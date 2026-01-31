import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import Foundation
import Darwin
import Observation // Für @Observable – by Obst-Terminator
import Sparkle
// MARK: - Datenmodell – by Obst-Terminator

enum SyncMode: String, Codable {
    case folder
    case selectedFiles

    // Benutzerfreundliche Labels mit Lokalisierung – by Obst-Terminator
    var label: String {
        switch self {
        case .folder: return String(localized: "Ordner")
        case .selectedFiles: return String(localized: "Dateiauswahl")
        }
    }
}

enum RunPhase: String, Sendable {
    case idle
    case checking
    case awaitingConfirm
    case syncing

    // Benutzerfreundliche Labels mit Lokalisierung – by Obst-Terminator
    var label: String {
        switch self {
        case .idle: return String(localized: "Leerlauf")
        case .checking: return String(localized: "Prüfen")
        case .awaitingConfirm: return String(localized: "Bestätigen")
        case .syncing: return String(localized: "Synchronisieren")
        }
    }
}

nonisolated struct RunProgress: Equatable, Sendable {
    var fraction: Double = 0
    var percentText: String = "0%"
    var transferredBytes: Int64 = 0
    var totalBytes: Int64 = 0

    // v1.1: Dateizähler (bestmöglich/geschätzt) – by Obst-Terminator
    var transferredFiles: Int = 0
    var totalFiles: Int = 0

    var speedBytesPerSec: Double = 0
    var etaSeconds: Int? = nil

    var hasAnyProgress: Bool { fraction > 0 || transferredBytes > 0 }
    static let zero = RunProgress()
}

struct SyncItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var mode: SyncMode
    var sourceBasePath: String
    var targetPath: String
    var selectedRelativePaths: [String]?

    init(
        id: UUID = UUID(),
        mode: SyncMode,
        sourceBasePath: String,
        targetPath: String,
        selectedRelativePaths: [String]? = nil
    ) {
        self.id = id
        self.mode = mode
        self.sourceBasePath = sourceBasePath
        self.targetPath = targetPath
        self.selectedRelativePaths = selectedRelativePaths
    }

    // Kann durch das Label der Enum-Property ersetzt werden – by Obst-Terminator
    var modeLabel: String {
        mode.label
    }
}

struct DryRunRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: String
    let target: String
    let filesToTransfer: Int
    let bytesToTransfer: Int64
}

// MARK: - POSIX-Spawn-Helfer (thread-sicher, ohne Actor) – by Obst-Terminator

struct RsyncRunResult: Sendable {
    let exitCode: Int32
    let sawAnyOutput: Bool
    let lastNonProgressLine: String
    let wasCancelled: Bool
}

enum PosixSpawn {

    struct Result: Sendable {
        let exitCode: Int32
        let output: String
    }

    /// Führt einen Befehl aus und erfasst kombinierte Stdout+Stderr. – by Obst-Terminator
    nonisolated static func captureAll(executablePath: String, arguments: [String]) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
        } catch {
            return Result(exitCode: 127, output: "ERROR: Process.run failed: \(error.localizedDescription)\n")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let out = String(data: data, encoding: .utf8) ?? ""
        return Result(exitCode: proc.terminationStatus, output: out)
    }

    /// Führt einen Befehl aus und streamt kombinierte Stdout+Stderr über `onChunk`. – by Obst-Terminator
    /// Diese Variante stellt den laufenden Prozess über `onStart` bereit, damit Aufrufer ihn abbrechen können. – by Obst-Terminator
    nonisolated static func stream(
        executablePath: String,
        arguments: [String],
        onStart: ((Process) -> Void)? = nil,
        onChunk: @escaping (String) -> Void
    ) -> RsyncRunResult {

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

// Thread-sicherer Zustand, da der readabilityHandler in einer Hintergrund-Queue laufen kann – by Obst-Terminator
        final class StreamState: @unchecked Sendable {
            let lock = NSLock()
            var sawAnyOutput = false
            var lastNonProgressLine = ""

            func note(_ chunk: String) {
                sawAnyOutput = true
                for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                        // progress2 enthält typischerweise '%' und ':' (ETA) – by Obst-Terminator
                    if t.contains("%") && t.contains(":") { continue }
                    lastNonProgressLine = t
                }
            }
        }

        let state = StreamState()
        let sema = DispatchSemaphore(value: 0)

        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { return }
            let chunk = String(decoding: data, as: UTF8.self)

            state.lock.lock()
            state.note(chunk)
            state.lock.unlock()

            onChunk(chunk)
        }

        proc.terminationHandler = { _ in
            sema.signal()
        }

        do {
            try proc.run()
        } catch {
            let msg = "ERROR: Process.run failed: \(error.localizedDescription)\n"
            onChunk(msg)
            state.lock.lock()
            state.note(msg)
            state.lock.unlock()
            pipe.fileHandleForReading.readabilityHandler = nil
            return RsyncRunResult(exitCode: 127, sawAnyOutput: true, lastNonProgressLine: msg.trimmingCharacters(in: .whitespacesAndNewlines), wasCancelled: false)
        }

        // Laufenden Prozess für Abbruch verfügbar machen – by Obst-Terminator
        onStart?(proc)

        // Auf Beendigung warten – by Obst-Terminator
        _ = sema.wait(timeout: .distantFuture)
        proc.waitUntilExit()

        // Verbleibende Daten (falls vorhanden) auslesen und Handler beenden – by Obst-Terminator
        pipe.fileHandleForReading.readabilityHandler = nil
        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
        if !remaining.isEmpty {
            let chunk = String(decoding: remaining, as: UTF8.self)
            state.lock.lock()
            state.note(chunk)
            state.lock.unlock()
            onChunk(chunk)
        }

        state.lock.lock()
        let saw = state.sawAnyOutput
        let last = state.lastNonProgressLine
        state.lock.unlock()

        let cancelled = (proc.terminationReason == .uncaughtSignal)

        return RsyncRunResult(exitCode: proc.terminationStatus, sawAnyOutput: saw, lastNonProgressLine: last, wasCancelled: cancelled)
    }

    /// Komfort-Wrapper, der die alte Signatur beibehält. – by Obst-Terminator
    nonisolated static func stream(
        executablePath: String,
        arguments: [String],
        onChunk: @escaping (String) -> Void
    ) -> RsyncRunResult {
        stream(executablePath: executablePath, arguments: arguments, onStart: nil, onChunk: onChunk)
    }
}

// MARK: - Sparkle Auto-Update – by Obst-Terminator

@MainActor
final class SparkleManager: ObservableObject {

    static let shared = SparkleManager()

    /// Der Sparkle-Updater (muss während der App-Laufzeit am Leben bleiben). – by Obst-Terminator
    let updaterController: SPUStandardUpdaterController

    private init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                         updaterDelegate: nil,
                                                         userDriverDelegate: nil)

        // Appcast-URL wird über Info.plist (Schlüssel: SUFeedURL) konfiguriert. – by Obst-Terminator

        updaterController.updater.automaticallyChecksForUpdates = true
        updaterController.updater.updateCheckInterval = 60 * 60 * 24 // 24h
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

enum PathRules {
    nonisolated static func normalizeFolderPath(_ path: String) -> String {
        path.hasSuffix("/") ? path : (path + "/")
    }

    nonisolated static func normalizeNoTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Zielregel für Ordner-Paare:
    /// - Quelle: Inhalt des Ordners (mit Slash am Ende)
    /// - Ziel:
    ///   - Wenn der Nutzer bereits .../<Ordnername> gewählt hat → direkt dorthin
    ///   - Sonst → .../<Ordnername> anlegen – by Obst-Terminator
    nonisolated static func folderPairDestination(chosenTargetPath: String, sourceFolderName: String) -> String {
        let chosen = normalizeNoTrailingSlash(chosenTargetPath)
        let chosenName = URL(fileURLWithPath: chosen).lastPathComponent
        if chosenName == sourceFolderName {
            return normalizeFolderPath(chosen)
        } else {
            return normalizeFolderPath(chosen + "/" + sourceFolderName)
        }
    }
}

enum RsyncParse {

    nonisolated static func stats(from output: String) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if let line = lines.first(where: { $0.lowercased().contains("number of regular files transferred") }) {
            if let n = Int(line.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) { files = n }
        } else if let line = lines.first(where: { $0.lowercased().contains("number of files transferred") }) {
            if let n = Int(line.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) { files = n }
        } else if let line = lines.first(where: { $0.lowercased().contains("files transferred") }) {
            if let n = Int(line.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) { files = n }
        }

        if let line = lines.first(where: { $0.lowercased().contains("total transferred file size") }) {
            let digits = line.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let n = Int64(digits) { bytes = n }
        }

        return (files, bytes)
    }

    /// rsync 3.x: --info=progress2 (Geschwindigkeit kann menschenlesbar wie MB/s sein, selbst mit --no-human-readable) – by Obst-Terminator
    nonisolated static func progress2(from chunk: String) -> RunProgress? {
        let lines = chunk.split(separator: "\n").map(String.init)
        guard let line = lines.first(where: { $0.contains("%") && $0.contains(":") }) else { return nil }

        // Beispiele (variiert je nach rsync-Version/Bauart): – by Obst-Terminator
        // "  1234567  12%   34.56MB/s    0:00:12"
        // "  1234567  12%   34567.89  0:00:12" (bytes/s)
        // Wir erfassen die optionale Einheit am Ende. – by Obst-Terminator
        let pattern = #"^\s*(\d+)\s+(\d+)%\s+(\d+(?:\.\d+)?)\s*([A-Za-z]+(?:/s)?)?\s+([0-9]+):([0-9]+):([0-9]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count))
        else { return nil }

        func group(_ i: Int) -> String {
            let r = m.range(at: i)
            guard let rr = Range(r, in: line) else { return "" }
            return String(line[rr])
        }

        let transferred = Int64(group(1)) ?? 0
        let percentInt = Int(group(2)) ?? 0

        let speedValue = Double(group(3)) ?? 0
        let speedUnitRaw = group(4)

        func speedToBytesPerSec(_ value: Double, unitRaw: String) -> Double {
            let u0 = unitRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if u0.isEmpty {
                // Assume bytes/sec
                return value
            }

            // Normalisieren wie "MB/s" -> "mb", "kB/s" -> "kb", "KiB/s" -> "kib" – by Obst-Terminator
            var u = u0.lowercased()
            if u.hasSuffix("/s") { u = String(u.dropLast(2)) }
            u = u.trimmingCharacters(in: .whitespacesAndNewlines)

            switch u {
            case "b", "byte", "bytes":
                return value
            case "kb", "kib":
                return value * 1024.0
            case "mb", "mib":
                return value * 1024.0 * 1024.0
            case "gb", "gib":
                return value * 1024.0 * 1024.0 * 1024.0
            case "tb", "tib":
                return value * 1024.0 * 1024.0 * 1024.0 * 1024.0
            default:
                // Unbekannte Einheit: bestmöglich als Bytes/Sekunde behandeln – by Obst-Terminator
                return value
            }
        }

        let speedBytesPerSec = speedToBytesPerSec(speedValue, unitRaw: speedUnitRaw)

        let h = Int(group(5)) ?? 0
        let mm = Int(group(6)) ?? 0
        let s = Int(group(7)) ?? 0
        let eta = h * 3600 + mm * 60 + s

        var p = RunProgress()
        p.transferredBytes = transferred
        p.percentText = "\(percentInt)%"
        p.fraction = max(0, min(1, Double(percentInt) / 100.0))
        p.speedBytesPerSec = speedBytesPerSec
        p.etaSeconds = eta

        // Bestehendes Verhalten beibehalten: Wenn Prozentwerte verfügbar sind, kann eine Gesamtsumme geschätzt werden. – by Obst-Terminator
        if percentInt > 0 {
            let approxTotal = Int64(Double(transferred) / (Double(percentInt) / 100.0))
            p.totalBytes = approxTotal
        }

        return p
    }

    /// Fallback für Apple rsync 2.6.9: --progress (nur Prozentanzeige) – by Obst-Terminator
    nonisolated static func percentOnly(from chunk: String) -> RunProgress? {
        let lines = chunk.split(separator: "\n").map(String.init)
        guard let line = lines.first(where: { $0.contains("%") }) else { return nil }

        let percentPattern = #"\b(\d{1,3})%\b"#
        guard let re = try? NSRegularExpression(pattern: percentPattern),
              let m = re.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)),
              let rr = Range(m.range(at: 1), in: line)
        else { return nil }

        let percentInt = max(0, min(100, Int(line[rr]) ?? 0))
        var p = RunProgress()
        p.percentText = "\(percentInt)%"
        p.fraction = Double(percentInt) / 100.0
        return p
    }
}

enum RsyncTool {

    nonisolated static func preferredExecutablePath() -> String {
        let candidates = [
            "/opt/homebrew/bin/rsync",
            "/usr/local/bin/rsync",
            "/usr/bin/rsync"
        ]
        for p in candidates where FileManager.default.fileExists(atPath: p) {
            return p
        }
        return "/usr/bin/rsync"
    }

    nonisolated static func supportsProgress2(executablePath: String) -> Bool {
        let res = PosixSpawn.captureAll(executablePath: executablePath, arguments: ["--version"])
        let firstLine = res.output.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.contains("rsync  version 3.")
            || firstLine.contains("rsync  version 4.")
            || firstLine.contains("rsync version 3.")
            || firstLine.contains("rsync version 4.")
    }
}

enum RsyncArgs {

    nonisolated static func make(item: SyncItem, dry: Bool, forProgress: Bool, supportsProgress2: Bool) -> ([String], String, String) {
        var args: [String] = ["-av", "-u"]

        if forProgress {
            if supportsProgress2 {
                args += ["--info=progress2", "--no-human-readable"]
            } else {
                args += ["--progress"]
            }
        } else {
            args.append("--stats")
        }

        if dry { args.append("--dry-run") }

        let srcShown: String
        let dstShown: String

        switch item.mode {
        case .folder:
            let srcURL = URL(fileURLWithPath: item.sourceBasePath)
            let folderName = srcURL.lastPathComponent

            let src = PathRules.normalizeFolderPath(item.sourceBasePath)
            let dst = PathRules.folderPairDestination(chosenTargetPath: item.targetPath, sourceFolderName: folderName)

            srcShown = src
            dstShown = dst

            args.append(src)
            args.append(dst)

        case .selectedFiles:
            let src = PathRules.normalizeFolderPath(item.sourceBasePath)
            let dst = PathRules.normalizeFolderPath(item.targetPath)

            args.append("--include=*/")
            (item.selectedRelativePaths ?? []).forEach { rel in
                args.append("--include=\(rel)")
            }
            args.append("--exclude=*")

            srcShown = src
            dstShown = dst

            args.append(src)
            args.append(dst)
        }

        return (args, srcShown, dstShown)
    }

    /// Argumente für das Streaming eines Dry-Runs, der eine Zeile pro Datei mit deren Größe ausgibt. – by Obst-Terminator
    /// Dies wird verwendet, um während der Prüfphase live „entdeckte Dateien / Bytes“-Zähler anzuzeigen. – by Obst-Terminator
    nonisolated static func makeDryRunCounting(item: SyncItem) -> ([String], String, String) {
        // -a (Archiv) + -u (Update) entspricht dem Verhalten des echten Laufs. – by Obst-Terminator
        // --dry-run stellt sicher, dass keine Änderungen vorgenommen werden. – by Obst-Terminator
        // --out-format gibt aus: <Größe>\t<Name> – by Obst-Terminator
        // --no-human-readable hält Größen als reine Zahlen. – by Obst-Terminator
        var args: [String] = ["-a", "-u", "--dry-run", "--no-human-readable", "--out-format=%l\t%n"]

        let srcShown: String
        let dstShown: String

        switch item.mode {
        case .folder:
            let srcURL = URL(fileURLWithPath: item.sourceBasePath)
            let folderName = srcURL.lastPathComponent

            let src = PathRules.normalizeFolderPath(item.sourceBasePath)
            let dst = PathRules.folderPairDestination(chosenTargetPath: item.targetPath, sourceFolderName: folderName)

            srcShown = src
            dstShown = dst

            args.append(src)
            args.append(dst)

        case .selectedFiles:
            let src = PathRules.normalizeFolderPath(item.sourceBasePath)
            let dst = PathRules.normalizeFolderPath(item.targetPath)

            args.append("--include=*/")
            (item.selectedRelativePaths ?? []).forEach { rel in
                args.append("--include=\(rel)")
            }
            args.append("--exclude=*")

            srcShown = src
            dstShown = dst

            args.append(src)
            args.append(dst)
        }

        return (args, srcShown, dstShown)
    }
}

// MARK: - UI-Hilfen – by Obst-Terminator

@MainActor private func formatBytes(_ bytes: Int64) -> String {
    // Use the class helper to avoid creating a formatter instance (Swift 6 / @MainActor annotations in Foundation can be strict).
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

@MainActor private func formatSpeed(_ bytesPerSec: Double) -> String {
    guard bytesPerSec > 0 else { return "–" }

    // Use ByteCountFormatter so throughput is shown in human-friendly units (KB/MB/GB per second).
    let pretty = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec.rounded()), countStyle: .file)
    return "\(pretty)/s"
}

@MainActor private func formatETA(_ seconds: Int?) -> String {
    guard let seconds, seconds > 0 else { return "–" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

@MainActor
struct DebugLogView: View {
    let text: String
    let autoScrollToBottom: Bool

    var body: some View {
        LogTextView(text: text.isEmpty ? String(localized: "(keine Debug-Ausgabe)") : text, autoScrollToBottom: autoScrollToBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25), lineWidth: 1))
            .cornerRadius(6)
    }

    /// AppKit-basierte, schreibgeschützte Log-Ansicht, die lange Zeilen umbricht und keinen horizontalen Bildlauf benötigt. – by Obst-Terminator
    private struct LogTextView: NSViewRepresentable {
        let text: String
        let autoScrollToBottom: Bool

        final class Coordinator {
            var lastTextCount: Int = 0
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSScrollView {
            let textView = NSTextView()
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

            // Zeilenumbruch erzwingen (keine horizontale Ausdehnung). – by Obst-Terminator
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = true
            textView.autoresizingMask = [.width]

            if let tc = textView.textContainer {
                tc.widthTracksTextView = true
                tc.heightTracksTextView = false
                tc.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
                tc.lineFragmentPadding = 0
            }

            let scroll = NSScrollView()
            scroll.documentView = textView
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false

            textView.string = text
            // Bei langen Logs am Ende beginnen. – by Obst-Terminator
            let end = (textView.string as NSString).length
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            return scroll
        }

        func updateNSView(_ nsView: NSScrollView, context: Context) {
            guard let tv = nsView.documentView as? NSTextView else { return }

            // Nur bei Bedarf aktualisieren. – by Obst-Terminator
            if tv.string != text {
                tv.string = text
            }

            // Automatisch scrollen, wenn aktiviert und der Inhalt gewachsen ist. – by Obst-Terminator
            let currentCount = (tv.string as NSString).length
            if autoScrollToBottom, currentCount > context.coordinator.lastTextCount {
                tv.scrollRangeToVisible(NSRange(location: currentCount, length: 0))
            }
            context.coordinator.lastTextCount = currentCount
        }
    }
}

// MARK: - Modell (Swift 5.9 @Observable für automatische Bindings) – by Obst-Terminator

// MannoCopyModel als @Observable mit normalen Properties statt @Published – by Obst-Terminator
@Observable
final class MannoCopyModel {

    // Normale Properties mit Anfangswerten – by Obst-Terminator

    var items: [SyncItem] = []
    var isDryRun: Bool = true
    var isRunning: Bool = false

    // Abbruch / Stopp – by Obst-Terminator
    var cancelRequested: Bool = false

    // Die aktuell laufenden rsync-Prozesse. Wird für Stopp verwendet. – by Obst-Terminator
    @ObservationIgnored private var activeProcesses: [UUID: Process] = [:]

    // v1.1 Flow-Status – by Obst-Terminator
    var runPhase: RunPhase = .idle
    var showSyncConfirm: Bool = false
    var preparedPlanMessage: String = ""

    // Dry-Run – by Obst-Terminator
    // Live-Zähler für entdeckte Dateien neben dem Spinner während der Prüfung – by Obst-Terminator
    var checkingDiscoveredFiles: Int = 0
    var checkingDiscoveredBytes: Int64 = 0

    // Katzen (nur Dry-Run) – by Obst-Terminator
    var checkingCatMessage: String = ""
    private let catMessages: [String] = [
        "🐈 Louis klappert mit dem Napf…",
        "🐈‍⬛ King Kong sucht seine Korkmaus…",
        "🐈 Louis sitzt im Karton. Warum auch nicht.",
        "🐈‍⬛ King Kong beobachtet unsichtbare Feinde.",
        "🐈 Louis überprüft, ob das Kabel noch lebt.",
        "🐈‍⬛ King Kong plant einen Hinterhalt.",
        "🐈 Louis liegt auf der Tastatur. Absicht.",
        "🐈‍⬛ King Kong bewacht das Kabel.",
        "🐈 Louis hat den Mauszeiger gefunden.",
        "🐈‍⬛ King Kong hat etwas gehört. Definitiv.",
        "🐈 Louis schläft. Mit offenen Augen.",
        "🐈‍⬛ King Kong jagt Staubpartikel.",
        "🐈 Louis sortiert Haare nach Wichtigkeit.",
        "🐈‍⬛ King Kong inspiziert die Ordnerstruktur.",
        "🐈 Louis steht im Weg. Wie immer.",
        "🐈‍⬛ King Kong sitzt. Und richtet.",
        "🐈 Louis hat gerade nichts gemacht. Ehrlich.",
        "🐈‍⬛ King Kong hat die Maus verloren.",
        "🐈 Louis testet die Schwerkraft (erneut).",
        "🐈‍⬛ King Kong weiß, was er tut. Wahrscheinlich.",
        "🐈 Louis lenkt ab…",
        "🐈‍⬛ King Kong erledigt den Rest.",
        "🐈 Louis hat eine Idee.",
        "🐈‍⬛ King Kong zweifelt daran.",
        "🐈 Louis ist zufrieden.",
        "🐈‍⬛ King Kong noch nicht.",
        "🐈 Louis klappert mit dem Napf.",
        "🐈‍⬛ King Kong sucht sein Korkmäuschen.",
        "🐈 Louis hat seine dollen 5 Minuten.",
        "🐈‍⬛ King Kong matscht im Brunnen.",
        "🐈 Louis meckert lautstark.",
        "🐈‍⬛ King Kong macht den Seehund."
    ]
    private var catIndex: Int = 0
    @ObservationIgnored private var catTimer: DispatchSourceTimer?
    var dryRunRows: [DryRunRow] = []
    var dryRunTotalFiles: Int = 0
    var dryRunTotalBytes: Int64 = 0
    var dryRunStatusText: String = ""

    // Hinweis bei großem Plan (automatisch im Dry-Run erkannt) – by Obst-Terminator
    var showLargePlanHint: Bool = false
    var largePlanHintText: String = ""

    @ObservationIgnored private var skipPlanRequested: Bool = false

    // Heuristische Schwellenwerte (für HDD/SMB optimiert) – by Obst-Terminator
    private let largePlanFilesThreshold: Int = 150_000
    private let largePlanBytesThreshold: Int64 = 500 * 1024 * 1024 * 1024 // 500 GB

    // Durchsatz-Glättung (vermeidet unruhige UI-Anzeige) – by Obst-Terminator
    @ObservationIgnored private var recentSpeeds: [Double] = []
    private let speedSmoothingWindow: Int = 5

    private func resetSpeedSmoothing() {
        recentSpeeds.removeAll(keepingCapacity: true)
    }

    private func smoothedSpeed(_ rawBytesPerSec: Double) -> Double {
        guard rawBytesPerSec > 0 else { return 0 }
        recentSpeeds.append(rawBytesPerSec)
        if recentSpeeds.count > speedSmoothingWindow {
            recentSpeeds.removeFirst(recentSpeeds.count - speedSmoothingWindow)
        }
        let sum = recentSpeeds.reduce(0, +)
        return sum / Double(recentSpeeds.count)
    }

    // Echt – by Obst-Terminator
    var progress: RunProgress = .zero
    var currentPairLabel: String = ""

    // Debug / Status – by Obst-Terminator
    var debugLogText: String = ""
    var lastRunMessage: String = ""
    var lastExitCode: Int32? = nil

    // Hinweis: Vollzugriff auf Festplatte (macOS Datenschutz) – by Obst-Terminator
    var showFullDiskAccessHint: Bool = false
    var fullDiskAccessHintText: String = ""
    @ObservationIgnored private var didShowFullDiskAccessHint: Bool = false

    // Debug-Ansicht Optionen – by Obst-Terminator
    var autoScrollDebug: Bool = true

    // Log begrenzen, damit die UI auch bei großen Läufen schnell bleibt. – by Obst-Terminator
    private static let debugMaxChars: Int = 2_000_000

    func appendDebug(_ s: String) {
        debugLogText.append(s)
        if debugLogText.count > Self.debugMaxChars {
            debugLogText = String(debugLogText.suffix(Self.debugMaxChars))
        }
    }

    func copyDebugToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(debugLogText, forType: .string)
    }

    // MARK: - Datenschutz / Vollzugriff – by Obst-Terminator

    @MainActor
    func openFullDiskAccessSettings() {
        // Apple erlaubt kein direktes „Anfordern“ – nur das Öffnen der passenden Systemeinstellungen.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func itemLikelyPhotosLibrary(_ item: SyncItem) -> Bool {
        let p = item.sourceBasePath.lowercased()
        return p.contains(".photoslibrary")
    }

    private func outputIndicatesPrivacyBlock(_ line: String) -> Bool {
        let l = line.lowercased()
        // Typische rsync/macos-Meldungen bei fehlenden Berechtigungen (TCC) – by Obst-Terminator
        return l.contains("operation not permitted")
            || l.contains("permission denied")
            || l.contains("not permitted")
            || l.contains("failed to open")
            || l.contains("error: perms")
    }

    @MainActor
    private func maybeShowFullDiskAccessHint(exitCode: Int32, lastLine: String, item: SyncItem) {
        guard !didShowFullDiskAccessHint else { return }
        // Exit 23 ist häufig „partial transfer“; in Kombination mit TCC/Permissions sehr typisch. – by Obst-Terminator
        let looksBlocked = outputIndicatesPrivacyBlock(lastLine)
        let isPhotos = itemLikelyPhotosLibrary(item)

        guard exitCode == 23 || looksBlocked else { return }
        guard looksBlocked || isPhotos else { return }

        didShowFullDiskAccessHint = true

        // Copy: Variante 1 (freundlich + erklärend + handlungsorientiert) – by Obst-Terminator
        var msg = "macOS schützt bestimmte Ordner besonders stark (z. B. Fotos-Mediathek, Mail, Safari-Daten).\n\nFür vollständige Backups benötigt MannoCopy den Vollzugriff auf die Festplatte.\n\nOhne diese Berechtigung können einzelne Dateien übersprungen werden."

        if isPhotos {
            msg += "\n\nHinweis: Die Apple Fotos-Mediathek ist besonders geschützt. Ohne Vollzugriff können Teile davon nicht gesichert werden."
        }

        fullDiskAccessHintText = msg
        showFullDiskAccessHint = true
    }

    /// Stoppt die aktuell laufenden rsync-Prozesse (falls vorhanden). Verwendet zuerst SIGTERM, dann SIGKILL als Fallback. – by Obst-Terminator
    func stopRunning() {
        guard isRunning else { return }
        cancelRequested = true
        stopCatTimer()

        let procs = activeProcesses
        if procs.isEmpty {
            runPhase = .idle
            isRunning = false
            lastRunMessage = String(localized: "Abgebrochen.")
            lastExitCode = nil
            appendDebug("\n=== STOP: kein aktiver Prozess gefunden ===\n")
            return
        }

        for (id, proc) in procs {
            let pid = proc.processIdentifier
            appendDebug("\n=== STOP: sende SIGTERM an rsync (pid: \(pid)) [\(id)] ===\n")
            proc.terminate() // SIGTERM
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let still = self.activeProcesses
            for (id, p) in still {
                if p.isRunning {
                    let pid2 = p.processIdentifier
                    self.appendDebug("=== STOP: rsync läuft noch, sende SIGKILL (pid: \(pid2)) [\(id)] ===\n")
                    _ = Darwin.kill(pid2, SIGKILL)
                }
            }
        }
    }

    /// Hinweis schließen und mit der Planung fortfahren. – by Obst-Terminator
    func continuePlanning() {
        showLargePlanHint = false
    }

    /// Fordert das Überspringen des Plans an: bricht aktuellen Dry-Run ab und startet sofort die Synchronisation. – by Obst-Terminator
    func skipPlanAndSyncNow() {
        skipPlanRequested = true
        showLargePlanHint = false
        // Reuse Stop logic to terminate all active dry-run rsync processes.
        stopRunning()
    }


    private func maybeShowLargePlanHint() {
        guard runPhase == .checking else { return }
        guard !showLargePlanHint else { return }
        guard !skipPlanRequested else { return }

        let hitFiles = checkingDiscoveredFiles >= largePlanFilesThreshold
        let hitBytes = checkingDiscoveredBytes >= largePlanBytesThreshold
        guard hitFiles || hitBytes else { return }

        showLargePlanHint = true

        var parts: [String] = []
        if hitFiles { parts.append("≥ \(largePlanFilesThreshold.formatted()) Dateien") }
        if hitBytes { parts.append("≥ \(formatBytes(largePlanBytesThreshold))") }
        let reason = parts.joined(separator: " oder ")
        largePlanHintText = "Großes Dataset erkannt (\(reason)). Die Planung kann sehr lange dauern (Stunden). Du kannst den Plan überspringen und direkt synchronisieren."
    }

    private func startCatTimerIfNeeded() {
        guard catTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 3.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.runPhase == .checking else { return }
            guard !self.catMessages.isEmpty else { return }
            self.checkingCatMessage = self.catMessages[self.catIndex % self.catMessages.count]
            self.catIndex += 1
        }
        catTimer = t
        t.resume()
    }

    private func stopCatTimer() {
        catTimer?.cancel()
        catTimer = nil
        checkingCatMessage = ""
        catIndex = 0
    }

    private let storageKey = "MannoCopy.Items.vClean"

    // Vorbereiteter Plan aus dem letzten Dry-Run (als Fortschritts-Baseline für den folgenden echten Lauf) – by Obst-Terminator
    @ObservationIgnored private var plannedBytesByID: [UUID: Int64] = [:]
    @ObservationIgnored private var preparedSnapshot: [SyncItem] = []

    @ObservationIgnored private var rsyncPath: String = "/usr/bin/rsync"
    @ObservationIgnored private var supportsProgress2: Bool = false
    @ObservationIgnored private var supportsChecked: Bool = false

    init() {
        loadItems()
        rsyncPath = RsyncTool.preferredExecutablePath()
    }

    // MARK: Persistence

    func saveItems() {
        do {
            let data = try JSONEncoder().encode(items)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            appendDebug("WARN: Speichern fehlgeschlagen: \(error.localizedDescription)\n")
        }
    }

    func loadItems() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        do {
            items = try JSONDecoder().decode([SyncItem].self, from: data)
        } catch {
            items = []
            appendDebug("WARN: Laden fehlgeschlagen (evtl. altes Format).\n")
        }
    }

    func clearAllItems() {
        items.removeAll()
        saveItems()
    }

    // MARK: Dialoge – by Obst-Terminator

    nonisolated func selectFolder(title: String) async -> URL? {
        await withCheckedContinuation { cont in
            Task { @MainActor in
                let p = NSOpenPanel()
                p.title = title
                p.prompt = String(localized: "Auswählen")
                p.canChooseDirectories = true
                p.canChooseFiles = false
                p.allowsMultipleSelection = false
                cont.resume(returning: p.runModal() == .OK ? p.url : nil)
            }
        }
    }

    nonisolated func pickFiles(title: String) async -> [URL] {
        await withCheckedContinuation { cont in
            Task { @MainActor in
                let p = NSOpenPanel()
                p.title = title
                p.message = String(localized: "Navigiere in den Ordner und wähle die gewünschten Dateien aus.")
                p.prompt = String(localized: "Auswählen")
                p.canChooseFiles = true
                p.canChooseDirectories = false
                p.allowsMultipleSelection = true
                p.allowedContentTypes = [UTType.item]
                p.canDownloadUbiquitousContents = true
                p.canResolveUbiquitousConflicts = true
                cont.resume(returning: p.runModal() == .OK ? p.urls : [])
            }
        }
    }

    // MARK: Einträge – by Obst-Terminator

    func addFolderItem() async {
        guard let src = await selectFolder(title: String(localized: "Quelle (Ordner) auswählen")),
              let dst = await selectFolder(title: String(localized: "Ziel (Ordner) auswählen"))
        else { return }

        items.append(SyncItem(mode: .folder, sourceBasePath: src.path, targetPath: dst.path))
        saveItems()
    }

    func addSelectedFilesItem() async {
        let files = await pickFiles(title: String(localized: "Dateien auswählen"))
        guard let first = files.first else { return }

        let base = first.deletingLastPathComponent()
        guard files.allSatisfy({ $0.deletingLastPathComponent() == base }) else {
            appendDebug("FEHLER: Dateien müssen aus demselben Ordner stammen\n")
            return
        }

        guard let dst = await selectFolder(title: String(localized: "Ziel (Ordner) auswählen")) else { return }

        let basePath = PathRules.normalizeFolderPath(base.path)
        let rels = files.compactMap { url -> String? in
            guard url.path.hasPrefix(basePath) else { return nil }
            return String(url.path.dropFirst(basePath.count))
        }

        items.append(SyncItem(mode: .selectedFiles, sourceBasePath: base.path, targetPath: dst.path, selectedRelativePaths: rels))
        saveItems()
    }

    func deleteItem(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        saveItems()
    }

    // MARK: Ausführen – by Obst-Terminator

    func runActionButton() {
        // Legacy entry point kept for internal use.
        guard !isRunning else { return }
        guard !items.isEmpty else { return }
        startCheckAndSyncFlow()
    }

    /// Neuer Hauptablauf für v1.1: immer zuerst Dry-Run, dann um Bestätigung fragen. – by Obst-Terminator
    func startCheckAndSyncFlow() {
        guard !isRunning else { return }
        guard !items.isEmpty else { return }

        resetOutputs()
        runPhase = .checking
        isRunning = true

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let initial: (items: [SyncItem], rsyncPath: String, supportsChecked: Bool, supportsProgress2: Bool) = await MainActor.run {
                (self.items, self.rsyncPath, self.supportsChecked, self.supportsProgress2)
            }

            var localSupportsProgress2 = initial.supportsProgress2
            let localRsyncPath = initial.rsyncPath

            if !initial.supportsChecked {
                let supports = RsyncTool.supportsProgress2(executablePath: localRsyncPath)
                localSupportsProgress2 = supports

                let rsyncPathSnapshot = localRsyncPath
                await MainActor.run {
                    self.supportsChecked = true
                    self.supportsProgress2 = supports
                    self.appendDebug("rsync: \(rsyncPathSnapshot) (progress2: \(supports ? "ja" : "nein"))\n")
                }
            }

            // Phase 1: Dry-run (plan)
            let completedPlan = await self.runDryRunWorker(snapshot: initial.items, rsyncPath: localRsyncPath, supportsProgress2: localSupportsProgress2)

            // Prepare plan baseline for progress.
            let shouldSkip = await MainActor.run { self.skipPlanRequested }
            if shouldSkip {
                await MainActor.run {
                    self.showLargePlanHint = false
                    self.largePlanHintText = ""
                    self.showSyncConfirm = false
                    self.runPhase = .syncing
                    self.isRunning = true
                    self.preparedSnapshot = initial.items
                    self.plannedBytesByID = [:]
                    self.preparedPlanMessage = ""
                }

                await self.runRealRunWorker(snapshot: initial.items, rsyncPath: localRsyncPath, supportsProgress2: localSupportsProgress2)

                await MainActor.run {
                    self.isRunning = false
                    self.runPhase = .idle
                    self.skipPlanRequested = false
                }
                return
            }

            if !completedPlan { return }

            let planned = await MainActor.run { () -> [UUID: Int64] in
                Dictionary(uniqueKeysWithValues: self.dryRunRows.map { ($0.id, $0.bytesToTransfer) })
            }

            await MainActor.run {
                self.plannedBytesByID = planned
                self.preparedSnapshot = initial.items
                self.preparedPlanMessage = String(localized: "Zu übertragen: \(self.dryRunTotalFiles) Datei(en) • \(formatBytes(self.dryRunTotalBytes))\n\nSynchronisation jetzt starten?")
                self.isRunning = false
                self.runPhase = .awaitingConfirm
                self.showSyncConfirm = true
            }
        }
    }

    /// Wird aufgerufen, nachdem der Nutzer das Pop-up bestätigt hat. – by Obst-Terminator
    func startPreparedSync() {
        guard !isRunning else { return }
        guard !preparedSnapshot.isEmpty else { return }

        resetRealOutputsOnly()
        runPhase = .syncing
        isRunning = true

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let initial: (rsyncPath: String, supportsProgress2: Bool, snapshot: [SyncItem]) = await MainActor.run {
                (self.rsyncPath, self.supportsProgress2, self.preparedSnapshot)
            }

            await self.runRealRunWorker(snapshot: initial.snapshot, rsyncPath: initial.rsyncPath, supportsProgress2: initial.supportsProgress2)

            await MainActor.run {
                self.isRunning = false
                self.runPhase = .idle
            }
        }
    }

    private func resetOutputs() {
        dryRunRows = []
        dryRunTotalFiles = 0
        dryRunTotalBytes = 0
        dryRunStatusText = ""

        progress = .zero
        currentPairLabel = ""

        debugLogText = ""
        lastRunMessage = ""
        lastExitCode = nil

        runPhase = .idle
        showSyncConfirm = false
        preparedPlanMessage = ""
        plannedBytesByID = [:]
        preparedSnapshot = []
        checkingDiscoveredFiles = 0
        checkingDiscoveredBytes = 0
        cancelRequested = false
        activeProcesses.removeAll()
        showLargePlanHint = false
        largePlanHintText = ""
        skipPlanRequested = false
        stopCatTimer()
        resetSpeedSmoothing()
        showFullDiskAccessHint = false
        fullDiskAccessHintText = ""
        didShowFullDiskAccessHint = false
    }

    private func resetRealOutputsOnly() {
        cancelRequested = false
        activeProcesses.removeAll()
        showLargePlanHint = false
        largePlanHintText = ""
        skipPlanRequested = false
        stopCatTimer()
        progress = .zero
        resetSpeedSmoothing()
        currentPairLabel = ""

        // Dateizähler sind pro Sync-Lauf; Bytes-Baseline kommt aus dem Plan. – by Obst-Terminator
        progress.transferredFiles = 0
        progress.totalFiles = 0

        lastRunMessage = ""
        lastExitCode = nil
        // dryRunRows / Summen behalten, damit der Nutzer den Plan weiterhin sehen kann. – by Obst-Terminator
    }

    private nonisolated func runDryRunWorker(snapshot: [SyncItem], rsyncPath: String, supportsProgress2: Bool) async -> Bool {
        await MainActor.run { self.dryRunStatusText = String(localized: "Ermittle zu übertragende Datenmenge…") }
        await MainActor.run { self.startCatTimerIfNeeded() }

        // Dry-Run-Zählung parallelisieren mit kleinem Limit, um Festplatten/Netzwerk-Shares nicht zu überlasten. – by Obst-Terminator
        let maxConcurrent = 2

        actor AsyncSemaphore {
            private var value: Int
            private var waiters: [CheckedContinuation<Void, Never>] = []

            init(_ value: Int) { self.value = value }

            func wait() async {
                if value > 0 {
                    value -= 1
                    return
                }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    waiters.append(cont)
                }
            }

            func signal() {
                if waiters.isEmpty {
                    value += 1
                } else {
                    let cont = waiters.removeFirst()
                    cont.resume()
                }
            }
        }

        let sem = AsyncSemaphore(maxConcurrent)

        // Ergebnisse nach ID speichern, damit die UI-Reihenfolge stabil bleibt (wie Snapshot-Reihenfolge). – by Obst-Terminator
        actor DryRunAggregator {
            private var rowsByID: [UUID: DryRunRow] = [:]
            private var totalsByID: [UUID: (files: Int, bytes: Int64)] = [:]

            func set(id: UUID, row: DryRunRow, files: Int, bytes: Int64) {
                rowsByID[id] = row
                totalsByID[id] = (files: files, bytes: bytes)
            }

            func orderedRows(snapshot: [SyncItem]) -> [DryRunRow] {
                snapshot.compactMap { rowsByID[$0.id] }
            }

            func totals() -> (files: Int, bytes: Int64) {
                totalsByID.values.reduce(into: (files: 0, bytes: Int64(0))) { acc, v in
                    acc.files += v.files
                    acc.bytes += v.bytes
                }
            }

            func doneCount() -> Int {
                rowsByID.count
            }
        }

        let aggregator = DryRunAggregator()

        await withTaskGroup(of: Void.self) { group in
            for (idx, item) in snapshot.enumerated() {
                group.addTask { [weak self] in
                    guard let self else { return }

                    await sem.wait()
                    defer { Task { await sem.signal() } }

                    // Cancel early if requested.
                    let cancelledEarly = await MainActor.run { self.cancelRequested }
                    if cancelledEarly { return }

                    await MainActor.run {
                        self.dryRunStatusText = "\(idx + 1)/\(snapshot.count): \(String(localized: "Ermittle Dateien…"))"
                    }

                    let (args, srcShown, dstShown) = RsyncArgs.makeDryRunCounting(item: item)

                    var itemFiles = 0
                    var itemBytes: Int64 = 0
                    var pending = ""

                    // Den blockierenden Stream auf einem GCD-Thread ausführen, um Swift-Concurrency-Threads nicht zu blockieren. – by Obst-Terminator
                    let result = await withCheckedContinuation { (cont: CheckedContinuation<RsyncRunResult, Never>) in
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            guard let self else {
                                cont.resume(returning: RsyncRunResult(exitCode: 127, sawAnyOutput: false, lastNonProgressLine: "", wasCancelled: false))
                                return
                            }

                            let result = PosixSpawn.stream(executablePath: rsyncPath, arguments: args, onStart: { [weak self] proc in
                                DispatchQueue.main.async { [weak self] in
                                    self?.activeProcesses[item.id] = proc
                                }
                            }) { [weak self] chunk in
                                guard let self else { return }

                                // Die Prüfausgabe ebenfalls ins Debug-Log schreiben, damit der Nutzer nachvollziehen kann, was rsync gemacht hat. – by Obst-Terminator
                                DispatchQueue.main.async { [weak self] in
                                    self?.appendDebug(chunk)
                                }

                                pending += chunk

                                while let cut = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                                    let line = String(pending[..<cut])

                                    var next = pending.index(after: cut)
                                    while next < pending.endIndex, (pending[next] == "\n" || pending[next] == "\r") {
                                        next = pending.index(after: next)
                                    }
                                    pending = String(pending[next...])

                                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if trimmed.isEmpty { continue }

                                    let parts = trimmed.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                                    guard parts.count == 2 else { continue }

                                    let sizeStr = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard let sz = Int64(sizeStr) else { continue }

                                    let name = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                                    if name == "." || name == "./" { continue }
                                    if name.hasSuffix("/") { continue }

                                    itemFiles += 1
                                    itemBytes += max(0, sz)

                                    DispatchQueue.main.async { [weak self] in
                                        guard let self else { return }
                                        self.checkingDiscoveredFiles += 1
                                        self.checkingDiscoveredBytes += max(0, sz)
                                        self.maybeShowLargePlanHint()
                                    }
                                }
                            }

                            cont.resume(returning: result)
                        }
                    }

                    // Eintrag des aktiven Prozesses entfernen. – by Obst-Terminator
                    await MainActor.run {
                        self.activeProcesses[item.id] = nil
                    }

                    let cancelledNow = await MainActor.run { self.cancelRequested }
                    if cancelledNow {
                        await MainActor.run {
                            self.isRunning = false
                            self.runPhase = .idle
                            self.lastRunMessage = String(localized: "Plan-Erstellung abgebrochen.")
                            self.stopCatTimer()
                            self.activeProcesses.removeAll()
                        }
                        return
                    }

                    // Datenschutz-Hinweis bereits im Dry-Run nur dann auslösen, wenn es wirklich nach macOS-Berechtigungen (TCC) aussieht. – by Obst-Terminator
                    if result.exitCode != 0 {
                        let hint = result.lastNonProgressLine.isEmpty ? String(localized: "(keine Detailzeile)") : result.lastNonProgressLine

                        // outputIndicatesPrivacyBlock ist UI-nah (MainActor); daher hier sauber auf MainActor ausführen. – by Obst-Terminator
                        let looksBlocked = await MainActor.run { self.outputIndicatesPrivacyBlock(hint) }
                        if looksBlocked || result.exitCode == 23 {
                            await MainActor.run {
                                self.maybeShowFullDiskAccessHint(exitCode: result.exitCode, lastLine: hint, item: item)
                            }
                        }
                    }

                    // Ergebnis in einem Actor speichern (Swift 6 sicher), dann UI in stabiler Reihenfolge aktualisieren. – by Obst-Terminator
                    let filesSnapshot = itemFiles
                    let bytesSnapshot = itemBytes
                    let row = DryRunRow(id: item.id, source: srcShown, target: dstShown, filesToTransfer: filesSnapshot, bytesToTransfer: bytesSnapshot)
                    await aggregator.set(id: item.id, row: row, files: filesSnapshot, bytes: bytesSnapshot)

                    let ordered = await aggregator.orderedRows(snapshot: snapshot)
                    let totals = await aggregator.totals()
                    let doneCount = await aggregator.doneCount()

                    await MainActor.run {
                        self.dryRunRows = ordered
                        self.dryRunTotalFiles = totals.files
                        self.dryRunTotalBytes = totals.bytes
                        self.dryRunStatusText = "\(doneCount)/\(snapshot.count): \(String(localized: "Fertig."))"
                    }
                }
            }

            await group.waitForAll()
        }

        let cancelledFinally = await MainActor.run { self.cancelRequested }
        await MainActor.run {
            if !cancelledFinally {
                self.dryRunStatusText = String(localized: "Plan fertig.")
            }
            self.stopCatTimer()
            self.activeProcesses.removeAll()
        }

        return !cancelledFinally
    }

    private nonisolated func runRealRunWorker(snapshot: [SyncItem], rsyncPath: String, supportsProgress2: Bool) async {
        for (idx, item) in snapshot.enumerated() {
            let shouldCancel = await MainActor.run { self.cancelRequested }
            if shouldCancel { return }
            let (args, srcShown, dstShown) = RsyncArgs.make(item: item, dry: false, forProgress: true, supportsProgress2: supportsProgress2)

            await MainActor.run {
                self.currentPairLabel = "\(idx + 1)/\(snapshot.count): \(srcShown) → \(dstShown)"
                self.progress = .zero
                self.progress.totalBytes = self.plannedBytesByID[item.id] ?? 0
                // Geplante Dateianzahl aus dem Plan (Dry-Run). – by Obst-Terminator
                self.progress.totalFiles = self.dryRunRows.first(where: { $0.id == item.id })?.filesToTransfer ?? 0
                self.progress.transferredFiles = 0
                self.resetSpeedSmoothing()

                let cmd = "\(rsyncPath) " + args.joined(separator: " ")
                self.appendDebug("\n=== RUN \(idx + 1)/\(snapshot.count) ===\n")
                self.appendDebug(String(localized: "Quelle: \(srcShown)\n"))
                self.appendDebug(String(localized: "Ziel:   \(dstShown)\n"))
                self.appendDebug(String(localized: "Befehl: \(cmd)\n\n"))
            }

            let localSupportsProgress2 = supportsProgress2

            let result = PosixSpawn.stream(executablePath: rsyncPath, arguments: args, onStart: { [weak self] proc in
                DispatchQueue.main.async { [weak self] in
                    self?.activeProcesses[item.id] = proc
                }
            }) { [weak self] chunk in
                guard let self else { return }

                if localSupportsProgress2 {
                    if let p = RsyncParse.progress2(from: chunk) {
                        Task { @MainActor [weak self] in
                            guard let self else { return }

                            // Geplante Gesamtsumme aus dem Dry-Run als Basis verwenden, falls verfügbar. – by Obst-Terminator
                            let plannedTotal = self.progress.totalBytes
                            if plannedTotal > 0 {
                                var pp = p
                                pp.totalBytes = plannedTotal
                                let frac = max(0, min(1, Double(pp.transferredBytes) / Double(plannedTotal)))
                                pp.fraction = frac
                                pp.percentText = "\(Int((frac * 100.0).rounded()))%"

                                // Durchsatz glätten, um UI-Flackern zu reduzieren. – by Obst-Terminator
                                pp.speedBytesPerSec = self.smoothedSpeed(pp.speedBytesPerSec)

                                // Näherungsweise Dateizähler: aus Bytes und geplanter Dateianzahl schätzen. – by Obst-Terminator
                                let plannedFiles = self.progress.totalFiles
                                if plannedFiles > 0 {
                                    let est = Int((Double(plannedFiles) * frac).rounded())
                                    pp.totalFiles = plannedFiles
                                    pp.transferredFiles = max(0, min(plannedFiles, est))
                                }

                                // Wenn möglich, eine ETA aus der Plan-Basis ableiten. – by Obst-Terminator
                                if pp.speedBytesPerSec > 0 {
                                    let remaining: Int64 = max(0, plannedTotal - pp.transferredBytes)
                                    pp.etaSeconds = Int(Double(remaining) / pp.speedBytesPerSec)
                                }

                                self.progress = pp
                            } else {
                                self.progress = p
                            }
                        }
                    }
                } else {
                    if let p = RsyncParse.percentOnly(from: chunk) {
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.progress.percentText = p.percentText
                            self.progress.fraction = p.fraction
                        }
                    }
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.appendDebug(chunk)
                }
            }

            let cancelledNow = await MainActor.run { self.cancelRequested }
            await MainActor.run { self.activeProcesses[item.id] = nil }

            if cancelledNow {
                await MainActor.run {
                    self.lastExitCode = result.exitCode
                    self.lastRunMessage = String(localized: "Abgebrochen.")
                    self.runPhase = .idle
                }
                return
            }

            await MainActor.run {
                self.lastExitCode = result.exitCode

                if self.cancelRequested || result.wasCancelled {
                    self.lastRunMessage = String(localized: "Abgebrochen.")
                } else if result.exitCode == 0 {
                    self.lastRunMessage = String(localized: "Fertig: \(srcShown) → \(dstShown)")
                } else {
                    let hint = result.lastNonProgressLine.isEmpty ? String(localized: "(keine Detailzeile)") : result.lastNonProgressLine
                    self.lastRunMessage = String(localized: "Fehler (Exit-Code \(result.exitCode)): \(hint)")
                    self.maybeShowFullDiskAccessHint(exitCode: result.exitCode, lastLine: hint, item: item)
                }

                if !self.progress.hasAnyProgress {
                    self.progress.percentText = (result.exitCode == 0) ? "100%" : "0%"
                    self.progress.fraction = (result.exitCode == 0) ? 1.0 : 0.0
                }

                if !result.sawAnyOutput {
                    self.appendDebug(String(localized: "(rsync lieferte keine Ausgabe)\n"))
                }

                self.appendDebug("\nExit-Code: \(result.exitCode)\n----------------------------------------\n")
            }
        }
    }
}

// MARK: - Views

@MainActor
struct DryRunSummaryView: View {
    // Änderung: @Bindable statt @ObservedObject
    @Bindable var model: MannoCopyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Plan"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isRunning {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.9)
                    Text(model.dryRunStatusText.isEmpty ? String(localized: "Berechne…") : model.dryRunStatusText)
                        .foregroundStyle(.secondary)
                }
            }

            if !model.dryRunRows.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(localized: "Gesamt:")).fontWeight(.semibold)
                            Spacer()
                            Text("\(model.dryRunTotalFiles) \(String(localized: "Datei(en)"))")
                            Text("•")
                            Text(formatBytes(model.dryRunTotalBytes))
                        }

                        Divider()

                        ForEach(model.dryRunRows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "Quelle → Ziel"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text("\(row.source) → \(row.target)")
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)

                                HStack(spacing: 10) {
                                    Text("\(row.filesToTransfer) \(String(localized: "Datei(en)"))")
                                    Text("•")
                                    Text(formatBytes(row.bytesToTransfer))
                                }
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            }
                            .padding(.vertical, 6)

                            Divider()
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else if !model.isRunning {
                Text(String(localized: "Klicke „Prüfen und Synchronisieren“, um zu sehen, wie viele Dateien kopiert würden."))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct RealRunProgressView: View {
    // Änderung: @Bindable statt @ObservedObject
    @Bindable var model: MannoCopyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Synchronisation"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isRunning {
                if !model.currentPairLabel.isEmpty {
                    Text(model.currentPairLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                ProgressView(value: model.progress.fraction) {
                    Text(model.progress.percentText)
                        .fontWeight(.semibold)
                }
                .progressViewStyle(.linear)

                HStack {
                    let transferred = model.progress.transferredBytes
                    let total = model.progress.totalBytes

                    Text(total > 0
                         ? "\(formatBytes(transferred)) \(String(localized: "von")) \(formatBytes(total))"
                         : "\(formatBytes(transferred)) \(String(localized: "übertragen"))")

                    Spacer()

                    let isComplete = (model.progress.fraction >= 1.0) || (total > 0 && transferred >= total)

                    if isComplete {
                        Text("✓ ") + Text(String(localized: "Abgeschlossen"))
                            .fontWeight(.semibold)
                    } else {
                        Text(String(localized: "Speed:")) + Text(" \(formatSpeed(model.progress.speedBytesPerSec))")
                        Text("•")

                        let etaText: String = {
                            // Wenn bereits übertragen wird, aber noch nicht genug Geschwindigkeitswerte gesammelt wurden, eine freundliche Platzhalteranzeige statt „–“ zeigen. – by Obst-Terminator
                            if transferred > 0 && model.progress.speedBytesPerSec <= 0 {
                                return String(localized: "wird ermittelt…")
                            }
                            return formatETA(model.progress.etaSeconds)
                        }()

                        Text(String(localized: "ETA:")) + Text(" \(etaText)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

            } else {
                if model.lastExitCode == 0, !model.lastRunMessage.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("✓ ") + Text(String(localized: "Abgeschlossen"))
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        Text(model.lastRunMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !model.lastRunMessage.isEmpty {
                    Text(model.lastRunMessage)
                        .foregroundStyle(.red)
                } else {
                    Text(String(localized: "Starte die Synchronisation, um den Fortschritt zu sehen."))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

@MainActor
struct ContentView: View {

    // Änderung: @Bindable statt @StateObject
    @Bindable private var model = MannoCopyModel()
    @State private var selectedID: UUID? = nil
    @State private var isDebugExpanded: Bool = false
    @StateObject private var sparkle = SparkleManager.shared

    // Minimale UI-Hilfen – by Obst-Terminator
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Hintergrund mit modernem Liquid-Glass-Effekt – by Obst-Terminator
                .background(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.gray.opacity(0.2), lineWidth: 1))
                .cornerRadius(10)
    }

    private func phaseChip(_ title: String, done: Bool, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : (active ? "circle.fill" : "circle"))
            Text(title).fontWeight(active ? .semibold : .regular)
        }
    }

    private var phaseBar: some View {
        HStack(spacing: 12) {
            phaseChip(String(localized: "Prüfen"), done: model.runPhase != .idle, active: model.runPhase == .checking)
            phaseChip(String(localized: "Bestätigen"), done: model.runPhase == .syncing, active: model.runPhase == .awaitingConfirm)
            phaseChip(
                String(localized: "Sync"),
                done: model.runPhase == .idle && model.lastExitCode == 0 && !model.lastRunMessage.isEmpty,
                active: model.runPhase == .syncing
            )
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(spacing: 16) {

            Text("MannoCopy")
                .font(.largeTitle)
                .fontWeight(.bold)

            HSplitView {
                VStack(spacing: 10) {
                    Text(String(localized: "Synchronisations-Paare"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    List(selection: $selectedID) {
                        ForEach(model.items) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.mode == .folder ? "folder" : "doc.on.doc")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(item.modeLabel)
                                            .fontWeight(.semibold)
                                        Image(systemName: "arrow.right")
                                            .foregroundStyle(.secondary)
                                        Text(URL(fileURLWithPath: item.targetPath).lastPathComponent)
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.caption)

                                    Text(item.sourceBasePath)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Text(item.targetPath)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(.vertical, 6)
                            .tag(item.id)
                        }
                        .onDelete(perform: model.deleteItem)
                    }
                    .frame(minWidth: 320, maxWidth: .infinity)
                    .layoutPriority(1)

                    HStack {
                        Button(String(localized: "Ordner-Paar hinzufügen")) {
                            Task { await model.addFolderItem() }
                        }
                        .controlSize(.small)
                        .disabled(model.isRunning)
                        .accessibilityLabel(String(localized: "Ordner-Paar hinzufügen"))

                        Button(String(localized: "Dateiauswahl hinzufügen")) {
                            Task { await model.addSelectedFilesItem() }
                        }
                        .controlSize(.small)
                        .disabled(model.isRunning)
                        .accessibilityLabel(String(localized: "Dateiauswahl hinzufügen"))

                        Spacer()

                        Button(String(localized: "Alle Einträge löschen")) {
                            model.clearAllItems()
                        }
                        .controlSize(.small)
                        .disabled(model.isRunning || model.items.isEmpty)
                        .accessibilityLabel(String(localized: "Alle Einträge löschen"))
                    }
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
                .layoutPriority(0)

                VStack(alignment: .leading, spacing: 12) {

                    card {
                        Button {
                            model.startCheckAndSyncFlow()
                        } label: {
                            Label(String(localized: "Prüfen und Synchronisieren"), systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.items.isEmpty || model.isRunning)
                        .accessibilityLabel(String(localized: "Prüfen und Synchronisieren"))

                        phaseBar

                        if model.isRunning {
                            HStack(spacing: 10) {
                                ProgressView().scaleEffect(0.9)

                                if model.runPhase == .checking {
                                    VStack(alignment: .leading, spacing: 2) {
                                        if !model.checkingCatMessage.isEmpty {
                                            Text(model.checkingCatMessage)
                                        }
                                        Text(String(localized: "Bisher \(model.checkingDiscoveredFiles) Dateien / \(formatBytes(model.checkingDiscoveredBytes))"))

                                        if model.showLargePlanHint {
                                            VStack(alignment: .leading, spacing: 6) {
                                                HStack(alignment: .top, spacing: 8) {
                                                    Image(systemName: "exclamationmark.triangle.fill")
                                                    Text(model.largePlanHintText)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }

                                                HStack(spacing: 8) {
                                                    Button(String(localized: "Plan weiter berechnen")) {
                                                        model.continuePlanning()
                                                    }
                                                    .controlSize(.small)
                                                    .accessibilityLabel(String(localized: "Plan weiter berechnen"))

                                                    Button(String(localized: "Plan überspringen & direkt syncen")) {
                                                        model.skipPlanAndSyncNow()
                                                    }
                                                    .controlSize(.small)
                                                    .accessibilityLabel(String(localized: "Plan überspringen und direkt synchronisieren"))
                                                }
                                            }
                                            .padding(8)
                                            .background(Color(nsColor: .textBackgroundColor))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.6), lineWidth: 1))
                                            .cornerRadius(8)
                                        }
                                    }
                                } else if model.runPhase == .syncing {
                                    let remainingBytes: Int64 = max(0, model.progress.totalBytes - model.progress.transferredBytes)

                                    if model.progress.totalFiles > 1 {
                                        let remainingFiles = max(0, model.progress.totalFiles - model.progress.transferredFiles)
                                        Text(LocalizedStringKey("Kopiert \(model.progress.transferredFiles) Dateien / \(formatBytes(model.progress.transferredBytes)) → offen \(remainingFiles) / \(formatBytes(remainingBytes))"))
                                    } else {
                                        Text(LocalizedStringKey("Übertragen \(formatBytes(model.progress.transferredBytes)) → offen \(formatBytes(remainingBytes))"))
                                    }
                                } else {
                                    Text(String(localized: "Arbeite…"))
                                }

                                // Beim Beenden kleinen Status-Text vor Spacer und Stopp-Button anzeigen – by Obst-Terminator
                                if model.cancelRequested {
                                    Text(String(localized: "Beende rsync…"))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 8)

                                // Stopp-Button durch verbesserte Variante ersetzt – by Obst-Terminator
                                Button {
                                    model.stopRunning()
                                } label: {
                                    if model.cancelRequested {
                                        Label(String(localized: "Beende…"), systemImage: "hourglass")
                                    } else {
                                        Label(String(localized: "Stopp"), systemImage: "stop.circle.fill")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                                .controlSize(.small)
                                .disabled(model.cancelRequested)
                                .accessibilityLabel(model.cancelRequested
                                                     ? String(localized: "Beende Synchronisation…")
                                                     : String(localized: "Synchronisation stoppen"))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    if model.runPhase == .syncing {
                        card {
                            RealRunProgressView(model: model)
                        }
                    } else {
                        card {
                            DryRunSummaryView(model: model)
                        }

                        if !model.lastRunMessage.isEmpty {
                            card {
                                RealRunProgressView(model: model)
                            }
                        }
                    }

                    DisclosureGroup(isExpanded: $isDebugExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Toggle(String(localized: "Auto-Scroll"), isOn: $model.autoScrollDebug)
                                    .toggleStyle(.switch)
                                    .accessibilityLabel(String(localized: "Debug Log Auto-Scroll ein/aus"))

                                Spacer()
                                
                                Button(String(localized: "Nach Updates suchen…")) {
                                    sparkle.checkForUpdates()
                                }
                                .controlSize(.small)
                                .accessibilityLabel(String(localized: "Nach Updates suchen"))

                                Button(String(localized: "Kopieren")) {
                                    model.copyDebugToClipboard()
                                }
                                .controlSize(.small)
                                .accessibilityLabel(String(localized: "Debug Log in Zwischenablage kopieren"))
                            }

                            DebugLogView(text: model.debugLogText, autoScrollToBottom: model.autoScrollDebug)
                                .frame(minHeight: 140)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .layoutPriority(1)
                        }
                    } label: {
                        Text(String(localized: "Details (Debug)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: isDebugExpanded ? .infinity : nil, alignment: .topLeading)
                    .layoutPriority(isDebugExpanded ? 2 : 0)

                    if !isDebugExpanded {
                        Spacer()
                    }
                }
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
                .padding(.leading, 10)
            }
            .frame(minHeight: 520)

        }
        .alert(String(localized: "Synchronisation starten?"), isPresented: $model.showSyncConfirm) {
            Button(String(localized: "Nein"), role: .cancel) {
                // User cancelled: keep the plan visible so they can adjust folders.
            }
            Button(String(localized: "Ja")) {
                model.startPreparedSync()
            }
        } message: {
            Text(model.preparedPlanMessage)
        }
        .alert(String(localized: "Vollzugriff auf Festplatte erforderlich"), isPresented: $model.showFullDiskAccessHint) {
            Button(String(localized: "Zu den Systemeinstellungen")) {
                model.openFullDiskAccessSettings()
            }
            Button(String(localized: "Abbrechen"), role: .cancel) {
                // Nur schließen
            }
        } message: {
            Text(model.fullDiskAccessHintText)
        }
        .onDisappear {
            model.stopRunning()
        }
        // Debug-Bereich automatisch erweitern, wenn lastExitCode ungleich Null ist. – by Obst-Terminator
        .onChange(of: model.lastExitCode) { _, newValue in
            if let code = newValue, code != 0 {
                isDebugExpanded = true
            }
        }
        // Debug ebenfalls automatisch erweitern, wenn lastRunMessage „Fehler“ enthält (ohne Beachtung der Groß-/Kleinschreibung, lokalisiert). – by Obst-Terminator
        .onChange(of: model.lastRunMessage) { _, newValue in
            if newValue.lowercased().contains(String(localized: "Fehler").lowercased()) {
                isDebugExpanded = true
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 980, minHeight: 860)
    }
}
// MARK: - Preview

#Preview {
    ContentView()
}


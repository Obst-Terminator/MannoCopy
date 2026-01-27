import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import Foundation
import Darwin

// MARK: - Datenmodell

enum SyncMode: String, Codable {
    case folder
    case selectedFiles
}

enum RunPhase: String, Sendable {
    case idle
    case checking
    case awaitingConfirm
    case syncing
}

nonisolated struct RunProgress: Equatable, Sendable {
    var fraction: Double = 0
    var percentText: String = "0%"
    var transferredBytes: Int64 = 0
    var totalBytes: Int64 = 0

    // v1.1: file counters (best-effort / estimated)
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

    var modeLabel: String {
        switch mode {
        case .folder: return "Ordner"
        case .selectedFiles: return "Dateiauswahl"
        }
    }
}

struct DryRunRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: String
    let target: String
    let filesToTransfer: Int
    let bytesToTransfer: Int64
}

// MARK: - POSIX spawn helpers (Thread-safe, non-actor)

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

    /// Runs a command and captures combined stdout+stderr.
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

    /// Runs a command and streams combined stdout+stderr via `onChunk`.
    /// This variant also exposes the running Process via `onStart` so callers can cancel it.
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

        // Thread-safe state, because readabilityHandler may run on a background queue.
        final class StreamState: @unchecked Sendable {
            let lock = NSLock()
            var sawAnyOutput = false
            var lastNonProgressLine = ""

            func note(_ chunk: String) {
                sawAnyOutput = true
                for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                    // progress2 enthält typischerweise '%' und ':' (ETA)
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

        // Expose the running process for cancellation.
        onStart?(proc)

        // Wait for termination.
        _ = sema.wait(timeout: .distantFuture)
        proc.waitUntilExit()

        // Drain remaining data (if any) and stop handler.
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

    /// Convenience wrapper keeping the old signature.
    nonisolated static func stream(
        executablePath: String,
        arguments: [String],
        onChunk: @escaping (String) -> Void
    ) -> RsyncRunResult {
        stream(executablePath: executablePath, arguments: arguments, onStart: nil, onChunk: onChunk)
    }
}

// MARK: - Helpers

enum PathRules {
    nonisolated static func normalizeFolderPath(_ path: String) -> String {
        path.hasSuffix("/") ? path : (path + "/")
    }

    nonisolated static func normalizeNoTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Folder-Pair Zielregel:
    /// - Quelle: Inhalt des Ordners (trailing slash)
    /// - Ziel:
    ///   - Wenn User schon .../<Ordnername> gewählt hat => direkt dahin
    ///   - Sonst => .../<Ordnername> anlegen
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

    /// rsync 3.x: --info=progress2 (speed can be human-readable like MB/s even with --no-human-readable)
    nonisolated static func progress2(from chunk: String) -> RunProgress? {
        let lines = chunk.split(separator: "\n").map(String.init)
        guard let line = lines.first(where: { $0.contains("%") && $0.contains(":") }) else { return nil }

        // Examples (varies by rsync version/build):
        // "  1234567  12%   34.56MB/s    0:00:12"
        // "  1234567  12%   34567.89  0:00:12" (bytes/s)
        // We capture optional unit suffix.
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

            // Normalize like "MB/s" -> "mb", "kB/s" -> "kb", "KiB/s" -> "kib"
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
                // Unknown unit: best effort—treat as bytes/sec
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

        // Keep existing behavior: when percent is available, we can approximate a total.
        if percentInt > 0 {
            let approxTotal = Int64(Double(transferred) / (Double(percentInt) / 100.0))
            p.totalBytes = approxTotal
        }

        return p
    }

    /// Fallback Apple rsync 2.6.9: --progress (percentage only)
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

    /// Args for streaming a dry-run that prints one line per file with its size.
    /// We use this to provide live "discovered files / bytes" counters during the checking phase.
    nonisolated static func makeDryRunCounting(item: SyncItem) -> ([String], String, String) {
        // -a (archive) + -u (update) matches real run behavior.
        // --dry-run ensures no changes.
        // --out-format prints: <size>\t<name>
        // --no-human-readable keeps sizes as plain integers.
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

// MARK: - UI Helpers

@MainActor private func formatBytes(_ bytes: Int64) -> String {
    // Use the class helper to avoid creating a formatter instance (Swift 6 / @MainActor annotations in Foundation can be strict).
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

@MainActor private func formatSpeed(_ bytesPerSec: Double) -> String {
    guard bytesPerSec > 0 else { return "–" }
    let mb = bytesPerSec / (1024.0 * 1024.0)
    return String(format: "%.2f MB/s", mb)
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
        LogTextView(text: text.isEmpty ? "(keine Debug-Ausgabe)" : text, autoScrollToBottom: autoScrollToBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25), lineWidth: 1))
            .cornerRadius(6)
    }

    /// AppKit-backed, read-only log view that wraps long lines and never requires horizontal scrolling.
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

            // Force wrapping (no horizontal expansion).
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
            // Start at bottom for long logs.
            let end = (textView.string as NSString).length
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            return scroll
        }

        func updateNSView(_ nsView: NSScrollView, context: Context) {
            guard let tv = nsView.documentView as? NSTextView else { return }

            // Only update when needed.
            if tv.string != text {
                tv.string = text
            }

            // Auto-scroll when enabled and content grew.
            let currentCount = (tv.string as NSString).length
            if autoScrollToBottom, currentCount > context.coordinator.lastTextCount {
                tv.scrollRangeToVisible(NSRange(location: currentCount, length: 0))
            }
            context.coordinator.lastTextCount = currentCount
        }
    }
}

// MARK: - Model (UI-Updates über MainActor)

@MainActor
final class MannoCopyModel: ObservableObject {

    @Published var items: [SyncItem] = []
    @Published var isDryRun: Bool = true
    @Published var isRunning: Bool = false

    // Cancellation / Stop
    @Published var cancelRequested: Bool = false

    // The currently running rsync Process (if any). Used for Stop.
    private var activeProcess: Process? = nil

    // v1.1 flow state
    @Published var runPhase: RunPhase = .idle
    @Published var showSyncConfirm: Bool = false
    @Published var preparedPlanMessage: String = ""

    // Dry-Run
    // Live discovery counters shown next to the spinner during checking
    @Published var checkingDiscoveredFiles: Int = 0
    @Published var checkingDiscoveredBytes: Int64 = 0

    // Cats (dry-run only)
    @Published var checkingCatMessage: String = ""
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
    private var catTimer: DispatchSourceTimer?
    @Published var dryRunRows: [DryRunRow] = []
    @Published var dryRunTotalFiles: Int = 0
    @Published var dryRunTotalBytes: Int64 = 0
    @Published var dryRunStatusText: String = ""

    // Real
    @Published var progress: RunProgress = .zero
    @Published var currentPairLabel: String = ""

    // Debug / status
    @Published var debugLogText: String = ""
    @Published var lastRunMessage: String = ""
    @Published var lastExitCode: Int32? = nil

    // Debug view options
    @Published var autoScrollDebug: Bool = true

    // Keep the log bounded so the UI stays fast even for huge runs.
    private let debugMaxChars: Int = 2_000_000

    func appendDebug(_ s: String) {
        debugLogText.append(s)
        if debugLogText.count > debugMaxChars {
            debugLogText = String(debugLogText.suffix(debugMaxChars))
        }
    }

    func copyDebugToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(debugLogText, forType: .string)
    }

    /// Stop the currently running rsync process (if any). Uses SIGTERM first, then SIGKILL as fallback.
    func stopRunning() {
        guard isRunning else { return }
        cancelRequested = true
        stopCatTimer()

        guard let proc = activeProcess else {
            runPhase = .idle
            isRunning = false
            lastRunMessage = "Abgebrochen."
            lastExitCode = nil
            appendDebug("\n=== STOP: kein aktiver Prozess gefunden ===\n")
            return
        }

        let pid = proc.processIdentifier
        appendDebug("\n=== STOP: sende SIGTERM an rsync (pid: \(pid)) ===\n")

        proc.terminate() // SIGTERM

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            guard let p = self.activeProcess else { return }
            if p.isRunning {
                let pid2 = p.processIdentifier
                self.appendDebug("=== STOP: rsync läuft noch, sende SIGKILL (pid: \(pid2)) ===\n")
                _ = Darwin.kill(pid2, SIGKILL)
            }
        }
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

    // Prepared plan from the last dry-run (used as progress baseline for the subsequent real run)
    private var plannedBytesByID: [UUID: Int64] = [:]
    private var preparedSnapshot: [SyncItem] = []

    private var rsyncPath: String = "/usr/bin/rsync"
    private var supportsProgress2: Bool = false
    private var supportsChecked: Bool = false

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

    // MARK: Dialogs

    nonisolated func selectFolder(title: String) async -> URL? {
        await withCheckedContinuation { cont in
            Task { @MainActor in
                let p = NSOpenPanel()
                p.title = title
                p.prompt = "Auswählen"
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
                p.message = "Navigiere in den Ordner und wähle die gewünschten Dateien aus."
                p.prompt = "Auswählen"
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

    // MARK: Items

    func addFolderItem() async {
        guard let src = await selectFolder(title: "Quelle (Ordner) auswählen"),
              let dst = await selectFolder(title: "Ziel (Ordner) auswählen")
        else { return }

        items.append(SyncItem(mode: .folder, sourceBasePath: src.path, targetPath: dst.path))
        saveItems()
    }

    func addSelectedFilesItem() async {
        let files = await pickFiles(title: "Dateien auswählen")
        guard let first = files.first else { return }

        let base = first.deletingLastPathComponent()
        guard files.allSatisfy({ $0.deletingLastPathComponent() == base }) else {
            appendDebug("FEHLER: Dateien müssen aus demselben Ordner stammen\n")
            return
        }

        guard let dst = await selectFolder(title: "Ziel (Ordner) auswählen") else { return }

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

    // MARK: Run

    func runActionButton() {
        // Legacy entry point kept for internal use.
        guard !isRunning else { return }
        guard !items.isEmpty else { return }
        startCheckAndSyncFlow()
    }

    /// New primary flow for v1.1: always dry-run first, then ask for confirmation.
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
            await self.runDryRunWorker(snapshot: initial.items, rsyncPath: localRsyncPath, supportsProgress2: localSupportsProgress2)

            // Prepare plan baseline for progress.
            let planned = await MainActor.run { () -> [UUID: Int64] in
                Dictionary(uniqueKeysWithValues: self.dryRunRows.map { ($0.id, $0.bytesToTransfer) })
            }

            await MainActor.run {
                self.plannedBytesByID = planned
                self.preparedSnapshot = initial.items
                self.preparedPlanMessage = "Zu übertragen: \(self.dryRunTotalFiles) Datei(en) • \(formatBytes(self.dryRunTotalBytes))\n\nSynchronisation jetzt starten?"
                self.isRunning = false
                self.runPhase = .awaitingConfirm
                self.showSyncConfirm = true
            }
        }
    }

    /// Called after the user confirmed the pop-up.
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
        activeProcess = nil
        stopCatTimer()
    }

    private func resetRealOutputsOnly() {
        cancelRequested = false
        activeProcess = nil
        stopCatTimer()
        progress = .zero
        currentPairLabel = ""

        // File counters are per sync run; bytes baseline comes from the plan.
        progress.transferredFiles = 0
        progress.totalFiles = 0

        lastRunMessage = ""
        lastExitCode = nil
        // Keep dryRunRows / totals so the user can still see the plan.
    }

    private nonisolated func runDryRunWorker(snapshot: [SyncItem], rsyncPath: String, supportsProgress2: Bool) async {
        await MainActor.run { self.dryRunStatusText = "Ermittle zu übertragende Datenmenge…" }
        await MainActor.run { self.startCatTimerIfNeeded() }

        var rows: [DryRunRow] = []
        var totalFiles = 0
        var totalBytes: Int64 = 0

        for (idx, item) in snapshot.enumerated() {
            await MainActor.run {
                self.dryRunStatusText = "\(idx + 1)/\(snapshot.count): Ermittle Dateien…"
            }

            let (args, srcShown, dstShown) = RsyncArgs.makeDryRunCounting(item: item)

            // Per-item counters (then we also add them to the global totals).
            var itemFiles = 0
            var itemBytes: Int64 = 0

            // Buffer partial lines across chunks.
            var pending = ""

            let result = PosixSpawn.stream(executablePath: rsyncPath, arguments: args, onStart: { [weak self] proc in
                DispatchQueue.main.async { [weak self] in
                    self?.activeProcess = proc
                }
            }) { [weak self] chunk in
                guard let self else { return }

                // Also write checking output into the debug log so the user can inspect what rsync did.
                DispatchQueue.main.async { [weak self] in
                    self?.appendDebug(chunk)
                }

                pending += chunk

                // Process complete lines only; keep the remainder in `pending`.
                // rsync may use \n, \r\n, or sometimes \r.
                while let idx = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    let line = String(pending[..<idx])

                    // Drop the line + any following newline characters (handles \r\n).
                    var next = pending.index(after: idx)
                    while next < pending.endIndex, (pending[next] == "\n" || pending[next] == "\r") {
                        next = pending.index(after: next)
                    }
                    pending = String(pending[next...])

                    // Expected format: "<size>\t<name>" (size is decimal bytes)
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }

                    // Split once on tab: "<size>\t<name>"
                    let parts = trimmed.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else { continue }

                    let sizeStr = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let sz = Int64(sizeStr) else { continue }

                    let name = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)

                    // Count ONLY files. Directories from rsync typically end with "/" or are "." / "./".
                    if name == "." || name == "./" { continue }
                    if name.hasSuffix("/") { continue }

                    itemFiles += 1
                    itemBytes += max(0, sz)

                    // Push live updates to the UI.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.checkingDiscoveredFiles += 1
                        self.checkingDiscoveredBytes += max(0, sz)
                    }
                }
            }

            let cancelledNow = await MainActor.run { self.cancelRequested }
            await MainActor.run { self.activeProcess = nil }

            if cancelledNow {
                await MainActor.run {
                    self.isRunning = false
                    self.runPhase = .idle
                    self.lastRunMessage = "Plan-Erstellung abgebrochen."
                    self.stopCatTimer()
                }
                return
            }

            _ = result

            totalFiles += itemFiles
            totalBytes += itemBytes

            rows.append(DryRunRow(id: item.id, source: srcShown, target: dstShown, filesToTransfer: itemFiles, bytesToTransfer: itemBytes))

            let rowsSnapshot = rows
            let totalFilesSnapshot = totalFiles
            let totalBytesSnapshot = totalBytes
            await MainActor.run {
                self.dryRunRows = rowsSnapshot
                self.dryRunTotalFiles = totalFilesSnapshot
                self.dryRunTotalBytes = totalBytesSnapshot
                self.dryRunStatusText = "\(idx + 1)/\(snapshot.count): Fertig."
            }
        }

        await MainActor.run {
            self.dryRunStatusText = "Plan fertig."
            self.stopCatTimer()
        }
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
                // Planned file count from the plan (dry-run)
                self.progress.totalFiles = self.dryRunRows.first(where: { $0.id == item.id })?.filesToTransfer ?? 0
                self.progress.transferredFiles = 0

                let cmd = "\(rsyncPath) " + args.joined(separator: " ")
                self.appendDebug("\n=== RUN \(idx + 1)/\(snapshot.count) ===\n")
                self.appendDebug("Quelle: \(srcShown)\n")
                self.appendDebug("Ziel:   \(dstShown)\n")
                self.appendDebug("Befehl: \(cmd)\n\n")
            }

            let localSupportsProgress2 = supportsProgress2

            let result = PosixSpawn.stream(executablePath: rsyncPath, arguments: args, onStart: { [weak self] proc in
                DispatchQueue.main.async { [weak self] in
                    self?.activeProcess = proc
                }
            }) { [weak self] chunk in
                guard let self else { return }

                if localSupportsProgress2 {
                    if let p = RsyncParse.progress2(from: chunk) {
                        Task { @MainActor [weak self] in
                            guard let self else { return }

                            // Use planned total from dry-run as baseline if available.
                            let plannedTotal = self.progress.totalBytes
                            if plannedTotal > 0 {
                                var pp = p
                                pp.totalBytes = plannedTotal
                                let frac = max(0, min(1, Double(pp.transferredBytes) / Double(plannedTotal)))
                                pp.fraction = frac
                                pp.percentText = "\(Int((frac * 100.0).rounded()))%"

                                // Best-effort file counters: estimate from bytes and the planned file count.
                                let plannedFiles = self.progress.totalFiles
                                if plannedFiles > 0 {
                                    let est = Int((Double(plannedFiles) * frac).rounded())
                                    pp.totalFiles = plannedFiles
                                    pp.transferredFiles = max(0, min(plannedFiles, est))
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
            await MainActor.run { self.activeProcess = nil }

            if cancelledNow {
                await MainActor.run {
                    self.lastExitCode = result.exitCode
                    self.lastRunMessage = "Abgebrochen."
                    self.runPhase = .idle
                }
                return
            }

            await MainActor.run {
                self.lastExitCode = result.exitCode

                if self.cancelRequested || result.wasCancelled {
                    self.lastRunMessage = "Abgebrochen."
                } else if result.exitCode == 0 {
                    self.lastRunMessage = "Fertig: \(srcShown) → \(dstShown)"
                } else {
                    let hint = result.lastNonProgressLine.isEmpty ? "(keine Detailzeile)" : result.lastNonProgressLine
                    self.lastRunMessage = "Fehler (Exit-Code \(result.exitCode)): \(hint)"
                }

                if !self.progress.hasAnyProgress {
                    self.progress.percentText = (result.exitCode == 0) ? "100%" : "0%"
                    self.progress.fraction = (result.exitCode == 0) ? 1.0 : 0.0
                }

                if !result.sawAnyOutput {
                    self.appendDebug("(rsync lieferte keine Ausgabe)\n")
                }

                self.appendDebug("\nExit-Code: \(result.exitCode)\n----------------------------------------\n")
            }
        }
    }
}

// MARK: - Views

@MainActor
struct DryRunSummaryView: View {
    @ObservedObject var model: MannoCopyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plan")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isRunning {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.9)
                    Text(model.dryRunStatusText.isEmpty ? "Berechne…" : model.dryRunStatusText)
                        .foregroundStyle(.secondary)
                }
            }

            if !model.dryRunRows.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Gesamt:").fontWeight(.semibold)
                            Spacer()
                            Text("\(model.dryRunTotalFiles) Datei(en)")
                            Text("•")
                            Text(formatBytes(model.dryRunTotalBytes))
                        }

                        Divider()

                        ForEach(model.dryRunRows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Quelle → Ziel")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text("\(row.source) → \(row.target)")
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)

                                HStack(spacing: 10) {
                                    Text("\(row.filesToTransfer) Datei(en)")
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
                Text("Klicke „Prüfen und Synchronisieren“, um zu sehen, wie viele Dateien kopiert würden.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct RealRunProgressView: View {
    @ObservedObject var model: MannoCopyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Synchronisation")
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
                         ? "\(formatBytes(transferred)) von \(formatBytes(total))"
                         : "\(formatBytes(transferred)) übertragen")

                    Spacer()

                    Text("Speed: \(formatSpeed(model.progress.speedBytesPerSec))")
                    Text("•")
                    Text("ETA: \(formatETA(model.progress.etaSeconds))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

            } else {
                if !model.lastRunMessage.isEmpty {
                    Text(model.lastRunMessage)
                        .foregroundStyle(model.lastExitCode == 0 ? Color.secondary : Color.red)
                } else {
                    Text("Starte die Synchronisation, um den Fortschritt zu sehen.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

@MainActor
struct ContentView: View {

    @StateObject private var model = MannoCopyModel()
    @State private var selectedID: UUID? = nil
    @State private var isDebugExpanded: Bool = false

    // Minimal UI helpers
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.background)
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
            phaseChip("Prüfen", done: model.runPhase != .idle, active: model.runPhase == .checking)
            phaseChip("Bestätigen", done: model.runPhase == .syncing, active: model.runPhase == .awaitingConfirm)
            phaseChip(
                "Sync",
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
                    Text("Synchronisations-Paare")
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
                        Button("Ordner-Paar hinzufügen") { Task { await model.addFolderItem() } }
                            .controlSize(.small)
                            .disabled(model.isRunning)

                        Button("Dateiauswahl hinzufügen") { Task { await model.addSelectedFilesItem() } }
                            .controlSize(.small)
                            .disabled(model.isRunning)

                        Spacer()

                        Button("Alle Einträge löschen") { model.clearAllItems() }
                            .controlSize(.small)
                            .disabled(model.isRunning || model.items.isEmpty)
                    }
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
                .layoutPriority(0)

                VStack(alignment: .leading, spacing: 12) {

                    card {
                        Button {
                            model.startCheckAndSyncFlow()
                        } label: {
                            Label("Prüfen und Synchronisieren", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.items.isEmpty || model.isRunning)

                        phaseBar

                        if model.isRunning {
                            HStack(spacing: 10) {
                                ProgressView().scaleEffect(0.9)

                        if model.runPhase == .checking {
                            VStack(alignment: .leading, spacing: 2) {
                                if !model.checkingCatMessage.isEmpty {
                                    Text(model.checkingCatMessage)
                                }
                                Text("Bisher \(model.checkingDiscoveredFiles) Dateien / \(formatBytes(model.checkingDiscoveredBytes))")
                            }
                        } else if model.runPhase == .syncing {
                            let remainingFiles = max(0, model.progress.totalFiles - model.progress.transferredFiles)
                            let remainingBytes = max(0, model.progress.totalBytes - model.progress.transferredBytes)
                            Text("Kopiert \(model.progress.transferredFiles) Dateien / \(formatBytes(model.progress.transferredBytes)) → offen \(remainingFiles) / \(formatBytes(remainingBytes))")
                        } else {
                            Text("Arbeite…")
                        }

                        Spacer(minLength: 8)

                        Button {
                            model.stopRunning()
                        } label: {
                            Label("Stopp", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.small)
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
                                Toggle("Auto-Scroll", isOn: $model.autoScrollDebug)
                                    .toggleStyle(.switch)

                                Spacer()

                                Button("Kopieren") {
                                    model.copyDebugToClipboard()
                                }
                                .controlSize(.small)
                            }

                            DebugLogView(text: model.debugLogText, autoScrollToBottom: model.autoScrollDebug)
                                .frame(minHeight: 140)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .layoutPriority(1)
                        }
                    } label: {
                        Text("Details (Debug)")
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
        .alert("Synchronisation starten?", isPresented: $model.showSyncConfirm) {
            Button("Nein", role: .cancel) {
                // User cancelled: keep the plan visible so they can adjust folders.
            }
            Button("Ja") {
                model.startPreparedSync()
            }
        } message: {
            Text(model.preparedPlanMessage)
        }
        .onDisappear {
            model.stopRunning()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 980, minHeight: 860)
    }
}

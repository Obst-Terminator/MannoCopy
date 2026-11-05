import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation
import Darwin
import Observation // Für @Observable – by Obst-Terminator
import Sparkle
// MARK: - Sparkle Auto-Update – by Obst-Terminator

@MainActor
final class SparkleManager {

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
    var photosLibraryDetected = false
    var isDryRun: Bool = true
    var isRunning: Bool = false {
        didSet {
            guard isRunning != oldValue else { return }
            if isRunning {
                activeTimeStartedAt = ProcessInfo.processInfo.systemUptime
                hasRunTiming = true
            } else if let start = activeTimeStartedAt {
                accumulatedRunTime += ProcessInfo.processInfo.systemUptime - start
                activeTimeStartedAt = nil
            }
        }
    }

    private var activeTimeStartedAt: TimeInterval?
    private var accumulatedRunTime: TimeInterval = 0
    private(set) var hasRunTiming = false

    // Count active work across pairs and phases; confirmation time is excluded.
    var elapsedRunTime: TimeInterval {
        accumulatedRunTime + (activeTimeStartedAt.map {
            ProcessInfo.processInfo.systemUptime - $0
        } ?? 0)
    }

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

    var dryRunRows: [DryRunRow] = []
    var dryRunTotalFiles: Int = 0
    var dryRunTotalBytes: Int64 = 0
    var dryRunStatusText: String = ""

    // Hinweis bei großem Plan (automatisch im Dry-Run erkannt) – by Obst-Terminator
    var showLargePlanHint: Bool = false
    var largePlanHintText: String = ""

    @ObservationIgnored private var skipPlanRequested: Bool = false
    @ObservationIgnored private var dismissedLargePlanHint = false


    // Archiv-Flow (tar + sha256 direkt im Zielordner) – by Obst-Terminator
    @ObservationIgnored private var archiveRequested: Bool = false
    // Heuristische Schwellenwerte (für HDD/SMB optimiert) – by Obst-Terminator
    private let largePlanFilesThreshold: Int = 150_000
    private let largePlanBytesThreshold: Int64 = 500 * 1024 * 1024 * 1024 // 500 GB

    @ObservationIgnored private var rateEstimator = TransferRateEstimator()

    private func resetSpeedSmoothing() {
        rateEstimator = TransferRateEstimator()
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
        if debugLogText.utf8.count > Self.debugMaxChars {
            debugLogText = String(decoding: debugLogText.utf8.suffix(Self.debugMaxChars), as: UTF8.self)
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
        return p.split(separator: "/").contains { $0.hasSuffix(".photoslibrary") }
            || (item.selectedRelativePaths ?? []).contains { $0.lowercased().hasSuffix(".photoslibrary") }
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


        let procs = activeProcesses
        for (id, proc) in procs {
            let pid = proc.processIdentifier
            appendDebug("\n=== STOP: sende SIGTERM an rsync (pid: \(pid)) [\(id)] ===\n")
            if proc.isRunning { proc.terminate() }
        }

        // Keep the run locked until the worker has drained all child processes.

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let still = procs
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
        dismissedLargePlanHint = true
    }

    /// Fordert das Überspringen des Plans an: bricht aktuellen Dry-Run ab und startet sofort die Synchronisation. – by Obst-Terminator
    func skipPlanAndSyncNow() {
        guard runPhase == .checking, isRunning, !cancelRequested else { return }
        skipPlanRequested = true
        showLargePlanHint = false
        // Reuse Stop logic to terminate all active dry-run rsync processes.
        stopRunning()
    }



    /// Erstellt ein .tar + .sha256 direkt im Zielordner (kein Temp-Archiv). – by Obst-Terminator
    /// Hinweis: Diese Aktion kann aus dem Large-Dataset-Hinweis während des laufenden Dry-Runs gestartet werden.
    /// In dem Fall wird der Dry-Run zuerst gestoppt und danach der Archiv-Flow gestartet. – by Obst-Terminator
    func startArchiveToTargetFlow() {
        // Wenn wir gerade im Dry-Run sind (Button ist genau dann sichtbar), erst sauber stoppen, dann archivieren. – by Obst-Terminator
        if isRunning {
            // Nur aus der Prüfphase heraus erlauben; sonst nicht in einen laufenden Sync reinfunken. – by Obst-Terminator
            guard runPhase == .checking else { return }

            archiveRequested = true
            showLargePlanHint = false
            largePlanHintText = ""

            // Stoppt rsync-Prozesse (SIGTERM/SIGKILL-Fallback). – by Obst-Terminator
            stopRunning()

            return
        }

        beginArchiveToTargetFlowUI()
    }

    @MainActor
    private func beginArchiveToTargetFlowUI() {
        guard !isRunning else { return }

        Task { @MainActor in
            // Quelle wählen (Ordner oder Package, z. B. Photos Library). – by Obst-Terminator
            guard let srcURL = await self.selectFolder(title: String(localized: "Quelle (Ordner/Library) auswählen")) else {
                self.archiveRequested = false
                return
            }
            // Zielordner (dorthin wird das Archiv geschrieben). – by Obst-Terminator
            guard let dstURL = await self.selectFolder(title: String(localized: "Zielordner für Archiv auswählen")) else {
                self.archiveRequested = false
                return
            }

            let sourcePath = srcURL.resolvingSymlinksInPath().standardizedFileURL.path
            let targetPath = dstURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard sourcePath != targetPath,
                  !targetPath.hasPrefix(PathRules.normalizeFolderPath(sourcePath)) else {
                self.lastExitCode = 1
                self.lastRunMessage = "Das Archivziel darf nicht innerhalb der Quelle liegen."
                self.archiveRequested = false
                return
            }

            // Warnhinweis: Photos-Library / laufende Photos-App (Konsistenz). – by Obst-Terminator
            let isPhotosLibrary = srcURL.path.lowercased().hasSuffix(".photoslibrary")
            let photosRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Photos" }
            if isPhotosLibrary && photosRunning {
                let alert = NSAlert()
                alert.messageText = String(localized: "Photos-App schließen empfohlen")
                alert.informativeText = String(localized: "Die Apple Fotos-Mediathek enthält Datenbanken. Bitte schließe die Fotos-App, bevor du die Mediathek archivierst, um eine konsistente Sicherung zu erhalten.")
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(localized: "Fortfahren"))
                alert.addButton(withTitle: String(localized: "Abbrechen"))
                if alert.runModal() == .alertSecondButtonReturn {
                    self.archiveRequested = false
                    return
                }
            }

            self.resetOutputs()
            self.runPhase = .archiving
            self.isRunning = true
            self.cancelRequested = false
            self.archiveRequested = true

            self.appendDebug("\n=== ARCHIVE: START ===\n")
            self.appendDebug("Quelle: \(srcURL.path)\n")
            self.appendDebug("Ziel:   \(dstURL.path)\n\n")
            self.lastRunMessage = String(localized: "Ermittle Größe…")

            Task.detached(priority: .userInitiated) { [self] in

                // 1) Größe schätzen (Worst-Case: wie Quelle, da Fotos kaum komprimierbar). – by Obst-Terminator
                let sizeResult = await self.captureManaged(executablePath: "/usr/bin/du", arguments: ["-sk", srcURL.path])
                if await self.finishCancelledArchiveIfNeeded() { return }
                let kib = Int64(sizeResult.output.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).first ?? "") ?? 0
                let estimatedBytes = max(0, kib) * 1024
                let freeBytes = await MainActor.run { self.availableBytes(at: dstURL) }

                // Reserve: 2% + 256 MiB (Filesystem-Overhead/Reserve). – by Obst-Terminator
                let margin = Int64(Double(estimatedBytes) * 0.02) + (256 * 1024 * 1024)
                let required = estimatedBytes + margin

                await MainActor.run {
                    self.appendDebug("Geschätzt: \(formatBytes(estimatedBytes))\n")
                    self.appendDebug("Frei:      \(formatBytes(freeBytes))\n")
                    self.appendDebug("Benötigt:  \(formatBytes(required)) (inkl. Reserve)\n\n")
                }

                if freeBytes > 0, freeBytes < required {
                    await MainActor.run {
                        self.isRunning = false
                        self.runPhase = .idle
                        self.lastExitCode = 1
                        self.lastRunMessage = String(localized: "Nicht genug freier Speicher im Zielordner für das Archiv.")
                        self.appendDebug("ERROR: Not enough free space for archive.\n")
                        self.archiveRequested = false
                    }
                    return
                }

                let baseName = await MainActor.run { self.makeArchiveFileBaseName(sourceURL: srcURL) }
                let archiveURL = dstURL.appendingPathComponent(baseName + ".tar")
                let checksumURL = dstURL.appendingPathComponent(baseName + ".tar.sha256")

                let parent = srcURL.deletingLastPathComponent()
                let name = srcURL.lastPathComponent

                await MainActor.run {
                    self.lastRunMessage = String(localized: "Erstelle Archiv…")
                    self.appendDebug("Archiv:   \(archiveURL.path)\n")
                    self.appendDebug("Checksum: \(checksumURL.path)\n\n")
                }

                // 2) tar direkt ins Ziel – by Obst-Terminator
                let tarID = UUID()
                let tarArgs = ["-cf", archiveURL.path, "-C", parent.path, name]

                let tarResult = PosixSpawn.stream(executablePath: "/usr/bin/tar", arguments: tarArgs, onStart: { [weak self] proc in
                    DispatchQueue.main.async { [weak self] in
                        self?.activeProcesses[tarID] = proc
                        if self?.cancelRequested == true, proc.isRunning { proc.terminate() }
                    }
                }) { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        self?.appendDebug(chunk)
                    }
                }

                await MainActor.run { self.activeProcesses[tarID] = nil }

                let cancelled = await MainActor.run { self.cancelRequested }
                if cancelled {
                    try? FileManager.default.removeItem(at: archiveURL)
                    await MainActor.run {
                        self.isRunning = false
                        self.runPhase = .idle
                        self.lastExitCode = tarResult.exitCode
                        self.lastRunMessage = String(localized: "Archivierung abgebrochen.")
                        self.appendDebug("\n=== ARCHIVE: CANCELLED ===\n")
                        self.archiveRequested = false
                    }
                    return
                }

                if tarResult.exitCode != 0 {
                    try? FileManager.default.removeItem(at: archiveURL)
                    await MainActor.run {
                        self.isRunning = false
                        self.runPhase = .idle
                        self.lastExitCode = tarResult.exitCode
                        let hint = tarResult.lastNonProgressLine.isEmpty ? String(localized: "(keine Detailzeile)") : tarResult.lastNonProgressLine
                        self.lastRunMessage = String(localized: "Fehler beim Erstellen des Archivs: \(hint)")
                        self.appendDebug("\n=== ARCHIVE: FAILED (tar) ===\n")
                        self.archiveRequested = false
                    }
                    return
                }

                // 3) sha256 schreiben – by Obst-Terminator
                await MainActor.run {
                    self.lastRunMessage = String(localized: "Berechne Checksum…")
                }

                let sha = await self.captureManaged(executablePath: "/usr/bin/shasum", arguments: ["-a", "256", archiveURL.path])
                if await self.finishCancelledArchiveIfNeeded() { return }
                if sha.exitCode != 0 || sha.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await MainActor.run {
                        self.isRunning = false
                        self.runPhase = .idle
                        self.lastExitCode = sha.exitCode
                        self.lastRunMessage = String(localized: "Fehler beim Berechnen der Checksum.")
                        self.appendDebug("\n=== ARCHIVE: FAILED (shasum) ===\n")
                        self.appendDebug(sha.output)
                        self.archiveRequested = false
                    }
                    return
                }

                do {
                    try sha.output.write(to: checksumURL, atomically: true, encoding: .utf8)
                } catch {
                    await MainActor.run {
                        self.isRunning = false
                        self.runPhase = .idle
                        self.lastExitCode = 1
                        self.lastRunMessage = String(localized: "Checksum-Datei konnte nicht geschrieben werden.")
                        self.appendDebug("ERROR: writing checksum failed: \(error.localizedDescription)\n")
                        self.archiveRequested = false
                    }
                    return
                }

                await MainActor.run {
                    self.isRunning = false
                    self.runPhase = .idle
                    self.lastExitCode = 0
                    self.lastRunMessage = String(localized: "Archiv erstellt: \(archiveURL.lastPathComponent)")
                    self.appendDebug("\n=== ARCHIVE: DONE ===\n")
                    self.appendDebug("Prüfen (optional): shasum -a 256 -c \"\(checksumURL.path)\"\n")
                    self.archiveRequested = false
                }
            }
        }
    }


    private func maybeShowLargePlanHint() {
        guard runPhase == .checking else { return }
        guard !showLargePlanHint, !dismissedLargePlanHint else { return }
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

// MARK: - Archivieren (tar + sha256) – by Obst-Terminator

private nonisolated func captureManaged(executablePath: String, arguments: [String]) async -> PosixSpawn.Result {
    let id = UUID()
    let result: PosixSpawn.Result = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            var output = ""
            let result = PosixSpawn.stream(executablePath: executablePath, arguments: arguments, onStart: { proc in
                DispatchQueue.main.async {
                    self.activeProcesses[id] = proc
                    if self.cancelRequested, proc.isRunning { proc.terminate() }
                }
            }, onChunk: { output += $0 })
            continuation.resume(returning: PosixSpawn.Result(exitCode: result.exitCode, output: output))
        }
    }
    await MainActor.run { self.activeProcesses[id] = nil }
    return result
}

@MainActor
private func finishCancelledArchiveIfNeeded() -> Bool {
    guard cancelRequested else { return false }
    isRunning = false
    runPhase = .idle
    archiveRequested = false
    lastExitCode = nil
    lastRunMessage = "Archivierung abgebrochen."
    return true
}

@MainActor
private func availableBytes(at url: URL) -> Int64 {
    if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
       let cap = v.volumeAvailableCapacityForImportantUsage {
        return Int64(cap)
    }
    if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
       let cap = v.volumeAvailableCapacity {
        return Int64(cap)
    }
    return 0
}

@MainActor
private func makeArchiveFileBaseName(sourceURL: URL) -> String {
    let raw = sourceURL.lastPathComponent
    // Avoid weird characters in filenames.
    let safe = raw
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return "\(safe)_\(df.string(from: Date()))_\(UUID().uuidString.prefix(8))"
}

    private let storageKey = "MannoCopy.Items.vClean"

    // Vorbereiteter Plan aus dem letzten Dry-Run (als Fortschritts-Baseline für den folgenden echten Lauf) – by Obst-Terminator
    @ObservationIgnored private var plannedBytesByID: [UUID: Int64] = [:]
    @ObservationIgnored private var preparedSnapshot: [SyncItem] = []
    @ObservationIgnored private var checkedSnapshot: [SyncItem] = []

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
        guard !isRunning else { return }
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
                p.treatsFilePackagesAsDirectories = true
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
        guard !isRunning else { return }
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

        guard items.allSatisfy({ item in
            let source = URL(fileURLWithPath: item.sourceBasePath).resolvingSymlinksInPath().standardizedFileURL.path
            let destination = item.mode == .folder
                ? PathRules.folderPairDestination(chosenTargetPath: item.targetPath,
                                                  sourceFolderName: URL(fileURLWithPath: item.sourceBasePath).lastPathComponent)
                : item.targetPath
            let target = URL(fileURLWithPath: destination).resolvingSymlinksInPath().standardizedFileURL.path
            return source != target && !target.hasPrefix(PathRules.normalizeFolderPath(source))
                && !source.hasPrefix(PathRules.normalizeFolderPath(target))
                && (item.mode != .selectedFiles || !(item.selectedRelativePaths ?? []).isEmpty)
        }) else {
            lastExitCode = 1
            lastRunMessage = "Quelle und Ziel dürfen sich nicht überschneiden; eine Dateiauswahl darf nicht leer sein."
            return
        }
        resetOutputs()
        photosLibraryDetected = items.contains(where: itemLikelyPhotosLibrary)
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
                    self.cancelRequested = false
                    self.dryRunRows = []
                    self.preparedPlanMessage = ""
                }

                await self.runRealRunWorker(snapshot: initial.items, rsyncPath: localRsyncPath, supportsProgress2: localSupportsProgress2)

                await MainActor.run {
                    self.isRunning = false
                    self.runPhase = .idle
                    self.skipPlanRequested = false
                    self.archiveRequested = false
                }
                return
            }

            if !completedPlan {
                await MainActor.run {
                    self.isRunning = false
                    self.runPhase = .idle
                    if self.archiveRequested { self.beginArchiveToTargetFlowUI() }
                }
                return
            }

            let planned = await MainActor.run { () -> [UUID: Int64] in
                Dictionary(uniqueKeysWithValues: self.dryRunRows.map { ($0.id, $0.bytesToTransfer) })
            }

            await MainActor.run {
                guard !self.cancelRequested else {
                    self.isRunning = false
                    self.runPhase = .idle
                    self.lastRunMessage = String(localized: "Plan-Erstellung abgebrochen.")
                    return
                }
                self.plannedBytesByID = planned
                self.checkedSnapshot = initial.items
                self.preparedSnapshot = SyncPlan.itemsRequiringSync(items: initial.items, rows: self.dryRunRows)
                self.isRunning = false
                if self.preparedSnapshot.isEmpty {
                    self.runPhase = .idle
                    self.showSyncConfirm = false
                    self.lastExitCode = 0
                    self.lastRunMessage = String(localized: "Alles aktuell, keine Synchronisation nötig.")
                    self.dryRunStatusText = self.lastRunMessage
                    self.appendDebug("\n=== Alles aktuell, keine Synchronisation nötig. ===\n")
                    return
                }
                self.preparedPlanMessage = String(localized: "Zu übertragen: \(self.dryRunTotalFiles) Datei(en) • \(formatBytes(self.dryRunTotalBytes))\n\nSynchronisation jetzt starten?")
                let otherChanges = self.dryRunRows.reduce(0) { $0 + max(0, $1.changesRequired - $1.filesToTransfer) }
                if otherChanges > 0 {
                    self.preparedPlanMessage += "\n\nWeitere Änderungen (Ordner, Links oder Metadaten): \(otherChanges)"
                }
                if self.photosLibraryDetected {
                    self.preparedPlanMessage += "\n\nFotos-Mediathek erkannt. Bitte die Fotos-App vor dem Kopieren schließen."
                }
                self.isRunning = false
                self.runPhase = .awaitingConfirm
                self.showSyncConfirm = true
            }
        }
    }

    /// Wird aufgerufen, nachdem der Nutzer das Pop-up bestätigt hat. – by Obst-Terminator
    func startPreparedSync() {
        guard !isRunning else { return }
        guard !preparedSnapshot.isEmpty, checkedSnapshot == items else { return }

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
        activeTimeStartedAt = nil
        accumulatedRunTime = 0
        hasRunTiming = false
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
        checkedSnapshot = []
        checkingDiscoveredFiles = 0
        checkingDiscoveredBytes = 0
        cancelRequested = false
        activeProcesses.removeAll()
        showLargePlanHint = false
        largePlanHintText = ""
        skipPlanRequested = false
        dismissedLargePlanHint = false

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

        // Serialize scans to avoid competing seeks on HDDs and network shares.
        let maxConcurrent = 1

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
            private var failed = false
            func noteFailure() { failed = true }
            func hasFailed() -> Bool { failed }
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

                    var itemChanges = 0
                    var itemFiles = 0
                    var itemBytes: Int64 = 0
                    var pending = ""
                    var detectedPhotos = false
                    var publishedFiles = 0
                    var publishedBytes: Int64 = 0
                    var lastPublish = ProcessInfo.processInfo.systemUptime

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
                                    if self?.cancelRequested == true, proc.isRunning { proc.terminate() }
                                }
                            }) { [weak self] chunk in
                                guard let self else { return }

                                pending += chunk.hasSuffix("\n") ? chunk : chunk + "\n"

                                while let cut = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                                    let line = String(pending[..<cut])

                                    var next = pending.index(after: cut)
                                    while next < pending.endIndex, (pending[next] == "\n" || pending[next] == "\r") {
                                        next = pending.index(after: next)
                                    }
                                    pending = String(pending[next...])

                                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if trimmed.isEmpty { continue }

                                    guard let change = RsyncPlanChange(line: trimmed) else {
                                        // Keep unknown output conservative: never declare this pair current.
                                        itemChanges += 1
                                        DispatchQueue.main.async { self.appendDebug(trimmed + "\n") }
                                        continue
                                    }
                                    if change.requiresSync { itemChanges += 1 }
                                    if !detectedPhotos && change.path.lowercased().contains(".photoslibrary/") {
                                        detectedPhotos = true
                                        DispatchQueue.main.async { self.photosLibraryDetected = true }
                                    }
                                    if change.transfersFile {
                                        itemFiles += 1
                                        itemBytes += change.bytes
                                    }

                                }
                                let now = ProcessInfo.processInfo.systemUptime
                                if now - lastPublish >= 0.2 {
                                    let files = itemFiles - publishedFiles
                                    let bytes = itemBytes - publishedBytes
                                    publishedFiles = itemFiles
                                    publishedBytes = itemBytes
                                    lastPublish = now
                                    DispatchQueue.main.async {
                                        self.checkingDiscoveredFiles += files
                                        self.checkingDiscoveredBytes += bytes
                                        self.maybeShowLargePlanHint()
                                    }
                                }
                            }
                            let files = itemFiles - publishedFiles
                            let bytes = itemBytes - publishedBytes
                            DispatchQueue.main.async {
                                self.checkingDiscoveredFiles += files
                                self.checkingDiscoveredBytes += bytes
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
                            self.lastRunMessage = String(localized: "Plan-Erstellung abgebrochen.")

                        }
                        return
                    }

                    // Datenschutz-Hinweis bereits im Dry-Run nur dann auslösen, wenn es wirklich nach macOS-Berechtigungen (TCC) aussieht. – by Obst-Terminator
                    if result.exitCode != 0 {
                        await aggregator.noteFailure()
                        await MainActor.run {
                            self.lastExitCode = result.exitCode
                            self.lastRunMessage = "Prüfung fehlgeschlagen: \(result.lastNonProgressLine)"
                        }
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
                    let row = DryRunRow(id: item.id, source: srcShown, target: dstShown, filesToTransfer: filesSnapshot, bytesToTransfer: bytesSnapshot, changesRequired: itemChanges)
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

        let failed = await aggregator.hasFailed()
        let cancelledFinally = await MainActor.run { self.cancelRequested }
        await MainActor.run {
            if !cancelledFinally && !failed {
                self.dryRunStatusText = String(localized: "Plan fertig.")
            }

            self.activeProcesses.removeAll()
        }

        return !cancelledFinally && !failed
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
                                    if self?.cancelRequested == true, proc.isRunning { proc.terminate() }
                }
            }) { [weak self] chunk in
                guard let self else { return }

                if localSupportsProgress2 {
                    if let p = RsyncParse.progress2(from: chunk) {
                        Task { @MainActor [weak self] in
                            guard let self else { return }

                            // Geplante Gesamtsumme aus dem Dry-Run als Basis verwenden, falls verfügbar. – by Obst-Terminator
                            let plannedTotal = self.plannedBytesByID[item.id] ?? 0
                            if plannedTotal > 0 {
                                var pp = p
                                pp.totalBytes = plannedTotal
                                let frac = max(0, min(1, Double(pp.transferredBytes) / Double(plannedTotal)))
                                pp.fraction = frac
                                pp.percentText = "\(Int((frac * 100.0).rounded()))%"

                                // Durchsatz glätten, um UI-Flackern zu reduzieren. – by Obst-Terminator
                                pp.speedBytesPerSec = self.rateEstimator.record(bytes: pp.transferredBytes, at: ProcessInfo.processInfo.systemUptime)

                                pp.totalFiles = self.progress.totalFiles
                                pp.transferredFiles = max(pp.transferredFiles, self.progress.transferredFiles)

                                // Wenn möglich, eine ETA aus der Plan-Basis ableiten. – by Obst-Terminator
                                if pp.speedBytesPerSec > 0, self.rateEstimator.isReady, pp.transferredBytes < plannedTotal {
                                    let remaining: Int64 = max(0, plannedTotal - pp.transferredBytes)
                                    pp.etaSeconds = Int(Double(remaining) / pp.speedBytesPerSec)
                                } else {
                                    pp.etaSeconds = nil
                                }

                                self.progress = pp
                            } else {
                                var estimate = p
                                estimate.totalBytes = 0
                                estimate.transferredFiles = max(estimate.transferredFiles, self.progress.transferredFiles)
                                estimate.speedBytesPerSec = self.rateEstimator.record(bytes: estimate.transferredBytes, at: ProcessInfo.processInfo.systemUptime)
                                estimate.etaSeconds = nil
                                self.progress = estimate
                            }
                        }
                    }
                } else {
                    if let p = RsyncParse.percentOnly(from: chunk) {
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            var legacy = p
                            legacy.isPerFile = true
                            legacy.percentText = "Aktuelle Datei: \(p.percentText)"
                            self.progress = legacy
                        }
                    }
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let messages = chunk.split(separator: "\n").filter { !$0.contains("%") }
                    if !messages.isEmpty { self.appendDebug(messages.joined(separator: "\n") + "\n") }
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

                if result.exitCode == 0 || !self.progress.hasAnyProgress {
                    self.progress.percentText = (result.exitCode == 0) ? "100%" : "0%"
                    self.progress.fraction = (result.exitCode == 0) ? 1.0 : 0.0
                }

                if !result.sawAnyOutput {
                    self.appendDebug(String(localized: "(rsync lieferte keine Ausgabe)\n"))
                }

                self.appendDebug("\nExit-Code: \(result.exitCode)\n----------------------------------------\n")
            }
            if result.exitCode != 0 { return }
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

            if model.runPhase == .checking {
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
                                    if row.changesRequired == 0 {
                                        Text("Alles aktuell")
                                    } else if row.changesRequired > row.filesToTransfer {
                                        Text("Weitere Änderungen: \(row.changesRequired - row.filesToTransfer)")
                                    }
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
private struct TransferMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct RealRunProgressView: View {
    let model: MannoCopyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Übertragung", systemImage: "arrow.up.arrow.down")
                .font(.headline)
            if model.isRunning && model.runPhase == .syncing {
                Text(model.currentPairLabel)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .help(model.currentPairLabel)
                ProgressView(value: model.progress.hasAnyProgress ? model.progress.fraction : nil) {
                    Text(model.progress.hasAnyProgress ? model.progress.percentText : "Dateien werden verglichen…")
                        .font(.headline).monospacedDigit()
                }
                .progressViewStyle(.linear)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let isStale = context.date.timeIntervalSince(model.progress.updatedAt) > 5
                    HStack(alignment: .top, spacing: 20) {
                        TransferMetric(title: "Übertragen", value: model.progress.isPerFile ? "–" : formatBytes(model.progress.transferredBytes))
                        TransferMetric(title: "Geschwindigkeit", value: isStale ? "–" : formatSpeed(model.progress.speedBytesPerSec))
                        TransferMetric(title: "Restzeit · aktuelles Paar",
                                   value: model.progress.isPerFile ? "Nicht verfügbar" : (isStale ? "Wird ermittelt…" : (model.progress.etaSeconds.map { "ca. " + formatETA($0) } ?? "Wird ermittelt…")))
                    }
                }
                if model.progress.totalBytes > 0 {
                    Text("Geplant: \(formatBytes(model.progress.totalBytes)) · \(model.progress.transferredFiles) Dateien übertragen")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.progress.fraction >= 1 && !model.progress.isPerFile {
                    Label("Übertragung wird abgeschlossen…", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !model.lastRunMessage.isEmpty {
                Label(model.lastRunMessage,
                      systemImage: model.cancelRequested ? "stop.circle" : (model.lastExitCode == 0 ? "checkmark.circle.fill" : "exclamationmark.circle"))
                    .foregroundStyle(model.lastExitCode == 0 ? Color.green : Color.primary)
                    .textSelection(.enabled)
            }
        }
    }
}

@MainActor
private struct RunWaitingView: View {
    let model: MannoCopyModel

    private static let catMessages: [String] = [
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


    var body: some View {
        if model.hasRunTiming {
            if model.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let seconds = max(0, Int(model.elapsedRunTime))
                    VStack(alignment: .leading, spacing: 8) {
                        RunElapsedLabel(seconds: seconds)
                        Text(Self.catMessages[(seconds / 3) % Self.catMessages.count])
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                RunElapsedLabel(seconds: max(0, Int(model.elapsedRunTime)))
            }
        }
    }
}

private struct RunElapsedLabel: View {
    let seconds: Int

    var body: some View {
        Label {
            Text("Vergangene Arbeitszeit: ")
                + Text(String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60))
        } icon: {
            Image(systemName: "clock")
        }
        .font(.callout)
        .monospacedDigit()
        .help("Zeit für Prüfung und Übertragung über alle Paare. Die Wartezeit auf die Bestätigung zählt nicht mit.")
    }
}

@MainActor
struct ContentView: View {

    @State private var model = MannoCopyModel()
    @State private var selectedID: UUID? = nil
    @State private var isDebugExpanded: Bool = false
    private let sparkle = SparkleManager.shared

    // Minimale UI-Hilfen – by Obst-Terminator
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
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
        phaseChip(String(localized: "Prüfen"), done: model.runPhase != .idle && model.runPhase != .checking, active: model.runPhase == .checking)
        if model.runPhase == .archiving {
            phaseChip(String(localized: "Archiv"), done: false, active: true)
        }
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

            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MannoCopy").font(.title.bold())
                    Text("Ordner sichern. Änderungen im Blick behalten.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Nach Updates suchen…") { sparkle.checkForUpdates() }
                    .buttonStyle(.borderless)
            }

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
                                        Text(URL(fileURLWithPath: item.sourceBasePath).lastPathComponent)
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
                    .overlay {
                        if model.items.isEmpty {
                            ContentUnavailableView("Noch keine Kopieraufträge",
                                                   systemImage: "folder.badge.plus",
                                                   description: Text("Füge einen Ordner oder einzelne Dateien hinzu."))
                        }
                    }
                    .frame(minWidth: 320, maxWidth: .infinity)
                    .layoutPriority(1)

                    VStack(alignment: .leading, spacing: 8) {
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

                        Divider()

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

                ScrollView {
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

                        RunWaitingView(model: model)

                        if model.photosLibraryDetected {
                            Label("Fotos-Mediathek: Fotos vor dem Kopieren schließen.", systemImage: "photo.on.rectangle")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        if model.isRunning {
                            HStack(spacing: 10) {
                                ProgressView().scaleEffect(0.9)

                                if model.runPhase == .checking {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Änderungen werden geprüft…").fontWeight(.medium)
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


                                                    Button(String(localized: "Als Archiv sichern")) {
                                                        model.startArchiveToTargetFlow()
                                                    }
                                                    .controlSize(.small)
                                                    .accessibilityLabel(String(localized: "Als Archiv sichern"))
                                                }
                                            }
                                            .padding(8)
                                            .background(Color(nsColor: .textBackgroundColor))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.6), lineWidth: 1))
                                            .cornerRadius(8)
                                        }
                                    }
                                } else if model.runPhase == .archiving {
                                    Text(model.lastRunMessage.isEmpty ? String(localized: "Erstelle Archiv im Zielordner…") : model.lastRunMessage)
                                } else if model.runPhase == .syncing {
                                    let remainingBytes: Int64 = max(0, model.progress.totalBytes - model.progress.transferredBytes)

                                    if model.progress.isPerFile {
                                        Text(model.progress.percentText)
                                    } else if model.progress.totalFiles > 1 {
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
                                


                                Button(String(localized: "Kopieren")) {
                                    model.copyDebugToClipboard()
                                }
                                .controlSize(.small)
                                .accessibilityLabel(String(localized: "Debug Log in Zwischenablage kopieren"))
                            }

                            DebugLogView(text: model.debugLogText, autoScrollToBottom: model.autoScrollDebug)
                                .frame(height: 220)
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
                }
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
                .padding(.leading, 10)
            }
            .frame(minHeight: 520)

        }
        .alert(String(localized: "Synchronisation starten?"), isPresented: $model.showSyncConfirm) {
            Button(String(localized: "Nein"), role: .cancel) {
                model.runPhase = .idle
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
        .frame(minWidth: 980, minHeight: 680)
    }
}
// MARK: - Preview

#Preview {
    ContentView()
}

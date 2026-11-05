import Foundation

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
    case archiving
    case syncing

    // Benutzerfreundliche Labels mit Lokalisierung – by Obst-Terminator
    var label: String {
        switch self {
        case .idle: return String(localized: "Leerlauf")
        case .checking: return String(localized: "Prüfen")
        case .awaitingConfirm: return String(localized: "Bestätigen")
        case .archiving: return String(localized: "Archivieren")
        case .syncing: return String(localized: "Synchronisieren")
        }
    }
}

nonisolated struct RunProgress: Equatable, Sendable {
    var fraction: Double = 0
    var percentText: String = "0%"
    var updatedAt = Date()
    var isPerFile = false
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
    let changesRequired: Int
}

nonisolated struct RsyncPlanChange {
    let requiresSync: Bool
    let transfersFile: Bool
    let bytes: Int64
    let path: String

    init?(line: String) {
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let size = Int64(parts[1]),
              parts[0].count >= 9 else { return nil }
        let code = Array(parts[0])
        guard "<>ch.*".contains(code[0]) else { return nil }
        // A leading dot means no content transfer, but attributes can still change.
        requiresSync = code[0] != "." || code.dropFirst(2).contains { $0 != "." && $0 != " " }
        transfersFile = (code[0] == ">" || code[0] == "<") && code[1] == "f"
        bytes = transfersFile ? max(0, size) : 0
        path = String(parts[2])
    }
}

enum SyncPlan {
    nonisolated static func itemsRequiringSync(items: [SyncItem], rows: [DryRunRow]) -> [SyncItem] {
        let unchangedIDs = Set(rows.filter { $0.changesRequired == 0 }.map(\.id))
        // Missing results must never be treated as proof that a pair is unchanged.
        return items.filter { !unchangedIDs.contains($0.id) }
    }
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
        proc.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }

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

        let out = String(decoding: data, as: UTF8.self)
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
        proc.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // One reader owns the pipe and parser. Preserve incomplete UTF-8 and records
        // across reads; rsync uses carriage returns for live progress.
        var pending = Data()
        var sawOutput = false
        var lastLine = ""
        var lastError = ""
        func deliver(_ data: Data) {
            let chunk = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "\n")
            sawOutput = true
            for line in chunk.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.contains("%") && text.contains(":") { continue }
                lastLine = text
                if text.contains("rsync:") || text.contains("denied") || text.contains("not permitted") {
                    lastError = text
                }
            }
            onChunk(chunk)
        }

        do {
            try proc.run()
        } catch {
            let message = "ERROR: Process.run failed: \(error.localizedDescription)\n"
            onChunk(message)
            return RsyncRunResult(exitCode: 127, sawAnyOutput: true,
                                  lastNonProgressLine: message, wasCancelled: false)
        }
        onStart?(proc)
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            pending.append(data)
            if let end = pending.lastIndex(where: { $0 == 10 || $0 == 13 }) {
                deliver(Data(pending[...end]))
                pending.removeSubrange(...end)
            }
        }
        if !pending.isEmpty { deliver(pending) }
        proc.waitUntilExit()
        return RsyncRunResult(exitCode: proc.terminationStatus, sawAnyOutput: sawOutput,
                              lastNonProgressLine: lastError.isEmpty ? lastLine : lastError,
                              wasCancelled: proc.terminationReason == .uncaughtSignal)
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

enum PathRules {
    nonisolated static func normalizeFolderPath(_ path: String) -> String {
        path.hasSuffix("/") ? path : (path + "/")
    }

    nonisolated static func normalizeNoTrailingSlash(_ path: String) -> String {
        path == "/" ? path : (path.hasSuffix("/") ? String(path.dropLast()) : path)
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
        let lines = chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        guard let line = lines.last(where: { $0.contains("%") && $0.contains(":") }) else { return nil }

        // Beispiele (variiert je nach rsync-Version/Bauart): – by Obst-Terminator
        // "  1234567  12%   34.56MB/s    0:00:12"
        // "  1234567  12%   34567.89  0:00:12" (bytes/s)
        // Wir erfassen die optionale Einheit am Ende. – by Obst-Terminator
        let pattern = #"^\s*([\d,]+)B?\s+(\d+)%\s+(\d+(?:\.\d+)?)\s*([A-Za-z]+(?:/s)?)?\s+([0-9]+):([0-9]+):([0-9]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count))
        else { return nil }

        func group(_ i: Int) -> String {
            let r = m.range(at: i)
            guard let rr = Range(r, in: line) else { return "" }
            return String(line[rr])
        }

        let transferred = Int64(group(1).replacingOccurrences(of: ",", with: "")) ?? 0
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
        // Completion records contain elapsed time, not remaining time.
        p.etaSeconds = line.contains("xfr#") || line.contains("to-chk=") || line.contains("ir-chk=") ? nil : eta
        if let range = line.range(of: #"xfr#(\d+)"#, options: .regularExpression) {
            p.transferredFiles = Int(line[range].dropFirst(4)) ?? 0
        }

        // Bestehendes Verhalten beibehalten: Wenn Prozentwerte verfügbar sind, kann eine Gesamtsumme geschätzt werden. – by Obst-Terminator
        if percentInt > 0 {
            let approxTotal = Int64(Double(transferred) / (Double(percentInt) / 100.0))
            p.totalBytes = approxTotal
        }

        return p
    }

    /// Fallback für Apple rsync 2.6.9: --progress (nur Prozentanzeige) – by Obst-Terminator
    nonisolated static func percentOnly(from chunk: String) -> RunProgress? {
        let lines = chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        guard let line = lines.last(where: { $0.contains("%") }) else { return nil }

        let percentPattern = #"\b(\d{1,3})%"#
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

nonisolated struct TransferRateEstimator {
    private var samples: [(time: Double, bytes: Int64)] = []
    private(set) var speed: Double = 0
    private(set) var isReady = false

    mutating func record(bytes: Int64, at time: Double) -> Double {
        if let last = samples.last, bytes < last.bytes {
            samples.removeAll()
            speed = 0
            isReady = false
        }
        if let last = samples.last, time - last.time < 0.25 { return speed }
        samples.append((time, bytes))
        while samples.count > 2, time - samples[1].time > 10 { samples.removeFirst() }
        guard let first = samples.first, time - first.time >= 1 else { return 0 }
        speed = Double(max(0, bytes - first.bytes)) / (time - first.time)
        isReady = time - first.time >= 3 && speed > 0
        return speed
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
        var args: [String] = ["-a", "-u"]

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

            // Explicit operands avoid walking every unrelated directory and treat
            // wildcard characters in selected filenames literally.
            // All selected files share the same source directory.

            srcShown = src
            dstShown = dst

            args.append("--")
            args += (item.selectedRelativePaths ?? []).map { src + $0 }
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
        var args: [String] = ["-a", "-u", "--dry-run", "--itemize-changes", "--out-format=%i\t%l\t%n"]

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

            // Explicit operands avoid walking every unrelated directory and treat
            // wildcard characters in selected filenames literally.
            // All selected files share the same source directory.

            srcShown = src
            dstShown = dst

            args.append("--")
            args += (item.selectedRelativePaths ?? []).map { src + $0 }
            args.append(dst)
        }

        return (args, srcShown, dstShown)
    }
}

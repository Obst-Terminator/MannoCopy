import Foundation
import Testing
@testable import TransferCore

@Test func planRecognizesNonContentChanges() throws {
    for code in ["cd+++++++++", "cL+++++++++", ".f...p.....", ".d..t......", "hf+++++++++"] {
        let change = try #require(RsyncPlanChange(line: "\(code)\t0\tentry"))
        #expect(change.requiresSync)
        #expect(!change.transfersFile)
    }
    #expect(RsyncPlanChange(line: ".d.........\t0\t./")?.requiresSync == false)
    #expect(RsyncPlanChange(line: ".f         \t12\tfile")?.requiresSync == false)
    #expect(RsyncPlanChange(line: ">f+++++++++\t0\tempty-file")?.requiresSync == true)
}

@Test func planSelectsOnlyChangedPairs() {
    let current = SyncItem(mode: .folder, sourceBasePath: "/source/a", targetPath: "/target")
    let changed = SyncItem(mode: .folder, sourceBasePath: "/source/b", targetPath: "/target")
    let currentRow = DryRunRow(id: current.id, source: current.sourceBasePath, target: current.targetPath,
                               filesToTransfer: 0, bytesToTransfer: 0, changesRequired: 0)
    let metadataRow = DryRunRow(id: changed.id, source: changed.sourceBasePath, target: changed.targetPath,
                                filesToTransfer: 0, bytesToTransfer: 0, changesRequired: 1)
    #expect(SyncPlan.itemsRequiringSync(items: [current], rows: [currentRow]).isEmpty)
    #expect(SyncPlan.itemsRequiringSync(items: [current, changed], rows: [currentRow, metadataRow]) == [changed])
    #expect(SyncPlan.itemsRequiringSync(items: [current, changed], rows: [currentRow]) == [changed])
}

@Test func actualRsyncDetectsDirectoriesLinksAndPermissions() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    for executable in ["/usr/bin/rsync", "/opt/homebrew/bin/rsync", "/usr/local/bin/rsync"] where fm.isExecutableFile(atPath: executable) {
        let base = root.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source")
        let destination = base.appendingPathComponent("backup/source")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("same content".utf8).write(to: source.appendingPathComponent("file"))
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.appendingPathComponent("file").path)
        let item = SyncItem(mode: .folder, sourceBasePath: source.path, targetPath: destination.path)
        func sync() throws {
            let result = PosixSpawn.captureAll(executablePath: executable,
                arguments: RsyncArgs.make(item: item, dry: false, forProgress: false, supportsProgress2: false).0)
            try #require(result.exitCode == 0, "\(executable): \(result.output)")
        }
        func changes() throws -> [RsyncPlanChange] {
            let result = PosixSpawn.captureAll(executablePath: executable,
                                               arguments: RsyncArgs.makeDryRunCounting(item: item).0)
            try #require(result.exitCode == 0)
            return result.output.split(separator: "\n").compactMap { RsyncPlanChange(line: String($0)) }.filter(\.requiresSync)
        }
        try sync()
        #expect(try changes().isEmpty)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.appendingPathComponent("file").path)
        let permissions = try changes()
        #expect(permissions.contains { $0.path == "file" && !$0.transfersFile })
        try sync()
        #expect(try changes().isEmpty)
        try fm.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let directories = try changes()
        #expect(directories.contains { $0.path == "empty/" && !$0.transfersFile })
        try sync()
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "file")
        let links = try changes()
        #expect(links.contains { $0.path == "link" && !$0.transfersFile })
        try sync()
        #expect(try changes().isEmpty)
    }
}

@Test func progressUsesLatestRecordAndRealFileCount() throws {
    let output = "  1,234,567  12% 34.56MB/s 0:00:12\r  2,000,000  20% 10.00MB/s 0:00:08 (xfr#7, to-chk=2/10)\n"
    let progress = try #require(RsyncParse.progress2(from: output))
    #expect(progress.transferredBytes == 2_000_000)
    #expect(progress.transferredFiles == 7)
    #expect(progress.etaSeconds == nil)
}

@Test func legacyProgressIsRecognized() {
    #expect(RsyncParse.percentOnly(from: "1024 50% 1.00MB/s 0:00:01")?.fraction == 0.5)
    #expect(RsyncParse.progress2(from: "filename with 50% inside") == nil)
}

@Test func rateNeedsWarmupAndIncludesPauses() {
    var rate = TransferRateEstimator()
    #expect(rate.record(bytes: 0, at: 0) == 0)
    #expect(!rate.isReady)
    #expect(rate.record(bytes: 3_000, at: 3) == 1_000)
    #expect(rate.isReady)
    #expect(rate.record(bytes: 3_000, at: 6) == 500)
    #expect(rate.record(bytes: 0, at: 7) == 0)
    #expect(!rate.isReady)
}

@Test func folderDestinationPreservesRootAndAvoidsDuplicateName() {
    #expect(PathRules.normalizeNoTrailingSlash("/") == "/")
    #expect(PathRules.folderPairDestination(chosenTargetPath: "/backup/source", sourceFolderName: "source") == "/backup/source/")
    #expect(PathRules.folderPairDestination(chosenTargetPath: "/backup", sourceFolderName: "source") == "/backup/source/")
}

@Test func explicitSelectionCopiesLiteralFilenamesAndOnlySelectedFiles() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("destination")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let names = ["a[1]*.txt", "Grüße 📷.txt", "-option.txt"]
    for name in names + ["unselected.txt"] {
        try Data("abc".utf8).write(to: source.appendingPathComponent(name))
    }
    let item = SyncItem(mode: .selectedFiles, sourceBasePath: source.path,
                        targetPath: destination.path, selectedRelativePaths: names)
    for executable in ["/usr/bin/rsync", "/opt/homebrew/bin/rsync", "/usr/local/bin/rsync"] where fm.isExecutableFile(atPath: executable) {
        for child in try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) {
            try fm.removeItem(at: child)
        }
        let dry = RsyncArgs.makeDryRunCounting(item: item).0
        let plan = PosixSpawn.captureAll(executablePath: executable, arguments: dry)
        #expect(plan.exitCode == 0, "\(executable): \(plan.output)")
        #expect(plan.output.split(separator: "\n").filter { $0.hasPrefix(">f") || $0.hasPrefix("<f") }.count == names.count)
        #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
        let arguments = RsyncArgs.make(item: item, dry: false, forProgress: true,
                                      supportsProgress2: RsyncTool.supportsProgress2(executablePath: executable)).0
        let copied = PosixSpawn.captureAll(executablePath: executable, arguments: arguments)
        #expect(copied.exitCode == 0, "\(executable): \(copied.output)")
        if RsyncTool.supportsProgress2(executablePath: executable) {
            #expect(RsyncParse.progress2(from: copied.output)?.transferredBytes == 9)
        }
        #expect(Set(try fm.contentsOfDirectory(atPath: destination.path)) == Set(names))
        let unchanged = PosixSpawn.captureAll(executablePath: executable, arguments: dry)
        #expect(unchanged.exitCode == 0)
        #expect(unchanged.output.isEmpty)
    }
}

@Test func streamPreservesSplitUTF8AndCarriageReturns() {
    var output = ""
    let result = PosixSpawn.stream(executablePath: "/bin/sh", arguments: ["-c", "printf '\\303'; sleep 0.05; printf '\\244\\rsecond\\nlast'"] , onChunk: { output += $0 })
    #expect(result.exitCode == 0)
    #expect(output == "ä\nsecond\nlast")
    #expect(result.lastNonProgressLine == "last")
}

@Test func failedLaunchIsReported() {
    let result = PosixSpawn.stream(executablePath: "/nonexistent/mannocopy", arguments: [], onChunk: { _ in })
    #expect(result.exitCode == 127)
}

@Test func runningChildCanBeStopped() {
    let result = PosixSpawn.stream(executablePath: "/bin/sleep", arguments: ["2"],
                                  onStart: { $0.terminate() }, onChunk: { _ in })
    #expect(result.wasCancelled)
    #expect(result.exitCode != 0)
}

@Test func libraryFolderPlanCountsFilesAndCopiesContents() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("Example.photoslibrary")
    try fm.createDirectory(at: source.appendingPathComponent("originals"), withIntermediateDirectories: true)
    try Data("database".utf8).write(to: source.appendingPathComponent("Photos.sqlite"))
    try Data("image".utf8).write(to: source.appendingPathComponent("originals/example.jpg"))
    for executable in ["/usr/bin/rsync", "/opt/homebrew/bin/rsync", "/usr/local/bin/rsync"] where fm.isExecutableFile(atPath: executable) {
        let destination = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let item = SyncItem(mode: .folder, sourceBasePath: source.path, targetPath: destination.path)
        let plan = PosixSpawn.captureAll(executablePath: executable, arguments: RsyncArgs.makeDryRunCounting(item: item).0)
        #expect(plan.exitCode == 0)
        let files = plan.output.split(separator: "\n").filter { $0.hasPrefix(">f") || $0.hasPrefix("<f") }
        #expect(files.count == 2)
        #expect(files.compactMap { Int($0.split(separator: "\t")[1]) }.reduce(0, +) == 13)
        let result = PosixSpawn.captureAll(executablePath: executable,
            arguments: RsyncArgs.make(item: item, dry: false, forProgress: true,
                                     supportsProgress2: RsyncTool.supportsProgress2(executablePath: executable)).0)
        #expect(result.exitCode == 0)
        #expect(try Data(contentsOf: destination.appendingPathComponent("Example.photoslibrary/originals/example.jpg")) == Data("image".utf8))
    }
}

import Foundation
import Testing

@testable import ArchiveCore

struct Fixture {
    let root: URL
    let service: ArchiveService
    let executable: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SevenZipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        executable =
            ProcessInfo.processInfo.environment["SEVENZIP_ENGINE"].map { URL(fileURLWithPath: $0) }
            ?? package.appendingPathComponent("Vendor/7zip/7zz")
        let recoveryExecutable =
            ProcessInfo.processInfo.environment["RECOVERY_ENGINE"].map { URL(fileURLWithPath: $0) }
            ?? package.appendingPathComponent("build/recovery/rz")
        let rarExecutable = ProcessInfo.processInfo.environment["RAR_ENGINE"].map { URL(fileURLWithPath: $0) }
            ?? package.appendingPathComponent("Vendor/rar/rar")
        service = ArchiveService(executable: executable, recoveryExecutable: recoveryExecutable, rarExecutable: rarExecutable)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func file(_ path: String, contents: String = "七个文件，打包成一份。\n") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }
}

@Test(arguments: ArchiveFormat.allCases)
func roundTrip(format: ArchiveFormat) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let original = try fixture.file("资料 空格/子目录/你好.txt")
    _ = try fixture.file("资料 空格/-file[1]*?.txt", contents: "literal wildcards")
    _ = try fixture.file("资料 空格/@list.txt", contents: "not a listfile")
    let source = fixture.root.appendingPathComponent("资料 空格", isDirectory: true)
    let archive = fixture.root.appendingPathComponent("result.\(format.rawValue)")
    _ = try await fixture.service.compress([source], to: archive, options: CompressionOptions(format: format))
    let listing = try await fixture.service.list(archive)
    #expect(!listing.isEncrypted)
    #expect(listing.fileCount == 3)
    #expect(listing.entries.contains { $0.path == "资料 空格/子目录/你好.txt" })
    try await fixture.service.test(archive)
    let output = fixture.root.appendingPathComponent("extracted", isDirectory: true)
    _ = try await fixture.service.extract(archive, to: output)
    #expect(try Data(contentsOf: original) == Data(contentsOf: output.appendingPathComponent("资料 空格/子目录/你好.txt")))
    #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("资料 空格/-file[1]*?.txt").path))
}

@Test(arguments: [ArchiveFormat.sevenZip, .zip, .recovery, .rar])
func encryptedRoundTrip(format: ArchiveFormat) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("secret.txt")
    let archive = fixture.root.appendingPathComponent("encrypted.\(format.rawValue)")
    let password = "secret"
    _ = try await fixture.service.compress(
        [source], to: archive,
        options: CompressionOptions(format: format, password: password))
    let listing = try await fixture.service.list(archive, password: password)
    #expect(listing.isEncrypted)
    #expect(listing.entries.first?.path == "secret.txt")
    await #expect(throws: ArchiveError.self) { try await fixture.service.test(archive, password: "incorrect") }
    try await fixture.service.test(archive, password: password)
    let output = fixture.root.appendingPathComponent("output", isDirectory: true)
    _ = try await fixture.service.extract(archive, to: output, password: password)
    #expect(try Data(contentsOf: source) == Data(contentsOf: output.appendingPathComponent("secret.txt")))
    if format == .sevenZip {
        await #expect(throws: ArchiveError.self) { try await fixture.service.list(archive) }
    } else if format == .recovery {
        let locked = try await fixture.service.list(archive)
        #expect(locked.isLocked && locked.isEncrypted && locked.entries.isEmpty)
    }
}

@Test func refusesExistingDestination() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source.txt")
    let existing = try fixture.file("keep.7z", contents: "do not replace")
    await #expect(throws: ArchiveError.self) {
        try await fixture.service.compress([source], to: existing, options: CompressionOptions())
    }
    #expect(try String(contentsOf: existing, encoding: .utf8) == "do not replace")
}

@Test func refusesRecursiveOutput() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("folder/file.txt")
    let folder = fixture.root.appendingPathComponent("folder", isDirectory: true)
    await #expect(throws: ArchiveError.self) {
        try await fixture.service.compress(
            [folder], to: folder.appendingPathComponent("self.7z"), options: CompressionOptions())
    }
}

@Test func preservesDuplicateNamesFromDifferentFolders() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let left = try fixture.file("left/same.txt", contents: "left")
    let right = try fixture.file("right/same.txt", contents: "right")
    let archive = fixture.root.appendingPathComponent("both.7z")
    _ = try await fixture.service.compress([left, right], to: archive, options: CompressionOptions())
    let listing = try await fixture.service.list(archive)
    #expect(Set(listing.entries.filter { !$0.isDirectory }.map(\.path)) == ["left/same.txt", "right/same.txt"])
}

@Test func rejectsLinksBeforeExtraction() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("target.txt")
    let link = fixture.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")
    let archive = fixture.root.appendingPathComponent("links.tar")
    _ = try await fixture.service.compress([link], to: archive, options: CompressionOptions(format: .tar))
    let listing = try await fixture.service.list(archive)
    #expect(listing.entries.contains { $0.isLink })
    let output = fixture.root.appendingPathComponent("blocked", isDirectory: true)
    await #expect(throws: ArchiveError.self) { try await fixture.service.extract(archive, to: output) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test func corruptArchiveDoesNotLeaveOutput() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let archive = try fixture.file("broken.7z", contents: "this is not an archive")
    let output = fixture.root.appendingPathComponent("output", isDirectory: true)
    await #expect(throws: ArchiveError.self) { try await fixture.service.extract(archive, to: output) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).filter { $0.hasPrefix(".7zip-") }.isEmpty
    )
}

@Test func cancellationTerminatesChild() async throws {
    let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sleep"))
    let start = ContinuousClock.now
    let task = Task { try await runner.run(arguments: ["30"]) }
    try await Task.sleep(for: .milliseconds(120))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(5))
}

@Test func alreadyCancelledTaskDoesNotLaunch() async throws {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await ProcessRunner(executable: URL(fileURLWithPath: "/does/not/exist")).run(arguments: [])
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test(arguments: ["../escape", "/tmp/escape", "C:\\Windows\\file", "a/../../b", "a\\..\\b", "line\nbreak", ""])
func unsafePaths(path: String) {
    #expect(throws: ArchiveError.self) { try ArchivePath.validate(path) }
}

@Test func parserPreservesEqualsAndEmptyArchive() throws {
    let url = URL(fileURLWithPath: "/test.7z")
    let parsed = try ListingParser.parse(
        "Type = 7z\nPhysical Size = 100\n----------\nPath = a = b.txt\nSize = 8\nEncrypted = +\n\n", url: url)
    #expect(parsed.entries.first?.path == "a = b.txt")
    #expect(parsed.isEncrypted)
    #expect(try ListingParser.parse("Type = 7z\n----------\n", url: url).entries.isEmpty)
    #expect(throws: ArchiveError.self) {
        try ListingParser.parse("----------\nPath = a\nmalicious newline\nSize = 2\n", url: url)
    }
    #expect(throws: ArchiveError.self) {
        try ListingParser.parse("----------\nPath = a\nPath = b\n", url: url)
    }
}

@Test(arguments: ["traversal", "absolute"])
func maliciousZIPCannotExtract(name: String) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let archive = try #require(
        Bundle.module.url(forResource: name + ".zip", withExtension: "fixture", subdirectory: "Fixtures"))
    let output = fixture.root.appendingPathComponent("blocked", isDirectory: true)
    do {
        _ = try await fixture.service.extract(archive, to: output)
        Issue.record("Unsafe archive was extracted")
    } catch ArchiveError.unsafeEntry {}
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escaped.txt").path))
}

@Test func parentAndChildSourcesAreNotDuplicated() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let child = try fixture.file("folder/child.txt")
    let parent = child.deletingLastPathComponent()
    let archive = fixture.root.appendingPathComponent("single.7z")
    _ = try await fixture.service.compress([parent, child, child], to: archive, options: CompressionOptions())
    #expect(try await fixture.service.list(archive).fileCount == 1)
}

@Test func cancelledCompressionCleansStaging() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = fixture.root.appendingPathComponent("large.bin")
    var generator = SystemRandomNumberGenerator()
    let block = (0..<131_072).map { _ in UInt64.random(in: .min ... .max, using: &generator) }
    let data = block.withUnsafeBytes { Data($0) }
    FileManager.default.createFile(atPath: source.path, contents: nil)
    let handle = try FileHandle(forWritingTo: source)
    for _ in 0..<32 { try handle.write(contentsOf: data) }
    try handle.close()
    let output = fixture.root.appendingPathComponent("cancelled.7z")
    let task = Task {
        try await fixture.service.compress([source], to: output, options: CompressionOptions(level: 9))
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".7zip-") })
}

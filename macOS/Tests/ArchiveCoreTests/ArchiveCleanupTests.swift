import Foundation
import Testing

@testable import ArchiveCore

@Test(arguments: ArchiveFormat.allCases)
func recyclingRequiresSuccessfulVerification(format: ArchiveFormat) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let file = try fixture.file("source/file.txt", contents: "keep this content")
    let folder = file.deletingLastPathComponent()
    let destination = fixture.root.appendingPathComponent("saved.\(format.rawValue)")
    let recycled = fixture.root.appendingPathComponent("recycled")
    var options = CompressionOptions(format: format, deleteSourcesAfterVerification: true)
    if format.supportsPassword && format != .recovery { options.password = "test-password" }
    if format == .recovery {
        options.generateRecoveryKeyFile = true
        options.recoveryVolumeCounts = RecoveryVolumeCounts(data: 2, recovery: 1)
    }
    let output = try await fixture.service.compress([folder, file, folder], to: destination, options: options) { source in
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(source.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
        try FileManager.default.moveItem(at: source, to: recycled)
    }
    #expect(output.path == destination.path)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    let key = options.generateRecoveryKeyFile ? RecoveryArchive.keyFileURL(for: output) : nil
    let extracted = fixture.root.appendingPathComponent("extracted")
    _ = try await fixture.service.extract(output, to: extracted, password: options.password, keyFile: key)
    #expect(try String(contentsOf: extracted.appendingPathComponent("source/file.txt"), encoding: .utf8) == "keep this content")
}

@Test func recyclingIsOptIn() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source.txt")
    _ = try await fixture.service.compress(
        [source], to: fixture.root.appendingPathComponent("saved.zip"), options: CompressionOptions(format: .zip),
        recycle: { _ in Issue.record("Default compression must preserve sources") })
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test(arguments: ["corrupt", "changed", "added", "cancel"])
func failedOrCancelledVerificationPreservesSources(scenario: String) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source/data.txt")
    let folder = source.deletingLastPathComponent()
    let archive = fixture.root.appendingPathComponent("saved.zip")
    let task = Task {
        try await fixture.service.compress(
            [folder], to: archive,
            options: CompressionOptions(format: .zip, deleteSourcesAfterVerification: true),
            progress: { update in
                guard update.message == "正在校验压缩包，原文件暂时保留…" else { return }
                do {
                    switch scenario {
                    case "corrupt": try Data("broken".utf8).write(to: archive)
                    case "changed": try Data("new content".utf8).write(to: source)
                    case "added": try Data().write(to: folder.appendingPathComponent("new.txt"))
                    default: withUnsafeCurrentTask { $0?.cancel() }
                    }
                } catch { Issue.record(error) }
            }
        ) { _ in Issue.record("Sources must be retained") }
    }
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: archive.path))
}

@Test func recyclingRejectsFilteredRARAndSymbolicLinksBeforeCompression() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source/file.txt")
    var options = CompressionOptions(format: .rar, deleteSourcesAfterVerification: true)
    options.rar.excludeMasks = "*.txt"
    let archive = fixture.root.appendingPathComponent("saved.rar")
    await #expect(throws: ArchiveError.self) {
        try await fixture.service.compress([source.deletingLastPathComponent()], to: archive, options: options)
    }
    #expect(!FileManager.default.fileExists(atPath: archive.path))
    let link = fixture.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: ArchiveError.self) { try ArchiveSourceCleanup(sources: [link]) }
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func failedRecycleKeepsArchiveAndRemainingSources() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source.txt")
    let archive = fixture.root.appendingPathComponent("saved.zip")
    await #expect(throws: ArchiveError.self) {
        try await fixture.service.compress(
            [source], to: archive, options: CompressionOptions(format: .zip, deleteSourcesAfterVerification: true)
        ) { _ in throw CocoaError(.fileWriteNoPermission) }
    }
    try await fixture.service.test(archive)
    #expect(FileManager.default.fileExists(atPath: source.path))
}

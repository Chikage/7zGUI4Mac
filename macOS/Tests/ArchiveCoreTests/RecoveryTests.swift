import Foundation
import Testing

@testable import ArchiveCore

@Test func recoveryFormatCapabilities() {
    #expect(ArchiveFormat.recovery.supportsPassword)
    #expect(!ArchiveFormat.recovery.supportsCompressionLevel)
    #expect(CompressionOptions(format: .recovery).recoveryVolumeCounts == .init(data: 10, recovery: 2))
    #expect(ArchiveFormat.allCases.contains(.recovery))
}

@Test func recoverySelectedInputsPreservePathsWithoutOtherFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let left = try fixture.file("left/same.txt", contents: "left")
    let right = try fixture.file("right/same.txt", contents: "right")
    _ = try fixture.file("right/unselected.txt", contents: "do not archive")
    let quoted = try fixture.file("资料/含\"引号.txt")
    let output = fixture.root.appendingPathComponent("selected.rz", isDirectory: false)
    _ = try await fixture.service.compress(
        [left, right, quoted, left], to: output,
        options: CompressionOptions(format: .recovery))
    let container = try RecoveryContainerFixture(output)
    #expect(container.dataVolumes + container.recoveryVolumes == 12)
    let listing = try await fixture.service.list(output)
    #expect(listing.supportsRecovery)
    #expect(!listing.isEncrypted)
    #expect(listing.physicalSize == Int64(container.bytes.count))
    #expect(listing.recoveryDetails?.profile == 5)
    #expect(listing.preservesMetadata)
    let details = try #require(listing.recoveryDetails)
    #expect(Int64(container.volumeSize) == details.volumeSizeBytes)
    #expect(
        Set(listing.entries.filter { !$0.isDirectory }.map(\.path)) == [
            "left/same.txt", "right/same.txt", "资料/含\"引号.txt",
        ])
    let extracted = fixture.root.appendingPathComponent("extracted")
    _ = try await fixture.service.extract(output, to: extracted)
    #expect(try String(contentsOf: extracted.appendingPathComponent("left/same.txt"), encoding: .utf8) == "left")
    #expect(try String(contentsOf: extracted.appendingPathComponent("right/same.txt"), encoding: .utf8) == "right")
}

@Test func recoveryMemberOpenAndRepairMissingDataAndIndex() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source.txt")
    let archive = fixture.root.appendingPathComponent("archive.rz", isDirectory: false)
    _ = try await fixture.service.compress([source], to: archive, options: CompressionOptions(format: .recovery))
    try convertToLegacyRZDirectory(archive)
    try FileManager.default.removeItem(at: archive.appendingPathComponent("d000000.rzv"))
    try FileManager.default.removeItem(at: archive.appendingPathComponent("manifest.rzm"))
    let member = archive.appendingPathComponent("p000000.rzr")
    let listing = try await fixture.service.list(member)
    #expect(listing.url.standardizedFileURL.path == archive.standardizedFileURL.path)
    do {
        try await fixture.service.test(member)
        Issue.record("Missing volume passed verification")
    } catch ArchiveError.recoveryRepairable {}
    let extracted = fixture.root.appendingPathComponent("extract-before-repair")
    await #expect(throws: ArchiveError.self) { try await fixture.service.extract(member, to: extracted) }
    #expect(!FileManager.default.fileExists(atPath: extracted.path))
    let repaired = fixture.root.appendingPathComponent("repaired.rz", isDirectory: false)
    _ = try await fixture.service.repair(member, to: repaired)
    try await fixture.service.test(repaired)
    #expect(!FileManager.default.fileExists(atPath: archive.appendingPathComponent("d000000.rzv").path))
    _ = try await fixture.service.extract(repaired, to: extracted)
    #expect(try Data(contentsOf: extracted.appendingPathComponent("source.txt")) == Data(contentsOf: source))
    await #expect(throws: ArchiveError.self) { try await fixture.service.repair(archive, to: repaired) }
}

@Test func recoveryUnrecoverableDoesNotPublishPartialResult() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source.txt")
    let archive = fixture.root.appendingPathComponent("archive.rz", isDirectory: false)
    _ = try await fixture.service.compress([source], to: archive, options: CompressionOptions(format: .recovery))
    for name in ["d000000.rzv", "p000000.rzr", "p000001.rzr"] {
        try damageRZMember(in: archive, name: name)
    }
    do {
        try await fixture.service.test(archive)
        Issue.record("Unrecoverable archive passed verification")
    } catch ArchiveError.recoveryUnrecoverable {}
    let output = fixture.root.appendingPathComponent("failed.rz", isDirectory: false)
    do {
        _ = try await fixture.service.repair(archive, to: output)
        Issue.record("Unrecoverable archive was repaired")
    } catch ArchiveError.recoveryUnrecoverable {}
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".7zip-") })
}

@Test func recoveryRejectsUnsupportedOptionsAndRecursiveOutput() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let file = try fixture.file("input/data.txt")
    for options in [
        CompressionOptions(format: .recovery, password: "invalid\npassword"),
        CompressionOptions(format: .recovery, recoveryVolumeCounts: .init(data: 0, recovery: 1)),
        CompressionOptions(format: .recovery, recoveryVolumeCounts: .init(data: 1, recovery: 2)),
    ] {
        await #expect(throws: ArchiveError.self) {
            try await fixture.service.compress(
                [file], to: fixture.root.appendingPathComponent("invalid.rz"), options: options)
        }
    }
    let folder = file.deletingLastPathComponent()
    await #expect(throws: ArchiveError.self) {
        try await fixture.service.compress(
            [folder], to: folder.appendingPathComponent("recursive.rz"), options: CompressionOptions(format: .recovery))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["data.txt"])
}

@Test func recoveryMissingEngineHasActionableError() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let file = try fixture.file("data.txt")
    let service = ArchiveService(
        executable: fixture.executable, recoveryExecutable: fixture.root.appendingPathComponent("missing-rz"))
    do {
        _ = try await service.compress(
            [file], to: fixture.root.appendingPathComponent("output.rz"), options: CompressionOptions(format: .recovery)
        )
        Issue.record("Missing engine succeeded")
    } catch ArchiveError.recoveryEngineMissing {}
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".7zip-") })
}

@Test func recoveryCancellationCleansOuterAndInnerStages() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let file = try fixture.file("sparse.bin", contents: "")
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 2 * 1024 * 1024 * 1024)
    try handle.close()
    let output = fixture.root.appendingPathComponent("cancelled.rz", isDirectory: false)
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let task = Task {
        try await fixture.service.compress([file], to: output, options: CompressionOptions(format: .recovery)) { _ in
            continuation.yield(())
        }
    }
    for await _ in stream {
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        break
    }
    continuation.finish()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".7zip-") })
}

func recoveryListingJSON(_ overrides: [String: Any] = [:]) throws -> String {
    let recovery: [String: Any] = [
        "profile": 5, "dataBytes": 262_144, "payloadBytes": 131_072,
        "volumeLimitBytes": 0, "dataVolumes": 4, "recoveryVolumes": 2,
        "requestedMode": 2, "requestedValue": 0, "toleratedVolumeLosses": 2,
        "volumeSizeBytes": 132_056, "metadataBytesPerVolume": 66_520, "contentLimitBytes": Int64(1) << 40,
    ]
    let listing: [String: Any] = [
        "version": 1, "entries": [], "recovery": recovery, "encrypted": false, "locked": false,
        "encryptionSuite": 0, "requiresKeyFile": false, "preservesMetadata": false, "directoryUnavailable": false,
    ]
    return String(decoding: try JSONSerialization.data(withJSONObject: listing.merging(overrides) { _, new in new }), as: UTF8.self)
}

@Test func recoveryListingRejectsMalformedContracts() throws {
    let url = URL(fileURLWithPath: "/archive.rz")
    let invalid: [[String: Any]] = [
        ["version": 2], ["recovery": NSNull()],
        ["entries": [["path": "../escape", "size": 1, "isDirectory": false]]],
        ["entries": [["path": "file", "size": -1, "isDirectory": false]]],
        ["entries": [["path": "folder", "size": 1, "isDirectory": true]]],
        ["entries": Array(repeating: ["path": "file", "size": 0, "isDirectory": false], count: 2)],
    ]
    for fields in invalid {
        #expect(throws: ArchiveError.self) { try RecoveryListingParser.parse(recoveryListingJSON(fields), url: url, physicalSize: 0) }
    }
    #expect(try RecoveryListingParser.parse(recoveryListingJSON(), url: url, physicalSize: 0).entries.isEmpty)
    #expect(RecoveryArchive.directory(for: url.appendingPathComponent("p000000.rzr"))?.path == url.path)
}

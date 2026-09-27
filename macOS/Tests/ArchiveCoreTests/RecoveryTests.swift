import Foundation
import Testing

@testable import ArchiveCore

@Test func recoveryFormatCapabilities() {
    #expect(ArchiveFormat.recovery.supportsPassword)
    #expect(!ArchiveFormat.recovery.supportsCompressionLevel)
    #expect(CompressionOptions(format: .recovery).recoveryVolumeSizeBytes == 64 * 1024 * 1024)
    #expect(ArchiveFormat.allCases.contains(.recovery))
}

@Test func recoverySelectedInputsPreservePathsWithoutOtherFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let left = try fixture.file("left/same.txt", contents: "left")
    let right = try fixture.file("right/same.txt", contents: "right")
    _ = try fixture.file("right/unselected.txt", contents: "do not archive")
    let quoted = try fixture.file("资料/含\"引号.txt")
    let output = fixture.root.appendingPathComponent("selected.rz", isDirectory: true)
    _ = try await fixture.service.compress(
        [left, right, quoted, left], to: output,
        options: CompressionOptions(format: .recovery, recoveryVolumeSizeBytes: 3 * 1024 * 1024))
    let volumes = try FileManager.default.contentsOfDirectory(
        at: output, includingPropertiesForKeys: [.fileSizeKey]
    ).filter { ["rzv", "rzr"].contains($0.pathExtension) }
    #expect(volumes.count == 2)
    #expect(try volumes.allSatisfy { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 3 * 1024 * 1024 })
    let listing = try await fixture.service.list(output)
    #expect(listing.supportsRecovery)
    #expect(!listing.isEncrypted)
    #expect(listing.physicalSize > 0)
    #expect(listing.recoveryDetails?.profile == 3)
    #expect(listing.preservesMetadata)
    let details = try #require(listing.recoveryDetails)
    #expect(details.volumeLimitBytes == 3_145_728)
    #expect(
        Set(listing.entries.filter { !$0.isDirectory }.map(\.path)) == [
            "left/same.txt", "right/same.txt", "资料/含\"引号.txt",
        ])
    let extracted = fixture.root.appendingPathComponent("extracted")
    _ = try await fixture.service.extract(output, to: extracted)
    #expect(try String(contentsOf: extracted.appendingPathComponent("left/same.txt"), encoding: .utf8) == "left")
    #expect(try String(contentsOf: extracted.appendingPathComponent("right/same.txt"), encoding: .utf8) == "right")
}

@Test func customRecoveryInputsUseExactUnits() throws {
    #expect(try RecoveryInput.volumeBytes("1.5", unit: .mib) == 1_572_864)
    #expect(try RecoveryInput.volumeBytes("1.25", unit: .gib) == 1_342_177_280)
    #expect(try RecoveryInput.volumeBytes("16", unit: .gib) == 17_179_869_184)
    #expect(try RecoveryInput.sizeBytes("500", unit: .kib) == 512_000)
    #expect(try RecoveryInput.percentage("7.5") == .percentage(basisPoints: 750))
    #expect(try RecoveryInput.percentage("33.33").arguments() == ["--recovery-percent", "33.33"])
    #expect(try RecoveryPayload.bytes(512_000).arguments() == ["--recovery-bytes", "512000"])
    for text in ["", "0", "-1", "NaN", "1e3", "1,000", "1.2.3", "0.5", "16385"] {
        #expect(throws: ArchiveError.self) { try RecoveryInput.volumeBytes(text, unit: .mib) }
    }
    for text in ["0", "0.5", "100.01", "7.123", "inf", ""] {
        #expect(throws: ArchiveError.self) { try RecoveryInput.percentage(text) }
    }
}

@Test func customRecoveryPayloadRoundTrip() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let file = try fixture.file("random.bin", contents: "")
    var value: UInt64 = 0x1234_5678_9abc_def0
    var data = Data(capacity: 2 * 1024 * 1024)
    for _ in 0..<(2 * 1024 * 1024) {
        value ^= value << 13
        value ^= value >> 7
        value ^= value << 17
        data.append(UInt8(truncatingIfNeeded: value))
    }
    try data.write(to: file)
    for (index, payload) in [RecoveryPayload.percentage(basisPoints: 750), .bytes(500 * 1024)].enumerated() {
        let archive = fixture.root.appendingPathComponent("custom-\(index).rz", isDirectory: true)
        _ = try await fixture.service.compress(
            [file], to: archive,
            options: CompressionOptions(
                format: .recovery, recoveryVolumeSizeBytes: 1_572_864, recoveryPayload: payload))
        let listing = try await fixture.service.list(archive)
        let details = try #require(listing.recoveryDetails)
        #expect(details.volumeLimitBytes == 1_572_864)
        if index == 0 {
            #expect(details.requestedMode == 0)
            #expect(details.requestedValue == 750)
            #expect(details.payloadBytes == ((details.dataBytes / 65_536 * 750 + 9999) / 10_000) * 65_536)
        } else {
            #expect(details.requestedMode == 1)
            #expect(details.payloadBytes == 524_288)
        }
        try await fixture.service.test(archive)
        let output = fixture.root.appendingPathComponent("output-\(index)")
        _ = try await fixture.service.extract(archive, to: output)
        #expect(try Data(contentsOf: output.appendingPathComponent("random.bin")) == data)
    }
}

@Test func excessiveRecoveryCapacityHasLocalizedError() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let file = try fixture.file("tiny.txt")
    do {
        _ = try await fixture.service.compress(
            [file], to: fixture.root.appendingPathComponent("failed.rz"),
            options: CompressionOptions(format: .recovery, recoveryPayload: .bytes(1024 * 1024)))
        Issue.record("Excessive recovery capacity was accepted")
    } catch ArchiveError.invalidInput(let message) {
        #expect(message.contains("最多可设置"))
    }
}

@Test func recoveryMemberOpenAndRepairMissingDataAndIndex() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source.txt")
    let archive = fixture.root.appendingPathComponent("archive.rz", isDirectory: true)
    _ = try await fixture.service.compress([source], to: archive, options: CompressionOptions(format: .recovery))
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
    let repaired = fixture.root.appendingPathComponent("repaired.rz", isDirectory: true)
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
    let archive = fixture.root.appendingPathComponent("archive.rz", isDirectory: true)
    _ = try await fixture.service.compress([source], to: archive, options: CompressionOptions(format: .recovery))
    for name in ["d000000.rzv", "p000000.rzr"] {
        try FileManager.default.removeItem(at: archive.appendingPathComponent(name))
    }
    do {
        try await fixture.service.test(archive)
        Issue.record("Unrecoverable archive passed verification")
    } catch ArchiveError.recoveryUnrecoverable {}
    let output = fixture.root.appendingPathComponent("failed.rz", isDirectory: true)
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
        CompressionOptions(format: .recovery, recoveryVolumeSizeBytes: 0),
        CompressionOptions(format: .recovery, recoveryVolumeSizeBytes: 16 * 1024 * 1024 * 1024 + 1),
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
    let output = fixture.root.appendingPathComponent("cancelled.rz", isDirectory: true)
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

@Test func recoveryListingRejectsMalformedContracts() throws {
    let url = URL(fileURLWithPath: "/archive.rz", isDirectory: true)
    for json in [
        #"{"version":2,"entries":[]}"#,
        #"{"version":1,"entries":[{"path":"../escape","size":1,"isDirectory":false}]}"#,
        #"{"version":1,"entries":[{"path":"file","size":-1,"isDirectory":false}]}"#,
        #"{"version":1,"entries":[{"path":"folder","size":1,"isDirectory":true}]}"#,
        #"{"version":1,"entries":[{"path":"file","size":0,"isDirectory":false},{"path":"file","size":0,"isDirectory":false}]}"#,
    ] {
        #expect(throws: ArchiveError.self) { try RecoveryListingParser.parse(json, url: url, physicalSize: 0) }
    }
    #expect(try RecoveryListingParser.parse(#"{"version":1,"entries":[]}"#, url: url, physicalSize: 0).entries.isEmpty)
    #expect(RecoveryArchive.directory(for: url.appendingPathComponent("p000000.rzr"))?.path == url.path)
}

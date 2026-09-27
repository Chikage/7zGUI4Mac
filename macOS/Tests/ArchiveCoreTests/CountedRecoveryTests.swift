import Foundation
import Testing

@testable import ArchiveCore

@Test func countedRecoveryInputsRejectInvalidCounts() throws {
    #expect(CompressionOptions(format: .recovery).countedRecoveryProfile == .paged)
    #expect(try RecoveryInput.volumeCount(" 10 ") == 10)
    #expect(
        try RecoveryVolumeCounts(data: 10, recovery: 2).arguments() == [
            "--data-volumes", "10", "--recovery-volumes", "2",
        ])
    for value in ["", "0", "-1", "101", "2.0", "1e2", "1,000", "１２", "999999999999999999999"] {
        #expect(throws: ArchiveError.self) { try RecoveryInput.volumeCount(value) }
    }
    for counts in [
        RecoveryVolumeCounts(data: 0, recovery: 1), .init(data: 4, recovery: 5), .init(data: 101, recovery: 1),
        .init(data: 4, recovery: 0),
    ] {
        #expect(throws: ArchiveError.self) { try counts.arguments() }
    }
}

@Test(arguments: [CountedRecoveryProfile.compatible, .paged])
func countedRecoveryCreatesEqualVolumesAndRepairsTwoLosses(profile: CountedRecoveryProfile) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let file = try fixture.file("data.txt", contents: String(repeating: "equal volumes\n", count: 1000))
    let archive = fixture.root.appendingPathComponent("counted.rz")
    _ = try await fixture.service.compress(
        [file], to: archive,
        options: CompressionOptions(
            format: .recovery, recoveryVolumeCounts: .init(data: 4, recovery: 2), countedRecoveryProfile: profile))
    let listing = try await fixture.service.list(archive)
    let details = try #require(listing.recoveryDetails)
    #expect(details.profile == profile.rawValue && details.dataVolumes == 4 && details.recoveryVolumes == 2)
    #expect(details.hasCountedVolumes)
    #expect(details.toleratedVolumeLosses == 2)
    let volumes = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: [.fileSizeKey])
        .filter { ["rzv", "rzr"].contains($0.pathExtension) }
    #expect(volumes.count == 6)
    let sizes = try Set(volumes.map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize })
    #expect(sizes.count == 1)
    #expect(Int64(try #require(sizes.first.flatMap { $0 })) == details.volumeSizeBytes)
    try FileManager.default.removeItem(at: archive.appendingPathComponent("d000000.rzv"))
    try FileManager.default.removeItem(at: archive.appendingPathComponent("p000001.rzr"))
    try FileManager.default.removeItem(at: archive.appendingPathComponent("manifest.rzm"))
    do {
        try await fixture.service.test(archive)
        Issue.record("Missing volumes passed verification")
    } catch ArchiveError.recoveryRepairable {}
    let repaired = fixture.root.appendingPathComponent("repaired.rz")
    _ = try await fixture.service.repair(archive, to: repaired)
    let output = fixture.root.appendingPathComponent("output")
    _ = try await fixture.service.extract(repaired, to: output)
    #expect(try Data(contentsOf: output.appendingPathComponent("data.txt")) == Data(contentsOf: file))
}

@Test func countedRecoveryDefaultProfileAutomaticallyUnlocksGeneratedKey() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let file = try fixture.file("private.txt", contents: "Profile 5 automatic key pairing")
    let archive = fixture.root.appendingPathComponent("private.rz")
    let encryption: RecoveryEncryption = try await fixture.service.supportsRecoveryAES() ? .dual : .standard
    _ = try await fixture.service.compress(
        [file], to: archive,
        options: CompressionOptions(
            format: .recovery, recoveryEncryption: encryption, generateRecoveryKeyFile: true,
            recoveryVolumeCounts: .init(data: 4, recovery: 2)))
    let listing = try await fixture.service.list(archive)
    #expect(listing.recoveryDetails?.profile == 5)
    #expect(listing.requiresKeyFile && listing.isEncrypted && !listing.isLocked)
    #expect(listing.recoveryEncryption == encryption)
    try FileManager.default.removeItem(at: archive.appendingPathComponent("d000000.rzv"))
    let repaired = fixture.root.appendingPathComponent("repaired.rz")
    _ = try await fixture.service.repair(archive, to: repaired)
    try await fixture.service.test(repaired)
    let output = fixture.root.appendingPathComponent("output")
    _ = try await fixture.service.extract(repaired, to: output)
    #expect(try Data(contentsOf: output.appendingPathComponent("private.txt")) == Data(contentsOf: file))
}

@Test func pagedRecoveryListingValidatesProtectedIndexGeometryAndLargeContent() throws {
    let url = URL(fileURLWithPath: "/archive.rz")
    func parse(_ recovery: [String: Any]) throws -> ArchiveListing {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [], "recovery": recovery])
        return try RecoveryListingParser.parse(String(decoding: data, as: UTF8.self), url: url, physicalSize: 0)
    }
    func details(stripes: Int64) -> [String: Any] {
        let hashPages = (stripes * 6 * 32 + 65_535) / 65_536
        let indexRecords = (hashPages * 65_536 + 44 + hashPages * 32 + 262_143) / 262_144
        let metadata = 240 + 2 * 340 + 32 * stripes + 65_568 * indexRecords
        return [
            "profile": 5, "dataBytes": stripes * 4 * 65_536, "payloadBytes": stripes * 2 * 65_536,
            "volumeLimitBytes": 0, "dataVolumes": 4, "recoveryVolumes": 2,
            "requestedMode": 2, "requestedValue": 0, "toleratedVolumeLosses": 2,
            "volumeSizeBytes": stripes * 65_536 + metadata, "metadataBytesPerVolume": metadata,
            "contentLimitBytes": Int64(1024 * 1024 * 1024 * 1024),
        ]
    }
    let valid = details(stripes: 1)
    #expect(try parse(valid).recoveryDetails?.profile == 5)
    #expect(try parse(details(stripes: 100 * 1024 * 1024 * 1024 / 262_144)).recoveryDetails?.hasCountedVolumes == true)
    let invalidFields: [(String, Int64)] = [
        ("toleratedVolumeLosses", 3), ("dataVolumes", 0), ("dataVolumes", 101), ("recoveryVolumes", 5),
        ("dataBytes", .max), ("volumeSizeBytes", .max), ("dataBytes", 262_145),
        ("payloadBytes", 65_536), ("requestedMode", 0), ("volumeLimitBytes", 1_048_576),
        ("metadataBytesPerVolume", -1), ("metadataBytesPerVolume", .min), ("metadataBytesPerVolume", .max),
        ("metadataBytesPerVolume", 65_841), ("contentLimitBytes", 64 * 1024 * 1024 * 1024),
    ]
    for (key, value) in invalidFields {
        var invalid = valid
        invalid[key] = value
        #expect(throws: ArchiveError.self) { try parse(invalid) }
    }
    for key in ["metadataBytesPerVolume", "contentLimitBytes", "toleratedVolumeLosses"] {
        var invalid = valid
        invalid.removeValue(forKey: key)
        #expect(throws: ArchiveError.self) { try parse(invalid) }
    }
    #expect(throws: ArchiveError.self) { try parse(details(stripes: 5_000_000)) }
}

@Test func countedRecoveryListingRejectsFalseGuarantees() throws {
    let valid: [String: Any] = [
        "profile": 4, "dataBytes": 262144, "payloadBytes": 131072,
        "volumeLimitBytes": 0, "dataVolumes": 4, "recoveryVolumes": 2,
        "requestedMode": 2, "requestedValue": 0, "volumeSizeBytes": 67000, "toleratedVolumeLosses": 2,
    ]
    let url = URL(fileURLWithPath: "/archive.rz")
    func parse(_ recovery: [String: Any]) throws -> ArchiveListing {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [], "recovery": recovery])
        return try RecoveryListingParser.parse(String(decoding: data, as: UTF8.self), url: url, physicalSize: 0)
    }
    #expect(try parse(valid).recoveryDetails?.profile == 4)
    for (key, value) in [
        ("toleratedVolumeLosses", 3), ("dataVolumes", 0), ("dataVolumes", 101),
        ("recoveryVolumes", 5), ("volumeSizeBytes", 65536), ("dataBytes", 262145),
        ("payloadBytes", 65536), ("requestedMode", 0), ("volumeLimitBytes", 1_048_576),
    ] {
        var invalid = valid
        invalid[key] = value
        #expect(throws: ArchiveError.self) { try parse(invalid) }
    }
    var missing = valid
    missing.removeValue(forKey: "toleratedVolumeLosses")
    #expect(throws: ArchiveError.self) { try parse(missing) }
}

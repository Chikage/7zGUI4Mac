import Darwin
import Foundation
import Testing

@testable import ArchiveCore

@Test(arguments: RecoveryEncryption.allCases)
func keyFileCreationAutoUnlockManualUnlockAndRepair(encryption: RecoveryEncryption) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("private.txt")
    let archive = fixture.root.appendingPathComponent("archive.rz")
    let key = RecoveryArchive.keyFileURL(for: archive)
    _ = try await fixture.service.compress(
        [source], to: archive,
        options: CompressionOptions(format: .recovery, recoveryEncryption: encryption, generateRecoveryKeyFile: true))
    var info = stat()
    #expect(lstat(key.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    let automatic = try await fixture.service.list(archive)
    #expect(automatic.requiresKeyFile && automatic.isEncrypted && !automatic.isLocked)
    #expect(automatic.recoveryEncryption == encryption)
    let renamed = fixture.root.appendingPathComponent("renamed.rz")
    try FileManager.default.moveItem(at: archive, to: renamed)
    #expect(try await !fixture.service.list(renamed).isLocked)
    let backup = fixture.root.appendingPathComponent("backup/key.saved")
    try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: key, to: backup)
    let locked = try await fixture.service.list(renamed)
    #expect(locked.isLocked && locked.entries.isEmpty && locked.requiresKeyFile)
    await #expect(throws: ArchiveError.self) { try await fixture.service.test(renamed) }
    let output = fixture.root.appendingPathComponent("out")
    do {
        _ = try await fixture.service.extract(renamed, to: output)
        Issue.record("Missing key was accepted")
    } catch ArchiveError.keyFileRequired {}
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try await !fixture.service.list(renamed, keyFile: backup).isLocked)
    try FileManager.default.removeItem(at: renamed.appendingPathComponent("d000000.rzv"))
    let repaired = fixture.root.appendingPathComponent("repaired.rz")
    _ = try await fixture.service.repair(renamed, to: repaired)
    #expect(try await fixture.service.list(repaired).isLocked)
    try FileManager.default.moveItem(at: backup, to: key)
    _ = try await fixture.service.extract(repaired, to: output)
    #expect(try Data(contentsOf: output.appendingPathComponent("private.txt")) == Data(contentsOf: source))
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".7zip-") })
}

@Test func keyFileCollisionAndWrongKeyDoNotPublish() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("private.txt")
    let archive = fixture.root.appendingPathComponent("archive.rz")
    let key = RecoveryArchive.keyFileURL(for: archive)
    try Data("keep".utf8).write(to: key)
    let options = CompressionOptions(format: .recovery, generateRecoveryKeyFile: true)
    await #expect(throws: ArchiveError.self) {
        try await fixture.service.compress([source], to: archive, options: options)
    }
    #expect(try Data(contentsOf: key) == Data("keep".utf8))
    #expect(!FileManager.default.fileExists(atPath: archive.path))
    try FileManager.default.removeItem(at: key)
    _ = try await fixture.service.compress([source], to: archive, options: options)
    let other = fixture.root.appendingPathComponent("other.rz")
    _ = try await fixture.service.compress([source], to: other, options: options)
    let output = fixture.root.appendingPathComponent("wrong")
    do {
        _ = try await fixture.service.extract(archive, to: output, keyFile: RecoveryArchive.keyFileURL(for: other))
        Issue.record("Wrong archive's key accepted")
    } catch ArchiveError.keyFileRequired {}
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

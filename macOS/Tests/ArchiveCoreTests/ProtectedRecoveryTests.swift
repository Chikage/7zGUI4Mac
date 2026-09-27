import Darwin
import Foundation
import Testing

@testable import ArchiveCore

@Test(arguments: RecoveryEncryption.allCases)
func encryptedRecoveryCanRepairBeforeUnlocking(encryption: RecoveryEncryption) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("private-name.txt", contents: "private content")
    let archive = fixture.root.appendingPathComponent("encrypted.rz", isDirectory: true)
    _ = try await fixture.service.compress(
        [source], to: archive,
        options: CompressionOptions(format: .recovery, password: "true", recoveryEncryption: encryption))
    let locked = try await fixture.service.list(archive)
    #expect(locked.isEncrypted && locked.isLocked && locked.preservesMetadata)
    #expect(locked.recoveryEncryption == encryption)
    #expect(locked.entries.isEmpty)
    do {
        _ = try await fixture.service.list(archive, password: "wrong")
        Issue.record("Wrong password unlocked RZ")
    } catch ArchiveError.passwordRequired {}
    let unlocked = try await fixture.service.list(archive, password: "true")
    #expect(!unlocked.isLocked && unlocked.isEncrypted)
    #expect(unlocked.recoveryEncryption == encryption)
    #expect(unlocked.entries.first?.path == "private-name.txt")
    try FileManager.default.removeItem(at: archive.appendingPathComponent("d000000.rzv"))
    let stillLocked = try await fixture.service.list(archive)
    #expect(stillLocked.isLocked)
    let repaired = fixture.root.appendingPathComponent("fixed.rz", isDirectory: true)
    _ = try await fixture.service.repair(archive, to: repaired)
    try await fixture.service.test(repaired, password: "true")
    let output = fixture.root.appendingPathComponent("out")
    let result = try await fixture.service.extract(repaired, to: output, password: "true")
    #expect(result.metadataWarningCount == 0)
    #expect(try Data(contentsOf: output.appendingPathComponent("private-name.txt")) == Data(contentsOf: source))
}

@Test func dualEncryptionRequiresPasswordAndCannotSilentlyDowngrade() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("secret.txt")
    let archive = fixture.root.appendingPathComponent("dual.rz")
    do {
        _ = try await fixture.service.compress(
            [source], to: archive, options: CompressionOptions(format: .recovery, recoveryEncryption: .dual))
        Issue.record("Dual encryption accepted an empty password")
    } catch ArchiveError.invalidInput(let message) { #expect(message.contains("密码")) }
    #expect(!FileManager.default.fileExists(atPath: archive.path))
    let helper = try fixture.file(
        "noaes",
        contents: """
            #!/bin/sh
            if [ "$1" = "--capabilities" ]; then
                echo '{"version":1,"aes256gcm":false}'
                exit 0
            fi
            echo 'unexpected crypto operation' >&2
            exit 99
            """)
    #expect(chmod(helper.path, 0o700) == 0)
    let service = ArchiveService(executable: fixture.executable, recoveryExecutable: helper)
    #expect(try await !service.supportsRecoveryAES())
    do {
        _ = try await service.compress(
            [source], to: archive,
            options: CompressionOptions(format: .recovery, password: "test", recoveryEncryption: .dual))
        Issue.record("Dual encryption silently downgraded on unsupported hardware")
    } catch ArchiveError.invalidInput(let message) { #expect(message.contains("不支持 AES")) }
    #expect(!FileManager.default.fileExists(atPath: archive.path))
}

@Test func recoveryListingRejectsUnknownOrContradictoryEncryptionSuites() throws {
    for json in [
        #"{"version":1,"encrypted":true,"locked":true,"encryptionSuite":99,"entries":[]}"#,
        #"{"version":1,"encrypted":false,"encryptionSuite":2,"entries":[]}"#,
        #"{"version":1,"encrypted":true,"encryptionSuite":0,"entries":[]}"#,
    ] {
        #expect(throws: ArchiveError.self) {
            try RecoveryListingParser.parse(json, url: URL(fileURLWithPath: "/invalid.rz"), physicalSize: 0)
        }
    }
}

@Test func recoveryPreservesModeAndBinaryAttributes() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("attributes.txt")
    #expect(chmod(source.path, 0o640) == 0)
    let value = Data([0, 1, 2, 255, 0, 30])
    let status = value.withUnsafeBytes { setxattr(source.path, "user.rz-test", $0.baseAddress, $0.count, 0, 0) }
    #expect(status == 0)
    let archive = fixture.root.appendingPathComponent("attrs.rz", isDirectory: true)
    _ = try await fixture.service.compress([source], to: archive, options: CompressionOptions(format: .recovery))
    let out = fixture.root.appendingPathComponent("out")
    let result = try await fixture.service.extract(archive, to: out)
    #expect(result.metadataWarningCount == 0)
    let file = out.appendingPathComponent("attributes.txt")
    var info = stat()
    #expect(lstat(file.path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o640)
    var actual = Data(count: value.count)
    let size = actual.withUnsafeMutableBytes { getxattr(file.path, "user.rz-test", $0.baseAddress, $0.count, 0, 0) }
    #expect(size == value.count && actual == value)
}

@Test func metadataWarningsKeepExtractedContentAndAreLocalized() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("special.txt")
    #expect(chmod(source.path, 0o4755) == 0)
    let archive = fixture.root.appendingPathComponent("special.rz", isDirectory: true)
    _ = try await fixture.service.compress(
        [source], to: archive, options: CompressionOptions(format: .recovery, password: "true"))
    let result = try await fixture.service.extract(
        archive, to: fixture.root.appendingPathComponent("out"), password: "true")
    #expect(result.metadataWarningCount > 0)
    #expect(result.metadataWarnings.contains { $0.contains("特殊权限位") })
    #expect(try Data(contentsOf: result.url.appendingPathComponent("special.txt")) == Data(contentsOf: source))
    let skipped = try await fixture.service.extract(
        archive, to: fixture.root.appendingPathComponent("skip"), password: "true", restoreAttributes: false)
    #expect(skipped.metadataWarningCount == 0)
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".7zip-") })
}

@Test func metadataCaptureCanBeDisabled() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("plain.txt")
    let archive = fixture.root.appendingPathComponent("plain.rz", isDirectory: true)
    _ = try await fixture.service.compress(
        [source], to: archive,
        options: CompressionOptions(format: .recovery, preserveMetadata: false))
    let listing = try await fixture.service.list(archive)
    #expect(!listing.preservesMetadata && !listing.isEncrypted && !listing.isLocked)
}

@Test func protectedListingRetainsEncryptionForEmptyArchives() throws {
    let url = URL(fileURLWithPath: "/empty.rz", isDirectory: true)
    let json = #"{"version":1,"encrypted":true,"locked":true,"preservesMetadata":true,"entries":[]}"#
    let listing = try RecoveryListingParser.parse(json, url: url, physicalSize: 0)
    #expect(listing.isEncrypted && listing.isLocked && listing.preservesMetadata)
    #expect(throws: ArchiveError.self) {
        try RecoveryListingParser.parse(
            #"{"version":1,"encrypted":false,"locked":true,"entries":[]}"#, url: url, physicalSize: 0)
    }
}

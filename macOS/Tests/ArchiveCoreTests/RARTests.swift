import Foundation
import Testing

@testable import ArchiveCore

private func rarOptions(split: Bool = false) -> CompressionOptions {
    var options = CompressionOptions(format: .rar)
    options.rar.level = 0
    options.rar.recoveryRecordPercent = 10
    if split {
        options.rar.volumeSizeBytes = 64 * 1024
        options.rar.recoveryVolumeAmount = 1
    }
    return options
}

private func rarPayload(_ fixture: Fixture, size: Int = 240 * 1024) throws -> URL {
    let url = try fixture.file("资料/data.bin", contents: "")
    let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 17) })
    try data.write(to: url)
    return url
}

@Test(arguments: ["-", "ä密码🔒"])
func rarDataEncryptionKeepsNamesVisibleButRequiresPassword(password: String) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("visible-name.txt")
    let archive = fixture.root.appendingPathComponent("encrypted-data.rar")
    _ = try await fixture.service.compress(
        [source], to: archive,
        options: CompressionOptions(format: .rar, password: password, encryptNames: false))
    let listing = try await fixture.service.list(archive)
    #expect(listing.isEncrypted && listing.fileCount == 1)
    do {
        try await fixture.service.test(archive)
        Issue.record("Encrypted data must require a password")
    } catch ArchiveError.passwordRequired {}
    await #expect(throws: ArchiveError.self) {
        try await fixture.service.extract(archive, to: fixture.root.appendingPathComponent("without-password"))
    }
    try await fixture.service.test(archive, password: password)
    let output = fixture.root.appendingPathComponent("decoded")
    _ = try await fixture.service.extract(archive, to: output, password: password)
    #expect(try Data(contentsOf: source) == Data(contentsOf: output.appendingPathComponent("visible-name.txt")))
}

@Test func rarVolumesEncryptionAndMissingFirstVolumeRecovery() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try rarPayload(fixture)
    let destination = fixture.root.appendingPathComponent("split.rar")
    var options = rarOptions(split: true)
    options.password = "保密🔑 пароль"
    let first = try await fixture.service.compress([source], to: destination, options: options)
    let members = try RARArchive.family(first)
    let dataVolumes = members.filter { $0.pathExtension == "rar" }
    let rev = try #require(members.first { $0.pathExtension == "rev" })
    #expect(dataVolumes.count >= 3)
    #expect(first.deletingLastPathComponent().path == RARArchive.volumeDirectory(for: destination).path)
    let last = try #require(dataVolumes.last)
    let listed = try await fixture.service.list(last, password: options.password)
    #expect(listed.url.resolvingSymlinksInPath().path == first.resolvingSymlinksInPath().path)
    await #expect(throws: ArchiveError.self) { try await fixture.service.list(first) }
    let output = fixture.root.appendingPathComponent("out")
    _ = try await fixture.service.extract(first, to: output, password: options.password)
    #expect(try Data(contentsOf: source) == Data(contentsOf: output.appendingPathComponent("data.bin")))
    let original = try Data(contentsOf: first)
    try FileManager.default.removeItem(at: first)
    var request = RARToolRequest()
    request.operation = .reconstruct
    request.password = options.password
    let repaired = fixture.root.appendingPathComponent("rebuilt")
    _ = try await fixture.service.performRARTool(request, archive: rev, to: repaired)
    #expect(!FileManager.default.fileExists(atPath: first.path))
    let rebuiltFirst = repaired.appendingPathComponent(first.lastPathComponent)
    #expect(try Data(contentsOf: rebuiltFirst) == original)
    try await fixture.service.test(rebuiltFirst, password: options.password)
}

@Test func rarRecoveryRecordRepairsCorruptDataWithoutChangingInput() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try rarPayload(fixture)
    let archive = fixture.root.appendingPathComponent("damaged.rar")
    _ = try await fixture.service.compress([source], to: archive, options: rarOptions())
    var bytes = try Data(contentsOf: archive)
    for index in 5000..<5100 { bytes[index] ^= 0xff }
    try bytes.write(to: archive)
    await #expect(throws: ArchiveError.self) { try await fixture.service.test(archive) }
    var request = RARToolRequest()
    request.operation = .repair
    let result = fixture.root.appendingPathComponent("repaired")
    _ = try await fixture.service.performRARTool(request, archive: archive, to: result)
    let repaired = try #require(
        FileManager.default.contentsOfDirectory(at: result, includingPropertiesForKeys: nil).first)
    try await fixture.service.test(repaired)
    let extracted = fixture.root.appendingPathComponent("extracted")
    _ = try await fixture.service.extract(repaired, to: extracted)
    #expect(try Data(contentsOf: extracted.appendingPathComponent("data.bin")) == Data(contentsOf: source))
    #expect(try Data(contentsOf: archive) == bytes)
}

@Test func rarFiltersCommentAndArchiveEditing() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("docs/保留.txt")
    _ = try fixture.file("docs/忽略.tmp")
    let source = fixture.root.appendingPathComponent("docs")
    let archive = fixture.root.appendingPathComponent("edit.rar")
    var options = CompressionOptions(format: .rar)
    options.rar.solid = true
    options.rar.useBlake2 = true
    options.rar.excludeMasks = "*.tmp"
    options.rar.comment = "中文注释\nsecond line"
    _ = try await fixture.service.compress([source], to: archive, options: options)
    let listing = try await fixture.service.list(archive)
    #expect(listing.fileCount == 1)
    let original = try Data(contentsOf: archive)
    var request = RARToolRequest()
    request.operation = .exportComment
    let comments = fixture.root.appendingPathComponent("comments")
    _ = try await fixture.service.performRARTool(request, archive: archive, to: comments)
    #expect(try String(contentsOf: comments.appendingPathComponent("comment.txt"), encoding: .utf8).contains("中文注释"))
    request.operation = .rename
    request.entryNames = "docs/保留.txt"
    request.renamedPath = "docs/新名字.txt"
    let renamed = fixture.root.appendingPathComponent("renamed")
    _ = try await fixture.service.performRARTool(request, archive: archive, to: renamed)
    #expect(
        try await fixture.service.list(renamed.appendingPathComponent("edit.rar")).entries.contains {
            $0.path == "docs/新名字.txt"
        })
    #expect(try Data(contentsOf: archive) == original)
    request.operation = .delete
    request.entryNames = "docs/新名字.txt"
    let deleted = fixture.root.appendingPathComponent("deleted")
    _ = try await fixture.service.performRARTool(
        request, archive: renamed.appendingPathComponent("edit.rar"), to: deleted)
    let remaining = deleted.appendingPathComponent("edit.rar")
    if FileManager.default.fileExists(atPath: remaining.path) {
        #expect(try await fixture.service.list(remaining).fileCount == 0)
    }
}

@Test func rarRecoveryVolumeFailurePublishesNothing() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("tiny.txt")
    let archive = fixture.root.appendingPathComponent("tiny.rar")
    await #expect(throws: ArchiveError.self) {
        try await fixture.service.compress([source], to: archive, options: rarOptions(split: true))
    }
    #expect(!FileManager.default.fileExists(atPath: RARArchive.volumeDirectory(for: archive).path))
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".7zip-") })
}

@Test func rarVolumeFamilyDoesNotIncludeOtherArchives() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let first = try fixture.file("family[1].part1.rar")
    _ = try fixture.file("family[1].part2.rar")
    _ = try fixture.file("family[1].part1.rev")
    _ = try fixture.file("family1.part3.rar")
    _ = try fixture.file("family[1]-other.part1.rar")
    #expect(try RARArchive.family(first).count == 3)
}

@Test func rarFlattenRenamesDuplicateFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let left = try fixture.file("left/a.txt", contents: "left")
    let right = try fixture.file("right/a.txt", contents: "right")
    let archive = fixture.root.appendingPathComponent("flat.rar")
    _ = try await fixture.service.compress([left, right], to: archive, options: CompressionOptions(format: .rar))
    var request = RARToolRequest()
    request.operation = .extractFlat
    let output = fixture.root.appendingPathComponent("flat")
    _ = try await fixture.service.performRARTool(request, archive: archive, to: output)
    let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
    #expect(files.count == 2)
    #expect(try Set(files.map { try String(contentsOf: $0, encoding: .utf8) }) == ["left", "right"])
}

@Test func rarRejectsDangerousOutputAndInvalidOptions() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("folder/file.txt")
    let folder = fixture.root.appendingPathComponent("folder")
    await #expect(throws: ArchiveError.self) {
        try await fixture.service.compress(
            [folder], to: folder.appendingPathComponent("self.rar"), options: CompressionOptions(format: .rar))
    }
    var options = RAROptions()
    options.recoveryVolumeAmount = 1
    #expect(throws: ArchiveError.self) { try options.validate() }
    options.recoveryVolumeAmount = 0
    #expect(throws: ArchiveError.self) { try options.validate(password: String(repeating: "a", count: 128)) }
    options.includeMasks = "@secret-list.txt"
    #expect(throws: ArchiveError.self) { try options.validate() }
}

@Test func rarSFXRoundTripAndReports() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("item.txt")
    let archive = fixture.root.appendingPathComponent("sfx.rar")
    _ = try await fixture.service.compress([source], to: archive, options: CompressionOptions(format: .rar))
    var request = RARToolRequest()
    request.operation = .convertSFX
    let converted = fixture.root.appendingPathComponent("sfx-output")
    _ = try await fixture.service.performRARTool(request, archive: archive, to: converted)
    let sfx = try #require(
        FileManager.default.contentsOfDirectory(at: converted, includingPropertiesForKeys: nil)
            .first { $0.pathExtension != "rar" })
    request.operation = .removeSFX
    let plain = fixture.root.appendingPathComponent("plain")
    _ = try await fixture.service.performRARTool(request, archive: sfx, to: plain)
    let restored = try #require(
        FileManager.default.contentsOfDirectory(at: plain, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "rar" })
    try await fixture.service.test(restored)
    for operation in [RARToolOperation.list, .technicalList] {
        request.operation = operation
        let output = fixture.root.appendingPathComponent(operation.rawValue)
        _ = try await fixture.service.performRARTool(request, archive: archive, to: output)
        #expect(
            try String(contentsOf: output.appendingPathComponent("RAR-清单.txt"), encoding: .utf8).contains("item.txt"))
    }
}

@Test func rarAddsProtectionAndUpdatesOnlyCopy() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("item.txt")
    let archive = fixture.root.appendingPathComponent("protection.rar")
    _ = try await fixture.service.compress([source], to: archive, options: CompressionOptions(format: .rar))
    let original = try Data(contentsOf: archive)
    var request = RARToolRequest()
    request.operation = .recoveryRecord
    request.options.recoveryRecordPercent = 5
    let protected = fixture.root.appendingPathComponent("protected")
    _ = try await fixture.service.performRARTool(request, archive: archive, to: protected)
    #expect(try Data(contentsOf: protected.appendingPathComponent("protection.rar")).count > original.count)
    request.operation = .comment
    request.options.comment = "new comment"
    _ = try await fixture.service.performRARTool(
        request, archive: archive, to: fixture.root.appendingPathComponent("commented"))
    request.operation = .add
    request.sources = [try fixture.file("new.txt", contents: "new")]
    let updated = fixture.root.appendingPathComponent("updated")
    _ = try await fixture.service.performRARTool(request, archive: archive, to: updated)
    #expect(try await fixture.service.list(updated.appendingPathComponent("protection.rar")).fileCount == 2)
    request.operation = .lock
    let locked = fixture.root.appendingPathComponent("locked")
    _ = try await fixture.service.performRARTool(request, archive: archive, to: locked)
    request.operation = .add
    await #expect(throws: ArchiveError.self) {
        try await fixture.service.performRARTool(
            request, archive: locked.appendingPathComponent("protection.rar"),
            to: fixture.root.appendingPathComponent("cannot-update"))
    }
    #expect(try Data(contentsOf: archive) == original)
}

@Test func rarSplitRecordsRepairAndReadOperationsPreserveDamagedSources() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try rarPayload(fixture)
    let first = try await fixture.service.compress(
        [source], to: fixture.root.appendingPathComponent("volumes.rar"), options: rarOptions(split: true))
    let members = try RARArchive.family(first)
    let victim = members.filter { $0.pathExtension == "rar" }[1]
    var damaged = try Data(contentsOf: victim)
    for index in 3000..<3060 { damaged[index] ^= 0xff }
    try damaged.write(to: victim)
    await #expect(throws: ArchiveError.self) { try await fixture.service.test(first) }
    await #expect(throws: ArchiveError.self) {
        try await fixture.service.extract(first, to: fixture.root.appendingPathComponent("failed-extraction"))
    }
    #expect(try Data(contentsOf: victim) == damaged)
    var request = RARToolRequest()
    request.operation = .repair
    let output = fixture.root.appendingPathComponent("fixed-volumes")
    _ = try await fixture.service.performRARTool(request, archive: victim, to: output)
    let fixedFirst = output.appendingPathComponent(first.lastPathComponent)
    try await fixture.service.test(fixedFirst)
    #expect(try Data(contentsOf: victim) == damaged)
    #expect(
        try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .allSatisfy { $0.pathExtension != "rev" })
}

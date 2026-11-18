import Foundation
import Testing

@testable import ArchiveCore

// Independent reader for the container envelope, used to inject physical damage
// without relying on the engine's own parser or exposing a production mutation API.
struct RecoveryContainerFixture {
    let bytes: Data
    let dataVolumes: Int
    let recoveryVolumes: Int
    let volumeSize: Int
    let members: [String: Range<Int>]

    init(_ url: URL) throws {
        let bytes = try Data(contentsOf: url)
        try #require(bytes.count >= 256)
        try #require(bytes.prefix(8) == Data("RZCNT001".utf8))
        func number(_ offset: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        let k = number(12, 4), m = number(16, 4)
        let bootstrapSize = number(40, 8), size = number(48, 8)
        try #require((1...100).contains(k) && (1...k).contains(m))
        try #require(number(56, 8) == bytes.count)
        try #require(bytes.prefix(128) == bytes.suffix(128))
        var members = ["manifest.rzm": 128..<(128 + bootstrapSize + 32)]
        let first = 128 + bootstrapSize + 32
        for column in 0..<(k + m) {
            let name = String(format: column < k ? "d%06d.rzv" : "p%06d.rzr", column < k ? column : column - k)
            let start = first + column * size
            try #require(start + size <= bytes.count - 128)
            members[name] = start..<(start + size)
        }
        self.bytes = bytes
        self.dataVolumes = k
        self.recoveryVolumes = m
        self.volumeSize = size
        self.members = members
    }
}

func damageRZMember(in archive: URL, name: String) throws {
    let container = try RecoveryContainerFixture(archive)
    let range = try #require(container.members[name])
    let handle = try FileHandle(forWritingTo: archive)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(range.lowerBound))
    try handle.write(contentsOf: Data(repeating: 0, count: range.count))
}

func convertToLegacyRZDirectory(_ archive: URL) throws {
    let container = try RecoveryContainerFixture(archive)
    try FileManager.default.removeItem(at: archive)
    try FileManager.default.createDirectory(atPath: archive.path, withIntermediateDirectories: false)
    for (name, range) in container.members {
        try container.bytes.subdata(in: range).write(to: archive.appendingPathComponent(name))
    }
}

@Test func recoveryContainerIsAFileAndRepairsDamagedEnvelope() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("文件.txt")
    let archive = fixture.root.appendingPathComponent("container.rz")
    let created = try await fixture.service.compress([source], to: archive, options: .init(format: .recovery))
    #expect(!created.hasDirectoryPath)
    #expect(try created.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
    #expect(RecoveryArchive.directory(for: created)?.hasDirectoryPath == false)
    let before = try Data(contentsOf: created)
    let handle = try FileHandle(forWritingTo: created)
    try handle.write(contentsOf: Data(repeating: 0, count: 128))
    try handle.close()
    #expect(try await fixture.service.list(created).fileCount == 1)
    do {
        try await fixture.service.test(created)
        Issue.record("Damaged container header passed verification")
    } catch ArchiveError.recoveryRepairable {}
    let repaired = try await fixture.service.repair(created, to: fixture.root.appendingPathComponent("fixed.rz"))
    #expect(!repaired.hasDirectoryPath)
    #expect(try Data(contentsOf: repaired) == before)
    try await fixture.service.test(repaired)
}

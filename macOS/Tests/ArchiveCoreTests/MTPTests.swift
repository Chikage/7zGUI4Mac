import Foundation
import Testing

@testable import ArchiveCore

private struct MTPHelperFixture {
    let root: URL
    let executable: URL

    init(_ script: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MTPTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        executable = root.appendingPathComponent("helper")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    var service: MTPService { MTPService(executable: executable, temporaryDirectory: root) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private let device = MTPDevice(id: "device", name: "测试设备")
private let storage = MTPEntry(objectID: .max, storageID: 65537, name: "内部存储", isDirectory: true, isStorage: true)

@Test func mtpLocationsUseObjectHandlesAndRespectStorageBoundaries() throws {
    let root = MTPDirectory(device: device)
    #expect(root.parent == nil && root.storageID == 0 && root.parentID == .max)
    let volume = try #require(root.appending(storage))
    let folder = MTPEntry(objectID: 42, storageID: 65537, name: "资料", isDirectory: true)
    let child = try #require(volume.appending(folder))
    #expect(child.parent == volume && volume.parent == root)
    #expect(child.parentID == 42 && child.displayPath == "测试设备 / 内部存储 / 资料")
    #expect(root.appending(folder) == nil)
    #expect(volume.appending(storage) == nil)
    #expect(child.appending(folder) == nil)
    #expect(volume.appending(MTPEntry(objectID: 42, storageID: 2, name: "其他盘", isDirectory: true)) == nil)
    #expect(folder.browserEntry.url == nil)
}

@Test func mtpDecodesUnicodeEmptyFoldersAndFullWidthFileSizes() async throws {
    let fixture = try MTPHelperFixture(
        """
        case "$1" in
        devices) printf '%s' '{"devices":[{"id":"device","name":"手机 📱"}]}' ;;
        list) if [ "$4" = 42 ]; then printf '%s' '{"entries":[]}'; else
        printf '%s' '{"entries":[{"objectID":42,"storageID":65537,"name":"资料 \\"副本\\".zip","isDirectory":false,"isStorage":false,"size":5368709120,"modified":1700000000}]}'
        fi ;;
        esac
        """)
    defer { fixture.cleanup() }
    let service = fixture.service
    #expect(try await service.devices().first?.name == "手机 📱")
    let volume = try #require(MTPDirectory(device: device).appending(storage))
    let rows = try await service.contents(of: volume)
    #expect(rows.count == 1 && rows.first?.size == 5_368_709_120)
    #expect(rows.first?.browserEntry.isArchive == true)
    #expect(rows.first?.browserEntry.url == nil)
    let folder = try #require(volume.appending(MTPEntry(objectID: 42, storageID: 65537, name: "空", isDirectory: true)))
    #expect(try await service.contents(of: folder).isEmpty)
}

@Test func mtpRejectsDuplicateHandlesMalformedJSONAndWrongStorage() async throws {
    let item =
        #"{"objectID":3,"storageID":65537,"name":"a","isDirectory":false,"isStorage":false,"size":1,"modified":0}"#
    let volume = try #require(MTPDirectory(device: device).appending(storage))
    for payload in [
        "not json", "{\"entries\":[\(item),\(item)]}",
        "{\"entries\":[\(item.replacingOccurrences(of: "65537", with: "2"))]}",
    ] {
        let fixture = try MTPHelperFixture("printf '%s' '\(payload)'")
        defer { fixture.cleanup() }
        await #expect(throws: MTPError.self) { try await fixture.service.contents(of: volume) }
    }
}

@Test func mtpDownloadPublishesOnlyCompleteFileAndCleansFailedCopy() async throws {
    let fixture = try MTPHelperFixture("printf abc > \"$8\"\nprintf '{}'\n")
    defer { fixture.cleanup() }
    let entry = MTPEntry(objectID: 4, storageID: 65537, name: "中文 ' $(literal).txt", isDirectory: false, size: 3)
    let url = try await fixture.service.download(entry, from: device)
    #expect(url.lastPathComponent == entry.name)
    #expect(try Data(contentsOf: url) == Data("abc".utf8))
    let wrongSize = MTPEntry(objectID: 5, storageID: 65537, name: "incomplete.txt", isDirectory: false, size: 50)
    await #expect(throws: MTPError.self) { try await fixture.service.download(wrongSize, from: device) }
    let remaining = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
    #expect(remaining.filter { $0.lastPathComponent.hasPrefix("SevenZipMTP-") }.count == 1)
}

@Test func mtpDownloadCancellationTerminatesHelperAndRemovesPartialFile() async throws {
    let fixture = try MTPHelperFixture("printf x > \"$8\"\nwhile :; do :; done\n")
    defer { fixture.cleanup() }
    let service = fixture.service
    let entry = MTPEntry(objectID: 4, storageID: 65537, name: "partial.txt", isDirectory: false, size: 30)
    let download = Task { try await service.download(entry, from: device) }
    try await Task.sleep(for: .milliseconds(100))
    download.cancel()
    await #expect(throws: CancellationError.self) { try await download.value }
    let remaining = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
    #expect(remaining.map(\.lastPathComponent) == ["helper"])
}

@Test func mtpRejectsUnsafeRemoteNamesAndMissingHelper() async throws {
    for name in ["", ".", "..", "../escape", "/absolute", "a/b", "disk:file", "line\nfeed", "nul\0byte"] {
        #expect(throws: MTPError.self) { try MTPService.validateDownloadName(name) }
    }
    try MTPService.validateDownloadName("安全的文件 📄.txt")
    let service = MTPService(executable: URL(fileURLWithPath: "/nonexistent/mtp-helper"))
    await #expect(throws: MTPError.self) { try await service.devices() }
}

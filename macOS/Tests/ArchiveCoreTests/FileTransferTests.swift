import Darwin
import Foundation
import Testing

@testable import ArchiveCore

private func transfer(_ urls: [URL], to target: URL, kind: FileTransferKind = .copy) async -> FileTransferResult {
    await FileTransferService().transfer(urls, to: target, kind: kind, control: FileTransferControl()) { _ in }
}

@Test func transferCopiesTreeHiddenFilesEmptyFoldersLinksAndMetadata() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let file = try fixture.file("source/子目录/资料.txt", contents: "original bytes")
    _ = try fixture.file("source/.hidden", contents: "")
    let source = fixture.root.appendingPathComponent("source")
    try FileManager.default.createDirectory(
        at: source.appendingPathComponent("空文件夹"), withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    let metadata = Data("custom metadata".utf8)
    #expect(
        metadata.withUnsafeBytes { setxattr(file.path, "org.7zip.transfer-test", $0.baseAddress, $0.count, 0, 0) } == 0)
    let link = source.appendingPathComponent("断开的链接")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
    let out = fixture.root.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
    let result = await transfer([source, file], to: out)
    #expect(result.succeeded, "\(result.errorMessage ?? "")")
    #expect(result.destinations.count == 1)
    let copy = out.appendingPathComponent("source")
    #expect(try Data(contentsOf: copy.appendingPathComponent("子目录/资料.txt")) == Data(contentsOf: file))
    #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("空文件夹").path))
    #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent(".hidden").path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("断开的链接").path)
            == "missing")
    #expect(
        try FileManager.default.attributesOfItem(atPath: copy.appendingPathComponent("子目录/资料.txt").path)[
            .posixPermissions] as? Int == 0o640)
    var buffer = Data(count: 64)
    let length = buffer.withUnsafeMutableBytes {
        getxattr(
            copy.appendingPathComponent("子目录/资料.txt").path, "org.7zip.transfer-test", $0.baseAddress, $0.count, 0, 0)
    }
    #expect(length == metadata.count)
    #expect(buffer.prefix(max(0, length)) == metadata)
    #expect(try Data(contentsOf: file) == Data("original bytes".utf8))
}

@Test func transferKeepsBothNamesAndNeverOverwritesDanglingLinks() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source/a.txt", contents: "new")
    let existing = try fixture.file("out/a.txt", contents: "keep")
    let out = existing.deletingLastPathComponent()
    try FileManager.default.createSymbolicLink(
        atPath: out.appendingPathComponent("a（副本）.txt").path, withDestinationPath: "absent")
    let result = await transfer([source], to: out)
    #expect(result.succeeded)
    #expect(result.destinations.first?.lastPathComponent == "a（副本 2）.txt")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
    #expect(try String(contentsOf: out.appendingPathComponent("a（副本 2）.txt"), encoding: .utf8) == "new")
    let duplicate = await transfer([source], to: source.deletingLastPathComponent())
    #expect(duplicate.succeeded)
    #expect(duplicate.destinations.first?.lastPathComponent == "a（副本）.txt")
}

@Test func transferRejectsSelfDescendantAndSymlinkAliasBeforeWriting() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("source/child/file.txt")
    let source = fixture.root.appendingPathComponent("source")
    let child = source.appendingPathComponent("child")
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
    for destination in [source, child, alias] {
        let result = await transfer([source], to: destination)
        #expect(!result.succeeded)
        #expect(result.errorMessage?.contains("子文件夹") == true)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: child.path) == ["file.txt"])
}

@Test func transferMoveRenamesOnSameVolumeAndSameFolderIsNoOp() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source/file.txt")
    let original = try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? Int
    let same = await transfer([source], to: source.deletingLastPathComponent(), kind: .move)
    #expect(same.succeeded)
    #expect(same.destinations.first?.path == source.resolvingSymlinksInPath().path)
    let moved = await transfer([source], to: fixture.root, kind: .move)
    #expect(moved.succeeded)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(
        try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent("file.txt").path)[
            .systemFileNumber] as? Int == original)
}

@Test func transferCancellationRemovesPartialOutputAndPreservesSource() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source.bin", contents: "")
    try Data(repeating: 0x41, count: 16 * 1024 * 1024).write(to: source)
    let out = fixture.root.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
    let control = FileTransferControl()
    let result = await FileTransferService().transfer([source], to: out, kind: .copy, control: control) {
        if $0.copiedBytes > 0 { control.cancel() }
    }
    #expect(result.cancelled)
    #expect(result.completedSources.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    #expect(try Data(contentsOf: source).count == 16 * 1024 * 1024)
}

@Test func transferPauseCanResumeAndCancelWithoutDeadlock() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source.txt")
    let out = fixture.root.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
    for cancel in [false, true] {
        let control = FileTransferControl()
        control.setPaused(true)
        let task = Task {
            await FileTransferService().transfer([source], to: out, kind: .copy, control: control) { _ in }
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        if cancel { control.cancel() } else { control.setPaused(false) }
        let result = await task.value
        #expect(result.cancelled == cancel)
        #expect(result.succeeded != cancel)
        for url in result.destinations { try FileManager.default.removeItem(at: url) }
    }
}

@Test func transferMoveAcrossVolumesCopiesBeforeRemovingSource() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let out = package.appendingPathComponent(".build/transfer-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: out) }
    let source = try fixture.file("tree/sub/file.txt", contents: "cross volume bytes")
    let tree = fixture.root.appendingPathComponent("tree")
    let result = await transfer([tree], to: out, kind: .move)
    #expect(result.succeeded, "\(result.errorMessage ?? "")")
    #expect(
        try String(contentsOf: out.appendingPathComponent("tree/sub/file.txt"), encoding: .utf8) == "cross volume bytes"
    )
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["tree"])
}

@Test func transferFailurePreservesAlreadyCompletedItemsAndPendingSources() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let first = try fixture.file("a.txt")
    let second = try fixture.file("b.txt")
    let out = fixture.root.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
    let result = await FileTransferService().transfer(
        [first, second], to: out, kind: .copy, control: FileTransferControl()
    ) { progress in
        if progress.currentSource?.lastPathComponent == "a.txt", progress.phase == .copying {
            try? Data("changed after scan".utf8).write(to: second)
        }
    }
    #expect(!result.succeeded)
    #expect(result.completedSources.count == 1)
    #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("a.txt").path))
    #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("b.txt").path))
    #expect(FileManager.default.fileExists(atPath: second.path))
}

@Test func transferPublishRaceKeepsExistingDestination() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source.txt", contents: "copied")
    let out = fixture.root.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
    let result = await FileTransferService().transfer([source], to: out, kind: .copy, control: FileTransferControl()) {
        if $0.phase == .finishing {
            try? Data("concurrent file".utf8).write(to: out.appendingPathComponent("source.txt"))
        }
    }
    #expect(result.succeeded)
    #expect(result.destinations.first?.lastPathComponent == "source（副本）.txt")
    #expect(try String(contentsOf: out.appendingPathComponent("source.txt"), encoding: .utf8) == "concurrent file")
    #expect(try String(contentsOf: out.appendingPathComponent("source（副本）.txt"), encoding: .utf8) == "copied")
}

@Test func transferChangedSourceAcrossVolumesIsRetained() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let out = package.appendingPathComponent(".build/transfer-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: out) }
    var sourceInfo = stat()
    var targetInfo = stat()
    #expect(stat(fixture.root.path, &sourceInfo) == 0)
    #expect(stat(out.path, &targetInfo) == 0)
    // This integration path is available when the checkout is on a different volume than /tmp.
    guard sourceInfo.st_dev != targetInfo.st_dev else { return }
    let source = try fixture.file("source.txt", contents: "before")
    let result = await FileTransferService().transfer([source], to: out, kind: .move, control: FileTransferControl()) {
        if $0.phase == .finishing { try? Data("changed".utf8).write(to: source) }
    }
    #expect(!result.succeeded)
    #expect(try String(contentsOf: source, encoding: .utf8) == "changed")
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
}

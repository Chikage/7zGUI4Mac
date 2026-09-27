import AppKit
import ArchiveCore
import Foundation
import Testing

@testable import SevenZipMac

@Test @MainActor func clipboardTracksCutWithoutDeletingAndConsumesOnlyCompletedItems() throws {
    let board = NSPasteboard(name: .init("TransferTests-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let clipboard = FileClipboard(pasteboard: board)
    let first = URL(fileURLWithPath: "/tmp/transfer-a")
    let second = URL(fileURLWithPath: "/tmp/transfer-b")
    clipboard.write([first, second], kind: .move)
    let snapshot = try #require(clipboard.snapshot())
    #expect(snapshot.kind == .move)
    #expect(clipboard.cutPaths == [first.path, second.path])
    clipboard.finish(snapshot, completed: [first])
    let remaining = try #require(clipboard.snapshot())
    #expect(remaining.urls.map(\.path) == [second.path])
    #expect(remaining.kind == .move)
    clipboard.finish(remaining, completed: [second])
    #expect(clipboard.snapshot() == nil)
    #expect(clipboard.cutPaths.isEmpty)
}

@Test @MainActor func clipboardExternalCopyReplacesCutIntentAndIsNeverClearedByOldTransfer() throws {
    let board = NSPasteboard(name: .init("TransferTests-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let clipboard = FileClipboard(pasteboard: board)
    let file = URL(fileURLWithPath: "/tmp/file")
    clipboard.write([file], kind: .move)
    let old = try #require(clipboard.snapshot())
    board.clearContents()
    board.writeObjects([URL(fileURLWithPath: "/tmp/finder-file") as NSURL])
    clipboard.finish(old, completed: [file])
    let imported = try #require(clipboard.snapshot())
    #expect(imported.kind == .copy)
    #expect(imported.urls.first?.lastPathComponent == "finder-file")
    #expect(clipboard.cutPaths.isEmpty)
    board.clearContents()
    board.setString("ordinary text", forType: .string)
    #expect(clipboard.snapshot() == nil)
    #expect(!clipboard.hasFiles)
}

@Test @MainActor func clipboardCopyRemainsAvailableForRepeatedPaste() throws {
    let board = NSPasteboard(name: .init("TransferTests-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let clipboard = FileClipboard(pasteboard: board)
    let file = URL(fileURLWithPath: "/tmp/file")
    clipboard.write([file], kind: .copy)
    let snapshot = try #require(clipboard.snapshot())
    clipboard.finish(snapshot, completed: [file])
    #expect(clipboard.snapshot()?.urls == [file])
    #expect(clipboard.snapshot()?.kind == .copy)
}

@Test @MainActor func browserPasteRefreshesDestinationSelectionAndFinishesCut() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TransferUI-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    try Data("move me".utf8).write(to: source)
    let target = root.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let board = NSPasteboard(name: .init("TransferTests-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let files = FileBrowserStore(clipboard: FileClipboard(pasteboard: board))
    #expect(await files.navigate(to: root))
    files.selection = Set(files.entries.filter { $0.name == "source.txt" }.map(\.id))
    files.copySelection(files.selection, kind: .move)
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(await files.navigate(to: target))
    files.paste()
    #expect(files.isMutating)
    #expect(files.transfer.isPresented)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while files.isMutating || files.isLoading {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(files.transfer.result?.succeeded == true)
    #expect(files.transfer.fraction == 1)
    #expect(files.transfer.progress.totalBytes == 7)
    #expect(files.transfer.progress.completedBytes == 7)
    #expect(files.transfer.progress.completedItems == 1)
    #expect(files.entries.map(\.name) == ["source.txt"])
    #expect(files.selection == Set(files.entries.map(\.id)))
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(files.clipboard.snapshot() == nil)
}

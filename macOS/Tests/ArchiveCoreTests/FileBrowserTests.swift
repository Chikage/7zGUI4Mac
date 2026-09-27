import Foundation
import Testing

@testable import ArchiveCore

@Test func archiveTreeIncludesImplicitFoldersAndKeepsSearchGlobal() {
    let index = ArchiveDirectoryIndex(entries: [
        ArchiveEntry(path: "资料/照片/旅行.jpg", size: 512),
        ArchiveEntry(path: "资料/说明.txt", size: 42, isEncrypted: true),
        ArchiveEntry(path: "资料旧/其他.txt"),
        ArchiveEntry(path: "空目录/", isDirectory: true),
        ArchiveEntry(path: "nested.zip", size: 80),
    ])
    #expect(Set(index.folders(in: "").map(\.id)) == ["资料", "资料旧", "空目录"])
    #expect(Set(index.entries(in: "资料").map(\.name)) == ["照片", "说明.txt"])
    #expect(index.folders(in: "资料").map(\.id) == ["资料/照片"])
    #expect(index.entries(in: "资料/照片").first?.size == 512)
    #expect(index.entries(in: "资料").first { $0.name == "说明.txt" }?.isEncrypted == true)
    #expect(index.entries(in: "空目录").isEmpty)
    #expect(index.entries(in: "资料旧", search: "旅行").map(\.id) == ["资料/照片/旅行.jpg"])
    #expect(index.entries(in: "").first { $0.name == "nested.zip" }?.isArchive == true)
}

@Test func unsafeArchivePathsCannotBecomeTreeNodes() {
    let index = ArchiveDirectoryIndex(entries: [
        ArchiveEntry(path: "../outside/file"), ArchiveEntry(path: "/absolute/file"),
        ArchiveEntry(path: "loop/./file"), ArchiveEntry(path: "safe/file"),
    ])
    #expect(index.folders(in: "").map(\.id) == ["safe"])
    #expect(index.entries(in: "", search: "outside").count == 1)
}

@Test func historyBranchesAfterGoingBackAndDoesNotDuplicateRefresh() {
    var history = BrowserHistory("home")
    history.visit("a")
    history.visit("a")
    history.visit("b")
    history.goBack()
    #expect(history.current == "a")
    #expect(history.back == ["home"])
    #expect(history.forward == ["b"])
    history.goForward()
    #expect(history.current == "b")
    history.goBack()
    history.visit("c")
    #expect(history.forward.isEmpty)
    history.goBack()
    history.goBack()
    history.goBack()
    #expect(history.current == "home")
}

@Test func filesystemListingDistinguishesPackagesArchivesAndHiddenFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let service = FileBrowserService()
    _ = try fixture.file("资料/你好.txt")
    _ = try fixture.file(".hidden")
    _ = try fixture.file("sample.ZIP")
    _ = try fixture.file("folder.zip/child")
    _ = try fixture.file("backup.rz/index")
    let visible = try await service.contents(of: fixture.root, showHidden: false)
    #expect(!visible.contains { $0.name == ".hidden" })
    #expect(visible.first { $0.name == "资料" }?.isDirectory == true)
    #expect(visible.first { $0.name == "sample.ZIP" }?.isArchive == true)
    #expect(visible.first { $0.name == "folder.zip" }?.isDirectory == true)
    #expect(visible.first { $0.name == "folder.zip" }?.isArchive == false)
    #expect(visible.first { $0.name == "backup.rz" }?.isArchive == true)
    #expect(visible.first { $0.name == "backup.rz" }?.isDirectory == false)
    let all = try await service.contents(of: fixture.root, showHidden: true)
    #expect(all.count == visible.count + 1)
}

@Test func fileOperationsRejectCollisionsAndPathTraversal() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let service = FileBrowserService()
    let source = try fixture.file("original.txt", contents: "original")
    let existing = try fixture.file("existing.txt", contents: "keep")
    await #expect(throws: ArchiveError.self) { try await service.rename(source, to: "existing.txt") }
    #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    for name in ["../outside", ".", "..", "", "  ", "folder/file", "bad\nname"] {
        await #expect(throws: ArchiveError.self) { try await service.createFolder(in: fixture.root, name: name) }
    }
    let folder = try await service.createFolder(in: fixture.root, name: "新文件夹")
    #expect(FileManager.default.fileExists(atPath: folder.path))
    let renamed = try await service.rename(source, to: "新名称.txt")
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try String(contentsOf: renamed, encoding: .utf8) == "original")
}

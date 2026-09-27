import ArchiveCore
import Foundation
import Testing

@testable import SevenZipMac

@MainActor
private struct NavigationFixture {
    let root: URL
    let archive: URL
    let store: AppStore

    init() throws {
        root =
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "BrowserNavigation-\(UUID().uuidString)", isDirectory: true
            ).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not an archive".utf8).write(to: root.appendingPathComponent("示例.zip"))
        archive = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let defaults = try #require(UserDefaults(suiteName: "BrowserNavigation-\(UUID().uuidString)"))
        store = AppStore(defaults: defaults)
        let entries = [ArchiveEntry(path: "资料/子目录/说明.txt")]
        store.listing = ArchiveListing(url: archive, format: "zip", physicalSize: 14, entries: entries)
        store.archiveIndex = ArchiveDirectoryIndex(entries: entries)
        store.browserHistory = BrowserHistory(.directory(root))
        store.navigate(to: "")
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func waitForNavigation() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.files.isLoading || store.isBusy {
            try #require(ContinuousClock.now < deadline, "Browser navigation did not finish")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Test @MainActor func backAndForwardCrossArchiveBoundaryAndRestoreSelection() async throws {
    let fixture = try NavigationFixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    store.navigate(to: "资料")
    store.navigate(to: "资料/子目录")
    store.browserBack()
    #expect(store.folder == "资料")
    store.browserBack()
    #expect(store.folder.isEmpty)
    store.browserBack()
    try await fixture.waitForNavigation()
    #expect(store.page == .files)
    #expect(!store.isBrowsingArchive)
    #expect(store.files.directory == fixture.root)
    #expect(store.files.entries.filter { store.files.selection.contains($0.id) }.map(\.name) == ["示例.zip"])
    store.browserForward()
    #expect(store.isBrowsingArchive && store.folder.isEmpty)
    store.browserForward()
    #expect(store.folder == "资料")
    store.browserForward()
    #expect(store.folder == "资料/子目录")
}

@Test @MainActor func upFromArchiveRootReturnsToParentAndCanGoBack() async throws {
    let fixture = try NavigationFixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    store.navigate(to: "资料/子目录")
    store.browserUp()
    #expect(store.folder == "资料")
    store.browserUp()
    #expect(store.isBrowsingArchive && store.folder.isEmpty)
    store.browserUp()
    try await fixture.waitForNavigation()
    #expect(!store.isBrowsingArchive && store.files.directory == fixture.root)
    store.browserBack()
    #expect(store.isBrowsingArchive && store.folder.isEmpty)
}

@Test @MainActor func localDirectoryNavigationBranchesHistoryAfterLeavingArchive() async throws {
    let fixture = try NavigationFixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    let other = fixture.root.appendingPathComponent("其他", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    store.navigate(to: "资料")
    store.navigate(to: other)
    try await fixture.waitForNavigation()
    #expect(!store.isBrowsingArchive && store.files.directory == other)
    store.browserBack()
    #expect(store.isBrowsingArchive && store.folder == "资料")
    store.showArchiveParent()
    try await fixture.waitForNavigation()
    #expect(store.browserHistory.forward.isEmpty)
    #expect(store.files.directory == fixture.root)
}

@Test @MainActor func failedNavigationKeepsCurrentArchiveAndHistory() async throws {
    let fixture = try NavigationFixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    store.navigate(to: "资料")
    let previous = store.browserHistory
    store.navigate(to: fixture.root.appendingPathComponent("missing", isDirectory: true))
    try await fixture.waitForNavigation()
    #expect(store.files.errorMessage != nil)
    #expect(store.isBrowsingArchive && store.folder == "资料")
    #expect(store.browserHistory.current == previous.current)
    #expect(store.browserHistory.back == previous.back)
    store.openArchive(fixture.archive)
    try await fixture.waitForNavigation()
    #expect(store.errorMessage != nil)
    #expect(store.browserHistory.current == previous.current)
    #expect(store.browserHistory.back == previous.back)
}

@Test @MainActor func refreshCannotReplacePendingDirectoryNavigation() async throws {
    let fixture = try NavigationFixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    store.showArchiveParent()
    store.files.refresh()
    try await fixture.waitForNavigation()
    #expect(!store.isBrowsingArchive)
    #expect(store.files.directory == fixture.root)
    #expect(store.browserHistory.current == .directory(fixture.root))
}

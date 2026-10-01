import ArchiveCore
import Foundation
import Testing

@testable import SevenZipMac

private let testDevice = MTPDevice(id: "test", name: "手机")
private let testStorage = MTPEntry(objectID: .max, storageID: 1, name: "内部存储", isDirectory: true, isStorage: true)
private let testFolder = MTPEntry(objectID: 2, storageID: 1, name: "资料", isDirectory: true)
private let testFile = MTPEntry(objectID: 3, storageID: 1, name: "说明.txt", isDirectory: false, size: 10)

private actor FakeMTPService: MTPBrowsing {
    var connected = true
    func disconnect() { connected = false }
    func devices() async throws -> [MTPDevice] { connected ? [testDevice] : [] }
    func contents(of directory: MTPDirectory) async throws -> [MTPEntry] {
        try await Task.sleep(for: .milliseconds(20))
        guard connected else { throw MTPError.connection }
        if directory.trail.isEmpty { return [testStorage] }
        if directory.parentID == .max { return [testFolder] }
        return [testFile, MTPEntry(objectID: 4, storageID: 1, name: ".hidden", isDirectory: false)]
    }
    func download(_ entry: MTPEntry, from device: MTPDevice) async throws -> URL {
        try await Task.sleep(for: .seconds(30))
        return URL(fileURLWithPath: "/unused")
    }
}

@MainActor private func waitForMTP(_ store: AppStore) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.isBusy || store.files.isLoading {
        try #require(ContinuousClock.now < deadline, "MTP operation did not finish")
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test @MainActor func mtpDownloadedArchiveReturnsToDeviceAndDoesNotPersistTemporaryRecent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MTPArchive-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("sample.zip")
    try Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18)).write(to: archive)
    let defaults = try #require(UserDefaults(suiteName: "MTPArchive-\(UUID().uuidString)"))
    let mtp = MTPBrowserStore(service: FakeMTPService())
    let store = AppStore(defaults: defaults, mtp: mtp)
    let location = try #require(MTPDirectory(device: testDevice).appending(testStorage))
    store.navigate(to: location)
    try await waitForMTP(store)
    store.openMTPArchive(archive, from: location)
    try await waitForMTP(store)
    #expect(store.errorMessage == nil)
    #expect(store.isBrowsingArchive && store.recent.isEmpty)
    #expect(store.browserHistory.back.last == .mtp(location))
    store.browserUp()
    try await waitForMTP(store)
    #expect(store.isBrowsingMTP && mtp.directory == location)
}

@Test @MainActor func mtpNavigationSharesHistoryWithLocalAndArchiveDirectories() async throws {
    let mtp = MTPBrowserStore(service: FakeMTPService())
    let store = AppStore(mtp: mtp)
    let local = FileManager.default.temporaryDirectory.standardizedFileURL
    store.navigate(to: local)
    try await waitForMTP(store)
    let root = MTPDirectory(device: testDevice)
    store.navigate(to: root)
    #expect(!store.canNavigateBrowser)
    store.navigate(to: local)
    try await waitForMTP(store)
    #expect(store.isBrowsingMTP && store.browserHistory.current == .mtp(root))
    let storage = try #require(root.appending(testStorage))
    store.navigate(to: storage)
    try await waitForMTP(store)
    let folder = try #require(storage.appending(testFolder))
    store.navigate(to: folder)
    try await waitForMTP(store)
    #expect(mtp.visibleEntries.map(\.name) == ["说明.txt"])
    mtp.showHidden = true
    #expect(mtp.visibleEntries.count == 2)
    mtp.search = "说明"
    #expect(mtp.visibleEntries.count == 1)
    store.browserUp()
    try await waitForMTP(store)
    #expect(mtp.directory == storage && mtp.search.isEmpty)
    store.browserBack()
    try await waitForMTP(store)
    #expect(mtp.directory == folder)
    let archive = local.appendingPathComponent("mtp-history.zip")
    store.listing = ArchiveListing(url: archive, format: "zip", physicalSize: 0, entries: [])
    store.navigate(to: "")
    #expect(store.isBrowsingArchive)
    store.browserBack()
    try await waitForMTP(store)
    #expect(store.isBrowsingMTP && mtp.directory == folder)
    store.navigate(to: local)
    try await waitForMTP(store)
    #expect(!store.isBrowsingMTP && !store.isBrowsingArchive)
    #expect(store.browserHistory.forward.isEmpty)
}

@Test @MainActor func mtpFailedNavigationPreservesHistoryAndRefreshClearsStaleFiles() async throws {
    let service = FakeMTPService()
    let mtp = MTPBrowserStore(service: service)
    let store = AppStore(mtp: mtp)
    let root = MTPDirectory(device: testDevice)
    store.navigate(to: root)
    try await waitForMTP(store)
    let before = store.browserHistory
    await service.disconnect()
    store.navigate(to: try #require(root.appending(testStorage)))
    try await waitForMTP(store)
    #expect(store.browserHistory.current == before.current)
    #expect(store.browserHistory.back == before.back)
    #expect(mtp.errorMessage != nil && mtp.entries == [testStorage])
    mtp.refresh()
    try await waitForMTP(store)
    #expect(mtp.directoryError != nil && mtp.entries.isEmpty)
    mtp.scan()
    try await waitForMTP(store)
    #expect(mtp.devices.isEmpty && mtp.hasScanned)
}

@Test @MainActor func mtpCancellationDoesNotCommitNavigationOrOpenDownloadedFile() async throws {
    let mtp = MTPBrowserStore(service: FakeMTPService())
    let store = AppStore(mtp: mtp)
    let previous = store.browserHistory
    let root = MTPDirectory(device: testDevice)
    store.navigate(to: root)
    store.cancel()
    try await waitForMTP(store)
    #expect(store.browserHistory.current == previous.current && mtp.errorMessage == nil)
    let folder = try #require(root.appending(testStorage)?.appending(testFolder))
    store.navigate(to: folder)
    try await waitForMTP(store)
    var opened = false
    mtp.download(testFile) { _ in opened = true }
    #expect(store.isBusy)
    store.cancel()
    try await waitForMTP(store)
    #expect(!opened && !store.isBusy && mtp.errorMessage == nil)
}

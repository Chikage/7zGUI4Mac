import ArchiveCore
import Foundation
import Testing

@testable import SevenZipMac

@Test @MainActor func lockedKeyFileArchiveRequestsKeyInsteadOfPassword() throws {
    let store = AppStore(defaults: try #require(UserDefaults(suiteName: "KeyPrompt-\(UUID().uuidString)")))
    store.listing = ArchiveListing(
        url: URL(fileURLWithPath: "/example.rz"), format: "RZ", physicalSize: 0,
        entries: [], encrypted: true, locked: true, recoveryEncryption: .dual, requiresKeyFile: true)
    store.requestExtract()
    #expect(store.showKeyFile && !store.showPassword && !store.showExtract)
    store.showKeyFile = false
    store.testArchive()
    #expect(store.showKeyFile && !store.showPassword)
}

@Test @MainActor func automaticallyUnlockedKeyArchiveDoesNotRequestPasswordForExtraction() throws {
    let store = AppStore(defaults: try #require(UserDefaults(suiteName: "KeyUnlocked-\(UUID().uuidString)")))
    store.listing = ArchiveListing(
        url: URL(fileURLWithPath: "/example.rz"), format: "RZ", physicalSize: 0,
        entries: [ArchiveEntry(path: "file")], encrypted: true, recoveryEncryption: .dual, requiresKeyFile: true)
    store.requestExtract()
    #expect(store.showExtract && !store.showKeyFile && !store.showPassword)
}

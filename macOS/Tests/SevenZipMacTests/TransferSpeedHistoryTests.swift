import ArchiveCore
import Foundation
import Testing

@testable import SevenZipMac

@Test func speedHistoryKeepsWholeProgressWithBoundedSamples() {
    var history = TransferSpeedHistory()
    for index in 1...10_000 {
        history.record(fraction: Double(index) / 10_000, bytesPerSecond: Double(index) * 1_024)
    }
    #expect(history.samples.first?.fraction == 0)
    #expect(history.samples.last?.fraction == 1)
    #expect(history.samples.contains { $0.fraction > 0 && $0.fraction < 0.01 })
    #expect(history.samples.count <= 1_002)
    #expect(zip(history.samples, history.samples.dropFirst()).allSatisfy { $0.fraction < $1.fraction })
}

@Test func speedHistoryUpdatesStationaryProgressWithoutInventingAdvancement() {
    var history = TransferSpeedHistory()
    history.record(fraction: 0.25, bytesPerSecond: 100_000_000)
    history.record(fraction: 0.5, bytesPerSecond: 70_000_000)
    for _ in 0..<200 { history.record(fraction: 0.5, bytesPerSecond: 0) }
    #expect(history.samples.count == 3)
    #expect(history.samples.last?.fraction == 0.5)
    #expect(history.samples.last?.bytesPerSecond == 0)
    #expect(history.samples[1].bytesPerSecond == 100_000_000)
    history.record(fraction: 0.4, bytesPerSecond: 50_000_000)
    history.record(fraction: .nan, bytesPerSecond: 50_000_000)
    #expect(history.samples.count == 3)
    #expect(history.samples.last?.fraction == 0.5)
}

@Test @MainActor func shortCopyRecordsSpeedAndReachesRightEdgeOfChart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeedChart-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.bin")
    let target = root.appendingPathComponent("out")
    try Data(repeating: 0x61, count: 16_384).write(to: source)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let store = FileTransferStore()
    store.start(FileClipboardSnapshot(urls: [source], kind: .copy, changeCount: -1), to: target) { _ in }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.isRunning {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.result?.succeeded == true)
    #expect(store.samples.first?.fraction == 0)
    #expect(store.samples.last?.fraction == 1)
    #expect(store.samples.contains { $0.bytesPerSecond > 0 })
    #expect(try Data(contentsOf: target.appendingPathComponent("source.bin")) == Data(contentsOf: source))
}

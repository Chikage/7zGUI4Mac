import Foundation
import Testing

@testable import ArchiveCore

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [EngineProgress] = []
    func append(_ value: EngineProgress) { lock.withLock { values.append(value) } }
    var snapshots: [EngineProgress] { lock.withLock { values } }
}

@Test func sevenZipProgressHandlesSplitWritesAndFilesWithoutPercentChanges() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let archive = try fixture.file("partial.zip", contents: String(repeating: "x", count: 100))
    var parser = EngineProgressParser(compressionOutput: archive)
    _ = parser.consume(Data("Add new data to archive: 2 folders, 4 files, 1000 bytes (1 KiB)\n".utf8), now: 10)
    #expect(parser.consume(Data("  2".utf8), now: 11).isEmpty)
    let first = try #require(parser.consume(Data("5% 1 + 路径.txt".utf8), now: 12).last)
    #expect(first.fraction == 0.25)
    #expect(first.compression?.completedFiles == 1)
    #expect(first.compression?.totalFiles == 4)
    #expect(first.compression?.processedBytes == 250)
    #expect(first.compression?.bytesPerSecond == 125)
    #expect(first.compression?.ratio == 0.4)
    #expect(first.compression?.isEstimated == true)
    let second = try #require(parser.consume(Data("\u{8}\u{8} 25% 2 + next.txt\r".utf8), now: 13).last)
    #expect(second.fraction == 0.25)
    #expect(second.compression?.completedFiles == 2)
    let finalUpdate = parser.finish(now: 14)
    let done = try #require(finalUpdate)
    #expect(done.fraction == 1)
    #expect(done.compression?.completedFiles == 4)
    #expect(done.compression?.processedBytes == 1000)
    #expect(done.compression?.isEstimated == false)
}

@Test func progressIgnoresPercentInFilenamesAndMalformedTelemetry() {
    var parser = EngineProgressParser()
    for line in [
        "ERROR: document 75%.txt\n", "+ 22% report.txt\n", "1234%\n", "101%\n",
        "RZPROGRESS1\tcompressing\t-1\t100\t0\t1\t1\t1\n",
        "RZPROGRESS1\tcompressing\t101\t100\t0\t1\t1\t1\n",
        "RZPROGRESS1\tunknown\t10\t100\t0\t1\t1\t1\n",
    ] {
        #expect(parser.consume(Data(line.utf8)).isEmpty)
    }
}

@Test func recoveryProgressPreservesStatsDuringFinalization() throws {
    var parser = EngineProgressParser()
    _ = parser.consume(Data("RZPROGRESS1\tcompressing\t50\t".utf8))
    let update = try #require(parser.consume(Data("100\t1\t2\t20\t1000\n".utf8)).last)
    #expect(update.fraction == 0.5)
    #expect(update.compression?.bytesPerSecond == 50)
    #expect(update.compression?.ratio == 0.4)
    #expect(update.compression?.excludesRecovery == true)
    let finalizing = try #require(parser.consume(Data("RZPROGRESS1\trecovery\t100\t100\t2\t2\t40\t2000\n".utf8)).last)
    #expect(finalizing.fraction == nil)
    #expect(finalizing.message.contains("恢复卷"))
    #expect(finalizing.compression?.completedFiles == 2)
    #expect(finalizing.compression?.bytesPerSecond == 50)
    // Supplemental phase timings must not replace the content-compression speed.
    #expect(parser.consume(Data("RZTIMING1\t{\"version\":1,\"rs_work_us\":9000}\n".utf8)).isEmpty)
    #expect(parser.finish()?.compression?.bytesPerSecond == 50)
}

@Test func emptyInputHasNoRatioOrSpeed() throws {
    var parser = EngineProgressParser()
    let update = try #require(parser.consume(Data("RZPROGRESS1\tcompressing\t0\t0\t0\t2\t0\t0\n".utf8)).last)
    #expect(update.compression?.ratio == nil)
    #expect(update.compression?.bytesPerSecond == nil)
    #expect(parser.finish()?.compression?.completedFiles == 2)
    var value = CompressionMetrics()
    value.processedBytes = 10
    value.compressedBytes = 30
    #expect(value.ratio == 3)
}

@Test func processReportsUnterminatedProgressBeforeExit() async throws {
    let log = ProgressRecorder()
    let start = ContinuousClock.now
    let result = try await ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh")).run(
        arguments: ["-c", "printf ' 37%%'; sleep 2"], progress: { log.append($0) })
    #expect(result.status == 0)
    let update = try #require(log.snapshots.first)
    #expect(update.fraction == 0.37)
    #expect(start.duration(to: update.timestamp) < .seconds(1.5))
}

@Test(arguments: ArchiveFormat.allCases)
func compressionReportsRealTotalsAndCompletion(format: ArchiveFormat) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source/sub/data.txt", contents: String(repeating: "Compress me! ", count: 500_000))
    _ = try fixture.file("source/empty.txt", contents: "")
    let folder = fixture.root.appendingPathComponent("source")
    let destination = fixture.root.appendingPathComponent("output.\(format.rawValue)")
    let log = ProgressRecorder()
    _ = try await fixture.service.compress(
        [folder, source], to: destination,
        options: CompressionOptions(format: format), progress: { log.append($0) })
    let final = try #require(log.snapshots.last)
    let metrics = try #require(final.compression)
    #expect(final.fraction == 1)
    #expect(metrics.totalFiles == 2 && metrics.completedFiles == 2)
    #expect(metrics.totalBytes == 6_500_000 && metrics.processedBytes == metrics.totalBytes)
    #expect(metrics.ratio != nil)
    #expect(log.snapshots.contains { $0.fraction == 0 })
    if format == .recovery {
        #expect(log.snapshots.contains { $0.message.contains("恢复卷") && $0.compression != nil })
    } else {
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(metrics.compressedBytes == size.map(Int64.init))
    }
}

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

@Test func creationVerificationReportsRealReadProgress() throws {
    var parser = EngineProgressParser()
    let start = try #require(parser.consume(Data("RZPROGRESS1\tverifying\t100\t100\t2\t2\t40\t2000\n".utf8)).last)
    #expect(start.fraction == 0)
    let storage = try #require(parser.consume(Data("RZREADPROGRESS1\tstorage\t50\t200\t0\t0\t1000\n".utf8)).last)
    #expect(storage.fraction == 0.25)
    #expect(storage.processing?.processedBytes == 50)
    #expect(storage.processing?.bytesPerSecond == 50)
    let contents = try #require(parser.consume(Data("RZREADPROGRESS1\tchecking\t50\t100\t1\t2\t1000\n".utf8)).last)
    #expect(contents.fraction == 0.5)
    #expect(contents.processing?.completedFiles == 1)
    let done = try #require(parser.consume(Data("RZPROGRESS1\tcompleted\t100\t100\t2\t2\t40\t2000\n".utf8)).last)
    #expect(done.fraction == 1)
    #expect(done.processing == nil)
    #expect(done.compression?.totalBytes == 100)
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

@Test(arguments: [ArchiveReadOperation.extract, .verify])
func sevenZipReadProgressUsesListingTotals(operation: ArchiveReadOperation) throws {
    var parser = EngineProgressParser(
        readOperation: operation, totals: ProcessingMetrics(totalBytes: 1000, totalFiles: 4))
    #expect(parser.start(now: 10)?.fraction == 0)
    let update = try #require(parser.consume(Data(" 25% 2 - file.txt\r".utf8), now: 12).last)
    #expect(update.processing?.processedBytes == 250)
    #expect(update.processing?.completedFiles == 2)
    #expect(update.processing?.bytesPerSecond == 125)
    #expect(update.processing?.isEstimated == true)
    #expect(update.compression == nil)
    let finalUpdate = parser.finish(now: 14)
    let done = try #require(finalUpdate)
    #expect(done.fraction == 1)
    #expect(done.processing?.completedFiles == 4)
    #expect(done.processing?.processedBytes == 1000)
    #expect(done.processing?.isEstimated == false)
}

@Test func recoveryReadProgressHandlesPhasesAndSplitRecords() throws {
    var parser = EngineProgressParser(readOperation: .extract)
    #expect(parser.consume(Data("RZREADPROGRESS1\tstorage\t50\t".utf8)).isEmpty)
    let storage = try #require(parser.consume(Data("100\t0\t0\t1000\n".utf8)).last)
    #expect(storage.fraction == 0.5)
    #expect(storage.processing?.totalFiles == nil)
    #expect(storage.processing?.bytesPerSecond == 50)
    let extracted = try #require(parser.consume(Data("RZREADPROGRESS1\textracting\t100\t100\t2\t2\t2000\n".utf8)).last)
    #expect(extracted.fraction == 0.99)
    #expect(extracted.processing?.completedFiles == 2)
    let attributes = try #require(parser.consume(Data("RZREADPROGRESS1\tattributes\t100\t100\t2\t2\t2000\n".utf8)).last)
    #expect(attributes.fraction == nil)
    #expect(attributes.message.contains("恢复属性"))
    #expect(attributes.processing?.processedBytes == 100)
    // A process exiting without a completion record must not invent success.
    #expect(parser.finish() == nil)
    let done = try #require(parser.consume(Data("RZREADPROGRESS1\tcompleted\t100\t100\t2\t2\t2000\n".utf8)).last)
    #expect(done.fraction == 1)
    #expect(done.compression == nil)
    for line in [
        "RZREADPROGRESS1\tchecking\t101\t100\t0\t2\t10\n",
        "RZREADPROGRESS1\tchecking\t10\t100\t3\t2\t10\n",
        "RZREADPROGRESS1\tchecking\t-1\t100\t0\t2\t10\n",
        "RZREADPROGRESS1\tunknown\t10\t100\t0\t2\t10\n",
    ] {
        #expect(parser.consume(Data(line.utf8)).isEmpty)
    }
}

@Test func processStreamsProgressAlongsideJSONAndWarnings() async throws {
    let log = ProgressRecorder()
    let start = ContinuousClock.now
    let result = try await ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh")).run(
        arguments: [
            "-c",
            "printf 'RZREADPROGRESS1\\textracting\\t50\\t100\\t1\\t2\\t1000\\n' >&2; sleep 2; printf '{\"warningCount\":1}'; exit 5",
        ],
        captureListing: true, readOperation: .extract, progress: { log.append($0) })
    #expect(result.status == 5)
    #expect(result.output == "{\"warningCount\":1}")
    let update = try #require(log.snapshots.first)
    #expect(update.fraction == 0.5)
    #expect(start.duration(to: update.timestamp) < .seconds(1.5))
    #expect(!log.snapshots.contains { $0.fraction == 1 })
}

@Test func processDrainsBothPipesAndPreservesErrors() async throws {
    let result = try await ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh")).run(
        arguments: [
            "-c",
            "i=0; while [ $i -lt 5000 ]; do printf 'RZREADPROGRESS1\\tstorage\\t0\\t100\\t0\\t0\\t0\\n' >&2; i=$((i+1)); done; printf '{}'; printf 'run repair first\\n' >&2; exit 1",
        ],
        captureListing: true)
    #expect(result.status == 1)
    #expect(result.output.contains("run repair first"))
    #expect(result.output.hasPrefix("{}"))
}

@Test(arguments: ArchiveFormat.allCases)
func readOperationsReportTotalsAndCompletion(format: ArchiveFormat) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("source/data.txt", contents: String(repeating: "Read progress! ", count: 500_000))
    _ = try fixture.file("source/empty.txt", contents: "")
    let archive = fixture.root.appendingPathComponent("output.\(format.rawValue)")
    _ = try await fixture.service.compress(
        [source.deletingLastPathComponent()], to: archive, options: CompressionOptions(format: format))
    for operation in [ArchiveReadOperation.extract, .verify] {
        let log = ProgressRecorder()
        if operation == .extract {
            let output = fixture.root.appendingPathComponent("extracted")
            _ = try await fixture.service.extract(archive, to: output, progress: { log.append($0) })
            #expect(try Data(contentsOf: output.appendingPathComponent("source/data.txt")) == Data(contentsOf: source))
        } else {
            try await fixture.service.test(archive, progress: { log.append($0) })
        }
        let final = try #require(log.snapshots.last { $0.processing != nil })
        let metrics = try #require(final.processing)
        #expect(final.fraction == 1)
        #expect(metrics.totalBytes == 7_500_000 && metrics.processedBytes == metrics.totalBytes)
        #expect(metrics.totalFiles == 2 && metrics.completedFiles == 2)
        #expect(!metrics.isEstimated)
        #expect(log.snapshots.contains { $0.fraction == 0 })
        #expect(log.snapshots.allSatisfy { $0.compression == nil })
    }
}

@Test(arguments: [ArchiveFormat.sevenZip, .recovery])
func emptyFilesCompleteReadProgress(format: ArchiveFormat) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = try fixture.file("empty.txt", contents: "")
    let archive = fixture.root.appendingPathComponent("empty.\(format.rawValue)")
    _ = try await fixture.service.compress([source], to: archive, options: CompressionOptions(format: format))
    let log = ProgressRecorder()
    try await fixture.service.test(archive, progress: { log.append($0) })
    let final = try #require(log.snapshots.last)
    #expect(final.fraction == 1)
    #expect(final.processing?.totalBytes == 0)
    #expect(final.processing?.completedFiles == 1)
    #expect(final.processing?.bytesPerSecond == nil || final.processing?.bytesPerSecond == 0)
}

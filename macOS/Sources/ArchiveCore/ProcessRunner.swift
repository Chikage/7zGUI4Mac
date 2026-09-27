import Darwin
import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: String
}

public struct ProcessRunner: Sendable {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }

    public func run(
        arguments: [String], directory: URL? = nil, password: String = "",
        captureListing: Bool = false, compressionOutput: URL? = nil,
        readOperation: ArchiveReadOperation? = nil, totals: ProcessingMetrics? = nil,
        progress: @escaping @Sendable (EngineProgress) -> Void = { _ in }
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            let worker = Task.detached(priority: .userInitiated) {
                try control.execute(
                    executable: executable, arguments: arguments, directory: directory,
                    password: password, captureListing: captureListing, compressionOutput: compressionOutput,
                    readOperation: readOperation, totals: totals, progress: progress)
            }
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            control.cancel()
        }
    }
}

/// The worker owns all I/O. The lock serializes launch, cancellation and finish;
/// no Process or FileHandle is exposed across the boundary.
private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    func execute(
        executable: URL, arguments: [String], directory: URL?, password: String,
        captureListing: Bool, compressionOutput: URL?, readOperation: ArchiveReadOperation?,
        totals: ProcessingMetrics?, progress: @Sendable (EngineProgress) -> Void
    ) throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ArchiveError.engineMissing }
        let child = Process()
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        child.environment = environment
        child.standardOutput = output
        child.standardError = errors
        child.standardInput = input
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        do {
            try child.run()
            process = child
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
            lock.lock()
            process = nil
            lock.unlock()
        }
        // Passwords use stdin, never argv, shell interpolation, preferences or logs.
        if !password.isEmpty {
            try input.fileHandleForWriting.write(contentsOf: Data((password + "\n" + password + "\n").utf8))
        }
        try input.fileHandleForWriting.close()
        var captured = Data()
        var diagnostics = Data()
        let limit = captureListing ? 64 * 1024 * 1024 : 128 * 1024
        var parser = EngineProgressParser(
            compressionOutput: compressionOutput, readOperation: readOperation, totals: totals)
        var errorParser = EngineProgressParser(readOperation: readOperation)
        if let update = parser.start() { progress(update) }
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        var descriptors = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        // Drain both pipes on this worker: stderr telemetry must stay live while
        // stdout contains a JSON report, and neither pipe may fill and deadlock.
        while descriptors.contains(where: { $0.fd >= 0 }) {
            let ready = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), -1) }
            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            for index in descriptors.indices where descriptors[index].revents != 0 {
                if descriptors[index].revents & Int16(POLLNVAL) != 0 { throw POSIXError(.EBADF) }
                let chunk = handles[index].availableData
                if chunk.isEmpty {
                    descriptors[index].fd = -1
                    continue
                }
                if index == 1 && captureListing {
                    diagnostics.append(chunk)
                    if diagnostics.count > 128 * 1024 { diagnostics.removeFirst(diagnostics.count - 128 * 1024) }
                } else {
                    captured.append(chunk)
                    if captured.count > limit {
                        if captureListing { throw ArchiveError.listingTooLarge }
                        captured.removeFirst(captured.count - limit)
                    }
                }
                if index == 1 {
                    for update in errorParser.consume(chunk) { progress(update) }
                } else if !captureListing {
                    for update in parser.consume(chunk) { progress(update) }
                }
            }
        }
        child.waitUntilExit()
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if !captureListing && child.terminationStatus == 0, let update = parser.finish() { progress(update) }
        if child.terminationStatus == 0, let update = errorParser.finish() { progress(update) }
        // Exit 5 is an RZ extraction with attribute warnings and a valid JSON report.
        if captureListing && child.terminationStatus != 0 && child.terminationStatus != 5 {
            captured.append(diagnostics)
        }
        var text = String(decoding: captured, as: UTF8.self)
        if !captureListing && !password.isEmpty { text = text.replacingOccurrences(of: password, with: "••••••") }
        return ProcessResult(status: child.terminationStatus, output: text)
    }
}

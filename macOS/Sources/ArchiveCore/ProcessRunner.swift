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
        progress: @escaping @Sendable (EngineProgress) -> Void = { _ in }
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            let worker = Task.detached(priority: .userInitiated) {
                try control.execute(
                    executable: executable, arguments: arguments, directory: directory,
                    password: password, captureListing: captureListing, compressionOutput: compressionOutput,
                    progress: progress)
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
        captureListing: Bool, compressionOutput: URL?, progress: @Sendable (EngineProgress) -> Void
    ) throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ArchiveError.engineMissing }
        let child = Process()
        let output = Pipe()
        let input = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        child.environment = environment
        child.standardOutput = output
        child.standardError = output
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
        let limit = captureListing ? 64 * 1024 * 1024 : 128 * 1024
        var parser = EngineProgressParser(compressionOutput: compressionOutput)
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            captured.append(chunk)
            if captured.count > limit {
                if captureListing { throw ArchiveError.listingTooLarge }
                captured.removeFirst(captured.count - limit)
            }
            guard !captureListing else { continue }
            for update in parser.consume(chunk) { progress(update) }
        }
        child.waitUntilExit()
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if !captureListing && child.terminationStatus == 0, let update = parser.finish() { progress(update) }
        var text = String(decoding: captured, as: UTF8.self)
        if !captureListing && !password.isEmpty { text = text.replacingOccurrences(of: password, with: "••••••") }
        return ProcessResult(status: child.terminationStatus, output: text)
    }
}

import AppKit
import ArchiveCore
import Observation

struct FileClipboardSnapshot {
    let urls: [URL]
    let kind: FileTransferKind
    let changeCount: Int
}

@MainActor @Observable
final class FileClipboard {
    private let pasteboard: NSPasteboard
    private var cutChangeCount: Int?
    private var observedChangeCount: Int?
    private(set) var cutPaths: Set<String> = []
    private(set) var hasFiles = false

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func refresh() {
        guard observedChangeCount != pasteboard.changeCount else { return }
        observedChangeCount = pasteboard.changeCount
        hasFiles = !urls.isEmpty
        if cutChangeCount != pasteboard.changeCount {
            cutChangeCount = nil
            cutPaths = []
        }
    }

    func write(_ urls: [URL], kind: FileTransferKind) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls as [NSURL]) else {
            refresh()
            return
        }
        cutChangeCount = kind == .move ? pasteboard.changeCount : nil
        cutPaths = kind == .move ? Set(urls.map(\.path)) : []
        refresh()
    }

    func snapshot() -> FileClipboardSnapshot? {
        refresh()
        let files = urls
        guard !files.isEmpty else { return nil }
        return FileClipboardSnapshot(
            urls: files, kind: cutChangeCount == pasteboard.changeCount ? .move : .copy,
            changeCount: pasteboard.changeCount)
    }

    func finish(_ snapshot: FileClipboardSnapshot, completed: [URL]) {
        guard snapshot.kind == .move, snapshot.changeCount == pasteboard.changeCount else {
            refresh()
            return
        }
        let paths = Set(completed.map { canonicalPath($0) })
        let remaining = snapshot.urls.filter { url in
            let path = canonicalPath(url)
            return !paths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        if remaining.isEmpty {
            pasteboard.clearContents()
            refresh()
        } else if remaining.count != snapshot.urls.count {
            write(remaining, kind: .move)
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }

    private var urls: [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(\.isFileURL)
    }
}

struct TransferSpeedSample: Identifiable {
    var id: Double { fraction }
    let fraction: Double
    let bytesPerSecond: Double
}

/// Keep the whole transfer visible, with at most one endpoint per 0.1% progress bucket.
struct TransferSpeedHistory {
    private(set) var samples: [TransferSpeedSample] = []

    mutating func record(fraction: Double, bytesPerSecond: Double) {
        guard fraction.isFinite, bytesPerSecond.isFinite else { return }
        let fraction = min(1, max(0, fraction))
        guard fraction >= (samples.last?.fraction ?? 0) else { return }
        let sample = TransferSpeedSample(fraction: fraction, bytesPerSecond: max(0, bytesPerSecond))
        if samples.isEmpty { samples.append(TransferSpeedSample(fraction: 0, bytesPerSecond: 0)) }
        if let last = samples.last,
            last.fraction == fraction || (last.fraction > 0 && Int(last.fraction * 1_000) == Int(fraction * 1_000))
        {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
    }
}

@MainActor @Observable
final class FileTransferStore {
    private(set) var progress = FileTransferProgress()
    private(set) var sources: [URL] = []
    private(set) var destination = URL(fileURLWithPath: "/")
    private(set) var kind: FileTransferKind = .copy
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var isCancelling = false
    private(set) var result: FileTransferResult?
    private var speedHistory = TransferSpeedHistory()
    var samples: [TransferSpeedSample] { speedHistory.samples }
    private(set) var bytesPerSecond: Double = 0
    private(set) var elapsed: TimeInterval = 0
    var isPresented = false
    private var control = FileTransferControl()
    private var lastSample = ContinuousClock.now
    private var sampledBytes: Int64 = 0
    private var task: Task<Void, Never>?
    private let service = FileTransferService()

    var fraction: Double? {
        if let result { return result.succeeded ? 1 : (progress.fraction ?? 0) }
        return progress.fraction
    }
    var remainingSeconds: TimeInterval? {
        guard isRunning, !isPaused, !isCancelling, progress.phase == .copying, bytesPerSecond > 0 else { return nil }
        return Double(max(0, progress.totalBytes - progress.completedBytes)) / bytesPerSecond
    }
    var title: String {
        if isCancelling { return "正在取消…" }
        if isPaused { return "已暂停\(kind.title)" }
        if let result {
            if result.cancelled { return "已取消\(kind.title)" }
            if result.errorMessage != nil { return "\(kind.title)未完成" }
            return "\(kind.title)完成"
        }
        switch progress.phase {
        case .scanning: return "正在计算项目大小…"
        case .copying: return "正在\(kind.title)文件"
        case .moving: return "正在移动项目"
        case .finishing: return "正在保留属性并完成\(kind.title)…"
        }
    }

    func start(
        _ snapshot: FileClipboardSnapshot, to destination: URL, completion: @escaping (FileTransferResult) async -> Void
    ) {
        guard !isRunning else {
            isPresented = true
            return
        }
        sources = snapshot.urls
        kind = snapshot.kind
        self.destination = destination
        progress = FileTransferProgress()
        result = nil
        speedHistory = TransferSpeedHistory()
        elapsed = 0
        bytesPerSecond = 0
        sampledBytes = 0
        lastSample = .now
        control = FileTransferControl()
        isPaused = false
        isCancelling = false
        isRunning = true
        isPresented = true
        let control = control
        let channel = AsyncStream<FileTransferProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        task = Task {
            let reader = Task { for await value in channel.stream { progress = value } }
            let ticker = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                    sampleSpeed()
                }
            }
            let outcome = await service.transfer(snapshot.urls, to: destination, kind: snapshot.kind, control: control)
            {
                channel.continuation.yield($0)
            }
            channel.continuation.finish()
            await reader.value
            ticker.cancel()
            sampleSpeed(completed: outcome.succeeded)
            result = outcome
            isPaused = false
            isCancelling = false
            // Keep mutation guards up until the destination and clipboard have been refreshed.
            await completion(outcome)
            isRunning = false
            task = nil
        }
    }

    func togglePause() {
        guard isRunning, !isCancelling else { return }
        isPaused.toggle()
        control.setPaused(isPaused)
        lastSample = .now
        sampledBytes = progress.copiedBytes
        bytesPerSecond = 0
    }

    func cancel() {
        guard isRunning else { return }
        isCancelling = true
        isPaused = false
        control.cancel()
    }

    private func sampleSpeed(completed: Bool = false) {
        let now = ContinuousClock.now
        let interval = lastSample.duration(to: now)
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        lastSample = now
        defer { sampledBytes = progress.copiedBytes }
        guard !isPaused, seconds > 0 else { return }
        elapsed += seconds
        let delta = max(0, progress.copiedBytes - sampledBytes)
        if progress.phase == .copying || delta > 0 {
            bytesPerSecond = Double(delta) / seconds
        } else if completed {
            bytesPerSecond = samples.last?.bytesPerSecond ?? 0
        } else {
            bytesPerSecond = 0
        }
        // Include the final data interval even if a short copy finished between timer ticks.
        guard progress.copiedBytes > 0, let fraction = completed ? 1 : progress.fraction else { return }
        speedHistory.record(fraction: fraction, bytesPerSecond: bytesPerSecond)
    }
}

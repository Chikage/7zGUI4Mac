import Darwin
import Foundation

public enum FileTransferKind: String, Sendable {
    case copy, move
    public var title: String { self == .copy ? "复制" : "移动" }
}

public struct FileTransferProgress: Sendable {
    public enum Phase: Sendable { case scanning, copying, moving, finishing }
    public var phase: Phase = .scanning
    public var currentSource: URL?
    public var currentDestination: URL?
    public var completedBytes: Int64 = 0
    public var copiedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var completedItems = 0
    public var totalItems = 0

    public init() {}

    public var fraction: Double? {
        guard phase != .scanning else { return nil }
        let value =
            totalBytes > 0
            ? Double(completedBytes) / Double(totalBytes)
            : Double(completedItems) / Double(max(1, totalItems))
        // Publishing the destination and removing moved sources still has to succeed.
        return min(0.99, max(0, value))
    }
}

public struct FileTransferResult: Sendable {
    public var completedSources: [URL] = []
    public var destinations: [URL] = []
    public var cancelled = false
    public var errorMessage: String?
    public var succeeded: Bool { !cancelled && errorMessage == nil }
}

/// Shared with the synchronous copyfile callback; all mutable state is condition-protected.
public final class FileTransferControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false

    public init() {}

    public func setPaused(_ value: Bool) {
        condition.lock()
        paused = value
        condition.broadcast()
        condition.unlock()
    }

    public func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    func checkpoint() throws {
        condition.lock()
        defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        if cancelled { throw CancellationError() }
    }
}

public actor FileTransferService {
    public init() {}

    public func transfer(
        _ sources: [URL], to destination: URL, kind: FileTransferKind,
        control: FileTransferControl,
        progress: @escaping @Sendable (FileTransferProgress) -> Void
    ) async -> FileTransferResult {
        // copyfile is blocking. Use a dedicated worker and explicitly forward cancellation.
        await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                FileTransferWorker(control: control, report: progress).run(sources, to: destination, kind: kind)
            }.value
        } onCancel: {
            control.cancel()
        }
    }
}

private struct TransferNode: Equatable {
    enum Kind { case directory, file, link }
    let path: String
    let kind: Kind
    let bytes: Int64
    let inode: UInt64
    let device: Int32
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int

    init(_ url: URL, path: String) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError(url) }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .link
        default: throw ArchiveError.invalidInput("无法传输特殊文件“\(url.path)”。")
        }
        self.path = path
        bytes = kind == .file ? info.st_size : 0
        inode = info.st_ino
        device = info.st_dev
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanos = info.st_ctimespec.tv_nsec
    }
}

private func posixError(_ url: URL, code: Int32 = errno) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
}

/// Confined to a single worker; the C callback borrows it only during copyfile().
private final class FileTransferWorker {
    let control: FileTransferControl
    let report: @Sendable (FileTransferProgress) -> Void
    var progress = FileTransferProgress()
    private var lastReport = ContinuousClock.now
    private var fileCopied: Int64 = 0
    private var fileSize: Int64 = 0
    private let manager = FileManager.default

    init(control: FileTransferControl, report: @escaping @Sendable (FileTransferProgress) -> Void) {
        self.control = control
        self.report = report
    }

    func run(_ sources: [URL], to destination: URL, kind: FileTransferKind) -> FileTransferResult {
        var result = FileTransferResult()
        do {
            try control.checkpoint()
            guard destination.isFileURL, !sources.isEmpty, sources.allSatisfy(\.isFileURL) else {
                throw ArchiveError.invalidInput("请选择本地文件和目标文件夹。")
            }
            let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
            guard try TransferNode(destination, path: "").kind == .directory else {
                throw ArchiveError.invalidInput("粘贴位置必须是文件夹。")
            }
            // Resolve parent aliases, but never dereference a selected symbolic link.
            let normalized = Array(
                Set(
                    sources.map {
                        $0.deletingLastPathComponent().resolvingSymlinksInPath()
                            .appendingPathComponent($0.lastPathComponent).standardizedFileURL
                    })
            ).sorted { $0.path < $1.path }
            let roots = normalized.filter { url in
                !normalized.contains { parent in
                    parent != url && url.path.hasPrefix(parent.path + "/")
                        && (try? TransferNode(parent, path: "").kind) == .directory
                }
            }
            var plans: [(URL, [TransferNode])] = []
            for source in roots {
                progress.currentSource = source
                let root = try TransferNode(source, path: "")
                let isDescendant = root.kind == .directory ? try contains(destination, root: root) : false
                guard source.path != "/", !isDescendant
                else { throw ArchiveError.invalidInput("不能将文件夹粘贴到它自己或它的子文件夹中。") }
                let nodes = try scan(source)
                plans.append((source, nodes))
                progress.totalItems += nodes.count
                progress.totalBytes += nodes.reduce(0) { $0 + $1.bytes }
            }
            for (source, nodes) in plans {
                try control.checkpoint()
                guard let root = nodes.first else { continue }
                var target = availableDestination(source, in: destination, isDirectory: root.kind == .directory)
                progress.currentSource = source
                progress.currentDestination = target
                progress.phase = kind == .move ? .moving : .copying
                emit(force: true)
                try verify(source, node: root)
                if kind == .move {
                    var moved = false
                    // Pasting a cut item in its own folder is a no-op, not a renamed duplicate.
                    if source.deletingLastPathComponent() == destination {
                        target = source
                        moved = true
                    } else {
                        while true {
                            if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                                moved = true
                                break
                            }
                            let code = errno
                            if code == EEXIST {
                                target = availableDestination(
                                    source, in: destination, isDirectory: root.kind == .directory)
                                continue
                            }
                            if code == EXDEV { break }
                            throw posixError(source, code: code)
                        }
                    }
                    if moved {
                        progress.completedBytes += nodes.reduce(0) { $0 + $1.bytes }
                        progress.completedItems += nodes.count
                        result.completedSources.append(source)
                        result.destinations.append(target)
                        emit(force: true)
                        continue
                    }
                }
                try copy(source, nodes: nodes, to: destination, target: &target, kind: kind)
                result.completedSources.append(source)
                result.destinations.append(target)
            }
        } catch is CancellationError {
            result.cancelled = true
        } catch {
            let path = progress.currentSource?.path ?? destination.path
            result.errorMessage = "“\(path)”：\(error.localizedDescription)"
        }
        emit(force: true)
        return result
    }

    private func scan(_ source: URL, announcing: Bool = true) throws -> [TransferNode] {
        var nodes: [TransferNode] = []
        var pending = [(source, "")]
        while let (url, path) = pending.popLast() {
            try control.checkpoint()
            let node = try TransferNode(url, path: path)
            nodes.append(node)
            if announcing {
                progress.currentSource = url
                emit()
            }
            if node.kind == .directory {
                let children = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
                pending += children.map {
                    ($0, path.isEmpty ? $0.lastPathComponent : path + "/" + $0.lastPathComponent)
                }
            }
        }
        return nodes
    }

    private func copy(
        _ source: URL, nodes: [TransferNode], to destination: URL, target: inout URL, kind: FileTransferKind
    ) throws {
        let staging = destination.appendingPathComponent(".7zip-transfer-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(
            at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let payload = staging.appendingPathComponent("payload")
        defer {
            // Copied directory permissions may be read-only when cancellation occurs during metadata restoration.
            for node in nodes where node.kind == .directory {
                let output = node.path.isEmpty ? payload : payload.appendingPathComponent(node.path)
                var info = stat()
                if lstat(output.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                    chmod(output.path, info.st_mode | 0o700)
                }
            }
            try? manager.removeItem(at: staging)
        }
        progress.phase = .copying
        for node in nodes {
            try control.checkpoint()
            let input = node.path.isEmpty ? source : source.appendingPathComponent(node.path)
            let output = node.path.isEmpty ? payload : payload.appendingPathComponent(node.path)
            try verify(input, node: node)
            progress.currentSource = input
            progress.currentDestination = node.path.isEmpty ? target : target.appendingPathComponent(node.path)
            emit()
            if node.kind == .directory {
                try manager.createDirectory(
                    at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } else {
                fileCopied = 0
                fileSize = node.bytes
                try copyFile(input, to: output, flags: UInt32(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW))
                try verify(input, node: node)
                progress.completedBytes += max(0, node.bytes - fileCopied)
            }
            progress.completedItems += 1
        }
        progress.phase = .finishing
        emit(force: true)
        // Apply directory permissions after children, including read-only folders.
        for node in nodes.reversed() where node.kind == .directory {
            try control.checkpoint()
            let input = node.path.isEmpty ? source : source.appendingPathComponent(node.path)
            let output = node.path.isEmpty ? payload : payload.appendingPathComponent(node.path)
            try copyFile(input, to: output, flags: UInt32(COPYFILE_METADATA | COPYFILE_NOFOLLOW))
        }
        // A changed tree must never be deleted after a cross-volume move.
        if kind == .move, try scan(source, announcing: false) != nodes {
            throw ArchiveError.invalidInput("源文件夹在传输期间发生变化，已保留源文件，请重新操作。")
        }
        try control.checkpoint()
        while renamex_np(payload.path, target.path, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else { throw posixError(target) }
            target = availableDestination(source, in: destination, isDirectory: nodes.first?.kind == .directory)
        }
        if kind == .move {
            // Once committed, finish this item even if Cancel arrives. Never remove the only complete copy.
            do { try manager.removeItem(at: source) } catch {
                throw ArchiveError.invalidInput("文件已复制到“\(target.path)”，但无法移除源项目：\(error.localizedDescription)")
            }
        }
    }

    private func verify(_ url: URL, node: TransferNode) throws {
        guard try TransferNode(url, path: node.path) == node else {
            throw ArchiveError.invalidInput("源项目在传输期间发生变化，已保留源文件，请重新操作。")
        }
    }

    private func contains(_ destination: URL, root: TransferNode) throws -> Bool {
        var cursor = destination
        while true {
            let node = try TransferNode(cursor, path: "")
            if node.device == root.device, node.inode == root.inode { return true }
            if cursor.path == "/" { return false }
            cursor.deleteLastPathComponent()
        }
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func availableDestination(_ source: URL, in directory: URL, isDirectory: Bool) -> URL {
        let name = source.lastPathComponent
        var target = directory.appendingPathComponent(name)
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var suffix = 1
        while exists(target) {
            let label = suffix == 1 ? "副本" : "副本 \(suffix)"
            target = directory.appendingPathComponent(stem + "（\(label)）" + (ext.isEmpty ? "" : "." + ext))
            suffix += 1
        }
        return target
    }

    private func copyFile(_ source: URL, to destination: URL, flags: UInt32) throws {
        guard let state = copyfile_state_alloc() else { throw posixError(source, code: ENOMEM) }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, state, _, _, context in
            guard let context else { return COPYFILE_QUIT }
            let worker = Unmanaged<FileTransferWorker>.fromOpaque(context).takeUnretainedValue()
            do { try worker.control.checkpoint() } catch { return COPYFILE_QUIT }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                let bounded = min(worker.fileSize, Int64(copied))
                let delta = max(0, bounded - worker.fileCopied)
                let firstData = worker.progress.copiedBytes == 0 && delta > 0
                worker.fileCopied = bounded
                worker.progress.completedBytes += delta
                worker.progress.copiedBytes += delta
                worker.emit(force: firstData)
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(self).toOpaque())
        if copyfile(source.path, destination.path, state, flags) != 0 {
            let code = errno
            try control.checkpoint()
            throw posixError(source, code: code)
        }
    }

    private func emit(force: Bool = false) {
        let now = ContinuousClock.now
        guard force || lastReport.duration(to: now) >= .milliseconds(100) else { return }
        lastReport = now
        report(progress)
    }
}

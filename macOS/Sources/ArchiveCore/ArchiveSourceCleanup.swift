import Darwin
import Foundation

/// Only unchanged, fully included source trees may be recycled after verification.
struct ArchiveSourceCleanup {
    let sources: [URL]
    private let snapshots: [[String: Identity]]

    static func validate(_ options: CompressionOptions) throws {
        let rar = options.rar
        if options.format == .rar && (
            !rar.includeMasks.isEmpty || !rar.excludeMasks.isEmpty || rar.excludeEmptyDirectories
                || rar.minimumSize != nil || rar.maximumSize != nil
                || rar.modifiedAfter != nil || rar.modifiedBefore != nil || rar.nameCase != "original")
        {
            throw ArchiveError.invalidInput("RAR 文件筛选或名称大小写转换可能遗漏来源，不能同时启用自动删除原文件。请清除筛选条件并保留原始名称大小写。")
        }
    }

    init(sources: [URL]) throws {
        let unique = Set(sources.map { source in
            let url = source.standardizedFileURL
            // Resolve parent aliases (including /tmp -> /private/tmp), but retain the
            // final component so snapshot() can reject a selected symbolic link.
            return url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent)
        })
        self.sources = unique.filter { source in
            !unique.contains { $0 != source && source.path.hasPrefix($0.path + "/") }
        }.sorted { $0.path < $1.path }
        guard !self.sources.isEmpty, self.sources.allSatisfy({ $0.isFileURL && $0.path != "/" }) else {
            throw ArchiveError.invalidInput("请先添加要压缩的文件，且不能自动删除磁盘根目录。")
        }
        snapshots = try self.sources.map(Self.snapshot)
    }

    func recycleUnchangedSources(
        using recycle: (URL) throws -> Void,
        progress: @Sendable (EngineProgress) -> Void
    ) throws {
        // Validate every tree before recycling any of them.
        for (source, snapshot) in zip(sources, snapshots) {
            guard try Self.snapshot(source) == snapshot else {
                throw ArchiveError.invalidInput("原文件在压缩期间发生变化，已保留全部原文件。")
            }
        }
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            guard try Self.snapshot(source) == snapshots[index] else {
                throw ArchiveError.invalidInput("原文件在清理前发生变化，已保留尚未移入废纸篓的项目。")
            }
            progress(EngineProgress(
                fraction: Double(index) / Double(sources.count),
                message: "校验通过，正在将原文件移入废纸篓（\(index + 1)/\(sources.count)）…"))
            do { try recycle(source) } catch {
                throw ArchiveError.invalidInput(
                    "已将 \(index) 个项目移入废纸篓；其余原文件已保留。\(error.localizedDescription)")
            }
        }
        progress(EngineProgress(fraction: 1, message: "校验通过，原文件已移入废纸篓"))
    }

    private struct Identity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let mode: UInt16
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }

        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
            }
            guard [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT) else {
                throw ArchiveError.invalidInput("自动删除仅支持普通文件和文件夹；来源含链接或特殊文件，请关闭自动删除。")
            }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            mode = info.st_mode
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    private static func snapshot(_ root: URL) throws -> [String: Identity] {
        var result: [String: Identity] = [:]
        var pending = [root]
        while let url = pending.popLast() {
            try Task.checkCancellation()
            let identity = try Identity(url)
            result[url.path] = identity
            if identity.isDirectory {
                pending += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            }
        }
        return result
    }
}

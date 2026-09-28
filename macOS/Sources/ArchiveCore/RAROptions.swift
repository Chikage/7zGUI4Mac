import Foundation

public enum RARRecoveryVolumeMode: String, CaseIterable, Identifiable, Sendable {
    case count, percent
    public var id: String { rawValue }
    public var title: String { self == .count ? "个恢复卷" : "% 数据卷数量" }
}

public struct RAROptions: Sendable, Equatable {
    public var level = 3
    public var solid = false
    public var dictionaryMB = 32
    public var threads = 0
    public var volumeSizeBytes: Int64?
    public var recoveryRecordPercent = 0
    public var recoveryVolumeAmount = 0
    public var recoveryVolumeMode: RARRecoveryVolumeMode = .count
    public var useBlake2 = false
    public var quickOpen = "auto"
    public var lockArchive = false
    public var testAfterCreation = true
    public var excludeEmptyDirectories = false
    public var storeLinks = false
    public var comment = ""
    public var includeMasks = ""
    public var excludeMasks = ""
    public var storeExtensions = ""
    public var archivePath = ""
    public var nameCase = "original"
    public var archiveTime = "current"
    public var saveCreationTime = false
    public var saveAccessTime = false
    public var disableNameSort = false
    public var ignoreAttributes = false
    public var minimumSize: Int64?
    public var maximumSize: Int64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?

    public init() {}

    public func validate(password: String = "") throws {
        guard (0...5).contains(level), [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024].contains(dictionaryMB),
            (0...64).contains(threads), (0...100).contains(recoveryRecordPercent),
            (0...65534).contains(recoveryVolumeAmount),
            ["auto", "always", "never"].contains(quickOpen),
            ["original", "lower", "upper"].contains(nameCase),
            ["current", "latest", "keep"].contains(archiveTime)
        else { throw ArchiveError.invalidInput("RAR 参数超出允许范围。") }
        try Self.validatePassword(password)
        if let size = volumeSizeBytes, size < 64 * 1024 {
            throw ArchiveError.invalidInput("RAR 每卷大小至少为 64 KiB。")
        }
        if recoveryVolumeAmount > 0 && volumeSizeBytes == nil {
            throw ArchiveError.invalidInput("创建 REV 恢复卷前，请先启用 RAR 分卷。")
        }
        if recoveryVolumeMode == .percent && recoveryVolumeAmount > 100 {
            throw ArchiveError.invalidInput("恢复卷比例必须在 1–100% 之间。")
        }
        if !archivePath.isEmpty { try ArchivePath.validate(archivePath) }
        guard comment.utf8.count <= 256 * 1024, !comment.contains("\0") else {
            throw ArchiveError.invalidInput("归档注释不能超过 256 KiB 或包含 NUL 字符。")
        }
        for text in [includeMasks, excludeMasks, storeExtensions, archivePath] {
            guard text.utf8.count < 32 * 1024,
                !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" })
            else { throw ArchiveError.invalidInput("文件筛选条件包含控制字符或过长。") }
        }
        for mask in Self.masks(includeMasks) + Self.masks(excludeMasks) {
            guard !mask.hasPrefix("@") else { throw ArchiveError.invalidInput("筛选条件不能以 @ 开头。") }
        }
        if let minimumSize, minimumSize < 0 { throw ArchiveError.invalidInput("最小文件大小不能为负数。") }
        if let maximumSize, maximumSize <= 0 { throw ArchiveError.invalidInput("最大文件大小必须大于零。") }
        if let minimumSize, let maximumSize, minimumSize >= maximumSize {
            throw ArchiveError.invalidInput("最大文件大小必须大于最小文件大小。")
        }
        if let modifiedAfter, let modifiedBefore, modifiedAfter >= modifiedBefore {
            throw ArchiveError.invalidInput("结束时间必须晚于开始时间。")
        }
    }

    static func validatePassword(_ password: String) throws {
        guard password.unicodeScalars.count <= 127,
            !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw ArchiveError.invalidInput("RAR 密码最多 127 个字符，不能包含换行或控制字符。") }
    }

    static func masks(_ value: String) -> [String] {
        value.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func compressionArguments() -> [String] {
        var args = ["-m\(level)", "-md\(dictionaryMB)m", solid ? "-s" : "-s=-", useBlake2 ? "-htb" : "-htc"]
        if threads > 0 { args.append("-mt\(threads)") }
        if let volumeSizeBytes { args.append("-v\(volumeSizeBytes)b") }
        // Recovery records belong to each volume and must be written before REV creation.
        if recoveryRecordPercent > 0 { args.append("-rr\(recoveryRecordPercent)p") }
        if lockArchive { args.append("-k") }
        if excludeEmptyDirectories { args.append("-ed") }
        args.append(storeLinks ? "-ol" : "-ol-")
        if disableNameSort { args.append("-ds") }
        if ignoreAttributes { args.append("-ai") }
        if quickOpen != "auto" { args.append(quickOpen == "always" ? "-qo+" : "-qo-") }
        if !archivePath.isEmpty { args.append("-ap\(archivePath)") }
        if nameCase != "original" { args.append(nameCase == "lower" ? "-cl" : "-cu") }
        if archiveTime != "current" { args.append(archiveTime == "latest" ? "-tl" : "-tk") }
        if saveCreationTime { args.append("-tsc") }
        if saveAccessTime { args.append("-tsa") }
        if !storeExtensions.isEmpty { args.append("-ms\(storeExtensions)") }
        args += Self.masks(includeMasks).map { "-n\($0)" }
        args += Self.masks(excludeMasks).map { "-x\($0)" }
        if let minimumSize { args.append("-sm\(minimumSize)b") }
        if let maximumSize { args.append("-sl\(maximumSize)b") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        if let modifiedAfter { args.append("-ta\(formatter.string(from: modifiedAfter))") }
        if let modifiedBefore { args.append("-tb\(formatter.string(from: modifiedBefore))") }
        return args
    }

    var recoveryVolumeCommand: String {
        "rv\(recoveryVolumeAmount)" + (recoveryVolumeMode == .percent ? "p" : "")
    }
}

public enum RARToolOperation: String, CaseIterable, Identifiable, Sendable {
    case repair, reconstruct, recoveryRecord, recoveryVolumes, comment, exportComment, lock
    case add, update, freshen, delete, rename, extractFlat, list, technicalList, convertSFX, removeSFX
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .repair: "使用恢复记录修复（r）"
        case .reconstruct: "使用 REV 重建分卷（rc）"
        case .recoveryRecord: "添加恢复记录（rr）"
        case .recoveryVolumes: "生成 REV 恢复卷（rv）"
        case .comment: "设置归档注释（c）"
        case .exportComment: "导出归档注释（cw）"
        case .lock: "锁定归档（k）"
        case .add: "添加文件到副本（a）"
        case .update: "添加及更新文件（u）"
        case .freshen: "仅更新已有文件（f）"
        case .delete: "删除副本中的条目（d）"
        case .rename: "重命名副本中的条目（rn）"
        case .extractFlat: "解压到同一层目录（e）"
        case .list: "导出文件清单（lb）"
        case .technicalList: "导出详细信息（lta）"
        case .convertSFX: "生成 macOS 自解压程序（s）"
        case .removeSFX: "移除自解压模块（s-）"
        }
    }
    public var needsSources: Bool { [.add, .update, .freshen].contains(self) }
    public var permitsVolumes: Bool {
        [.repair, .reconstruct, .recoveryVolumes, .extractFlat, .list, .technicalList, .exportComment].contains(self)
    }
}

public struct RARToolRequest: Sendable {
    public var operation: RARToolOperation = .repair
    public var options = RAROptions()
    public var password = ""
    public var sources: [URL] = []
    public var entryNames = ""
    public var renamedPath = ""
    public init() {}
}

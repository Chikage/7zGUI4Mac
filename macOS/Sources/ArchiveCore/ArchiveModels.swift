import Foundation

public struct ArchiveEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    public let packedSize: Int64?
    public let modified: String
    public let isDirectory: Bool
    public let isEncrypted: Bool
    public let isLink: Bool
    public var name: String { (path as NSString).lastPathComponent }

    public init(
        path: String, size: Int64 = 0, packedSize: Int64? = nil,
        modified: String = "", isDirectory: Bool = false,
        isEncrypted: Bool = false, isLink: Bool = false
    ) {
        self.path = path
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
        self.isLink = isLink
    }
}

public struct ArchiveListing: Sendable {
    public let url: URL
    public let format: String
    public let physicalSize: Int64
    public let entries: [ArchiveEntry]
    public let recoveryDetails: RecoveryDetails?
    public let isLocked: Bool
    public let directoryUnavailable: Bool
    public let preservesMetadata: Bool
    public let recoveryEncryption: RecoveryEncryption?
    public let requiresKeyFile: Bool
    private let archiveEncrypted: Bool
    public init(
        url: URL, format: String, physicalSize: Int64, entries: [ArchiveEntry], recoveryDetails: RecoveryDetails? = nil,
        encrypted: Bool = false, locked: Bool = false, preservesMetadata: Bool = false,
        directoryUnavailable: Bool = false, recoveryEncryption: RecoveryEncryption? = nil, requiresKeyFile: Bool = false
    ) {
        self.url = url
        self.format = format
        self.physicalSize = physicalSize
        self.entries = entries
        self.recoveryDetails = recoveryDetails
        self.archiveEncrypted = encrypted
        self.isLocked = locked
        self.directoryUnavailable = directoryUnavailable
        self.preservesMetadata = preservesMetadata
        self.recoveryEncryption = recoveryEncryption
        self.requiresKeyFile = requiresKeyFile
    }
    public var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    public var totalSize: Int64 {
        entries.reduce(0) { total, entry in
            let (sum, overflow) = total.addingReportingOverflow(entry.size)
            return overflow ? Int64.max : sum
        }
    }
    public var isEncrypted: Bool { archiveEncrypted || entries.contains(where: \.isEncrypted) }
    public var supportsRecovery: Bool { format == "RZ" }
}

public enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case sevenZip = "7z"
    case zip = "zip"
    case tar = "tar"
    case recovery = "rz"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .sevenZip: "7z"
        case .recovery: "可恢复 RZ"
        default: rawValue.uppercased()
        }
    }
    public var supportsPassword: Bool { self == .sevenZip || self == .zip || self == .recovery }
    public var supportsCompressionLevel: Bool { self == .sevenZip || self == .zip }
    public var explanation: String {
        switch self {
        case .sevenZip: "7z 使用 LZMA2 压缩，适合追求更小体积。"
        case .zip: "ZIP 便于跨平台分享；加密 ZIP 需要支持 AES 的解压软件。"
        case .tar: "TAR 仅打包文件，不压缩，也不支持密码。"
        case .recovery: "生成带恢复卷的归档包，适合需要防损坏的资料保存。此实验格式仅本应用支持。"
        }
    }
}

public enum RecoveryEncryption: Int, CaseIterable, Identifiable, Sendable {
    case standard = 1
    case dual = 2
    public var id: Int { rawValue }
    public var title: String { self == .standard ? "标准加密" : "双层加密（增加 AES）" }
    public var algorithms: String {
        self == .standard ? "XChaCha20-Poly1305" : "XChaCha20-Poly1305 + AES-256-GCM"
    }
    var argument: String { self == .standard ? "standard" : "dual" }
}

public enum CountedRecoveryProfile: Int, Sendable {
    case compatible = 4
    case paged = 5
}

public struct CompressionOptions: Sendable {
    public var format: ArchiveFormat
    public var level: Int
    public var password: String
    public var encryptNames: Bool
    public var recoveryVolumeSizeBytes: Int64
    public var recoveryPayload: RecoveryPayload
    /// Counted, equal-sized volumes. Nil retains the legacy size/budget API.
    public var recoveryVolumeCounts: RecoveryVolumeCounts?
    /// New counted archives use the protected paginated index. Ignored by the legacy size/budget API.
    public var countedRecoveryProfile: CountedRecoveryProfile
    public var preserveMetadata: Bool
    public var recoveryEncryption: RecoveryEncryption
    public var generateRecoveryKeyFile: Bool
    public init(
        format: ArchiveFormat = .sevenZip, level: Int = 5,
        password: String = "", encryptNames: Bool = true,
        recoveryVolumeSizeBytes: Int64 = 64 * 1024 * 1024,
        recoveryPayload: RecoveryPayload = .percentage(basisPoints: 2000), preserveMetadata: Bool = true,
        recoveryEncryption: RecoveryEncryption = .standard, generateRecoveryKeyFile: Bool = false,
        recoveryVolumeCounts: RecoveryVolumeCounts? = nil, countedRecoveryProfile: CountedRecoveryProfile = .paged
    ) {
        self.format = format
        self.level = level
        self.password = password
        self.encryptNames = encryptNames
        self.recoveryVolumeSizeBytes = recoveryVolumeSizeBytes
        self.recoveryPayload = recoveryPayload
        self.recoveryVolumeCounts = recoveryVolumeCounts
        self.countedRecoveryProfile = countedRecoveryProfile
        self.preserveMetadata = preserveMetadata
        self.recoveryEncryption = recoveryEncryption
        self.generateRecoveryKeyFile = generateRecoveryKeyFile
    }
}

public struct ArchiveExtraction: Sendable {
    public let url: URL
    public let metadataWarningCount: Int
    public let metadataWarnings: [String]
    public init(url: URL, metadataWarningCount: Int = 0, metadataWarnings: [String] = []) {
        self.url = url
        self.metadataWarningCount = metadataWarningCount
        self.metadataWarnings = metadataWarnings
    }
}

public struct EngineProgress: Sendable {
    public let fraction: Double?
    public let message: String
    public let compression: CompressionMetrics?
    public let processing: ProcessingMetrics?
    public let timestamp = ContinuousClock.now
    public init(
        fraction: Double? = nil, message: String, compression: CompressionMetrics? = nil,
        processing: ProcessingMetrics? = nil
    ) {
        self.fraction = fraction
        self.message = message
        self.compression = compression
        self.processing = processing
    }
}

public enum ArchiveReadOperation: Sendable {
    case extract, verify

    var message: String { self == .extract ? "正在解压文件…" : "正在校验文件内容…" }
    var completionMessage: String { self == .extract ? "解压完成，正在保存…" : "校验完成" }
}

public struct ProcessingMetrics: Sendable, Equatable {
    public var processedBytes: Int64 = 0
    public var totalBytes: Int64
    public var completedFiles: Int64 = 0
    /// Nil while checking storage blocks, where original file counts do not apply.
    public var totalFiles: Int64?
    public var bytesPerSecond: Double?
    public var isEstimated = false

    public init(totalBytes: Int64, totalFiles: Int64? = nil) {
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
    }
}

public struct CompressionMetrics: Sendable, Equatable {
    public var processedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var completedFiles: Int64 = 0
    public var totalFiles: Int64 = 0
    public var compressedBytes: Int64?
    public var bytesPerSecond: Double?
    public var isEstimated = false
    public var excludesRecovery = false

    public init() {}

    /// Stored size / processed input size. Values over 100% are valid for small
    /// or incompressible inputs; zero-byte input has no meaningful ratio.
    public var ratio: Double? {
        guard processedBytes > 0, let compressedBytes, compressedBytes > 0 else { return nil }
        return Double(compressedBytes) / Double(processedBytes)
    }
}

public enum ArchiveError: LocalizedError, Sendable {
    case engineMissing
    case recoveryEngineMissing
    case recoveryEngineFailed(Int32, String)
    case recoveryRepairable
    case recoveryUnrecoverable
    case invalidInput(String)
    case unsafeEntry(String)
    case passwordRequired
    case keyFileRequired
    case engineFailed(Int32, String)
    case listingTooLarge
    case malformedListing

    public var errorDescription: String? {
        switch self {
        case .engineMissing: "找不到 7-Zip 内核，请使用 Scripts/package_app.sh 重新打包应用。"
        case .recoveryEngineMissing: "找不到可恢复归档内核，请使用 Scripts/package_app.sh 重新打包应用。"
        case .recoveryEngineFailed(let code, let detail): "可恢复归档操作失败（\(code)）。\n\(detail)"
        case .recoveryRepairable: "归档存在损坏、缺卷或索引副本缺失，仍可恢复。请点击“修复归档”生成完整副本。"
        case .recoveryUnrecoverable: "归档的部分数据超过恢复能力，无法完整修复。请补回缺失的分卷或恢复卷后重试。"
        case .invalidInput(let message): message
        case .unsafeEntry(let path): "归档包含不安全路径或链接，已停止解压：\(path)"
        case .passwordRequired: "此归档需要密码，或输入的密码不正确。"
        case .keyFileRequired: "未找到可用的恢复密钥，请选择创建此归档时生成的 .rzkey 文件。"
        case .engineFailed(let code, let detail): "7-Zip 操作失败（\(code)）。\n\(detail)"
        case .listingTooLarge: "归档文件清单过大，无法安全显示。"
        case .malformedListing: "无法可靠读取归档清单，文件名可能含有不支持的换行符。"
        }
    }
}

public enum ArchivePath {
    public static func validate(_ path: String) throws {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"),
            !normalized.contains(":"),
            !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            !normalized.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else {
            throw ArchiveError.unsafeEntry(path)
        }
    }

    public static func validateFilename(_ name: String) throws {
        try validate(name)
        guard !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
            !name.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw ArchiveError.invalidInput("请输入有效的文件或文件夹名称。")
        }
    }

    public static func extractionName(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
        return name.isEmpty ? "解压文件" : name
    }
}

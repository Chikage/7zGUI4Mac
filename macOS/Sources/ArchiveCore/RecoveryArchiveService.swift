import Darwin
import Foundation

public enum RecoveryArchive {
    public static func keyFileURL(for archive: URL) -> URL {
        archive.deletingPathExtension().appendingPathExtension("rzkey")
    }
    /// Resolve a Finder package, a CLI-created set directory, or any member volume.
    public static func directory(for url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        switch url.pathExtension.lowercased() {
        case "rz": return URL(fileURLWithPath: url.path, isDirectory: true)
        case "rzv", "rzr", "rzm": return url.deletingLastPathComponent()
        default:
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.rzm").path) {
                return URL(fileURLWithPath: url.path, isDirectory: true)
            }
            return nil
        }
    }
}

enum RecoveryListingParser {
    private struct Listing: Decodable {
        let version: Int
        let entries: [Entry]
        let recovery: RecoveryDetails?
        let encrypted: Bool?
        let locked: Bool?
        let preservesMetadata: Bool?
        let directoryUnavailable: Bool?
        let encryptionSuite: Int?
        let requiresKeyFile: Bool?
        struct Entry: Decodable {
            let path: String
            let size: Int64
            let isDirectory: Bool
        }
    }

    static func parse(_ output: String, url: URL, physicalSize: Int64) throws -> ArchiveListing {
        guard let listing = try? JSONDecoder().decode(Listing.self, from: Data(output.utf8)),
            listing.version == 1, listing.entries.count <= 100_000, listing.recovery?.isValid != false
        else { throw ArchiveError.malformedListing }
        guard listing.locked != true || (listing.encrypted == true && listing.entries.isEmpty) else {
            throw ArchiveError.malformedListing
        }
        guard listing.directoryUnavailable != true || listing.entries.isEmpty else {
            throw ArchiveError.malformedListing
        }
        guard listing.requiresKeyFile != true || listing.encrypted == true else { throw ArchiveError.malformedListing }
        let encryption: RecoveryEncryption?
        if listing.encrypted == true {
            guard let suite = RecoveryEncryption(rawValue: listing.encryptionSuite ?? 1) else {
                throw ArchiveError.malformedListing
            }
            encryption = suite
        } else {
            guard listing.encryptionSuite == nil || listing.encryptionSuite == 0 else {
                throw ArchiveError.malformedListing
            }
            encryption = nil
        }
        var paths: Set<String> = []
        let entries = try listing.entries.map { entry in
            try ArchivePath.validate(entry.path)
            guard entry.size >= 0, !entry.isDirectory || entry.size == 0,
                paths.insert(entry.path).inserted
            else { throw ArchiveError.malformedListing }
            return ArchiveEntry(
                path: entry.path, size: entry.size, isDirectory: entry.isDirectory,
                isEncrypted: listing.encrypted == true)
        }
        return ArchiveListing(
            url: url, format: "RZ", physicalSize: physicalSize, entries: entries, recoveryDetails: listing.recovery,
            encrypted: listing.encrypted == true, locked: listing.locked == true,
            preservesMetadata: listing.preservesMetadata == true,
            directoryUnavailable: listing.directoryUnavailable == true, recoveryEncryption: encryption,
            requiresKeyFile: listing.requiresKeyFile == true)
    }
}

actor RecoveryArchiveService {
    private let runner: ProcessRunner
    private let fm = FileManager.default

    init(executable: URL) { runner = ProcessRunner(executable: executable) }

    func supportsAES() async throws -> Bool {
        struct Capabilities: Decodable {
            let version: Int
            let aes256gcm: Bool
        }
        let result = try await run(["--capabilities"], captureListing: true)
        try check(result)
        guard let value = try? JSONDecoder().decode(Capabilities.self, from: Data(result.output.utf8)),
            value.version == 1
        else {
            throw ArchiveError.malformedListing
        }
        return value.aes256gcm
    }

    func list(_ directory: URL, password: String, keyFile: URL?) async throws -> ArchiveListing {
        let credentials = try credentialArguments(password, keyFile: keyFile)
        let result = try await run(
            ["list", directory.path, "--json"] + credentials, password: password, captureListing: true)
        try check(result)
        let members = try fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var physicalSize: Int64 = 0
        for url in members where ["rzv", "rzr", "rzm"].contains(url.pathExtension) {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true {
                let (sum, overflow) = physicalSize.addingReportingOverflow(Int64(values.fileSize ?? 0))
                guard !overflow else { throw ArchiveError.malformedListing }
                physicalSize = sum
            }
        }
        return try RecoveryListingParser.parse(result.output, url: directory, physicalSize: physicalSize)
    }

    func test(_ directory: URL, password: String, keyFile: URL?, progress: @escaping @Sendable (EngineProgress) -> Void)
        async throws
    {
        let credentials = try credentialArguments(password, keyFile: keyFile)
        progress(EngineProgress(message: "正在校验数据卷、恢复卷和索引…"))
        let result = try await run(
            ["verify", directory.path, "--progress"] + credentials, password: password, readOperation: .verify,
            progress: progress)
        switch result.status {
        case 2: throw ArchiveError.recoveryRepairable
        case 3: throw ArchiveError.recoveryUnrecoverable
        default: try check(result)
        }
    }

    func compress(
        _ sources: [URL], to destination: URL, options: CompressionOptions,
        progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> URL {
        guard !sources.isEmpty else { throw ArchiveError.invalidInput("请先添加要压缩的文件。") }
        let recoveryArguments: [String]
        if let counts = options.recoveryVolumeCounts {
            recoveryArguments = ["--profile", "\(options.countedRecoveryProfile.rawValue)"] + (try counts.arguments())
        } else {
            guard (1024 * 1024...16 * 1024 * 1024 * 1024).contains(options.recoveryVolumeSizeBytes) else {
                throw ArchiveError.invalidInput("每卷上限必须在 1 MiB–16 GiB 之间。")
            }
            recoveryArguments =
                ["--volume-size", "\(options.recoveryVolumeSizeBytes)"] + (try options.recoveryPayload.arguments())
        }
        guard !options.generateRecoveryKeyFile || options.password.isEmpty else {
            throw ArchiveError.invalidInput("请选择密码或密钥文件中的一种保护方式。")
        }
        if options.recoveryEncryption == .dual {
            guard !options.password.isEmpty || options.generateRecoveryKeyFile else {
                throw ArchiveError.invalidInput("双层加密需要设置密码或生成密钥文件。")
            }
            guard try await supportsAES() else {
                throw ArchiveError.invalidInput("此设备不支持 AES-256-GCM 硬件加速，无法创建双层加密归档。")
            }
        }
        let securityArguments =
            (options.generateRecoveryKeyFile
                ? ["--generate-key-file", "--encryption", options.recoveryEncryption.argument]
                : options.password.isEmpty
                    ? []
                    : ["--encrypt", "--encryption", options.recoveryEncryption.argument]
                        + passwordArguments(options.password))
            + (options.preserveMetadata ? ["--metadata"] : ["--no-metadata"])
        let result = try await writeOutput(
            to: destination, password: options.password, generatesKeyFile: options.generateRecoveryKeyFile,
            progress: progress, message: "正在压缩文件并生成恢复卷…"
        ) { output in
            ["create-selected", output.path, "--progress", "--threads", "auto"]
                + recoveryArguments + securityArguments + ["--"]
                + sources.map(\.path)
        }
        return result.url
    }

    func extract(
        _ directory: URL, to destination: URL, password: String, keyFile: URL?, restoreAttributes: Bool,
        progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> ArchiveExtraction {
        let credentials = try credentialArguments(password, keyFile: keyFile)
        return try await writeOutput(
            to: destination, password: password, reportsMetadata: true, progress: progress, message: "正在校验、解压并恢复文件属性…"
        ) { output in
            ["extract", directory.path, output.path, "--json", "--progress"] + credentials
                + (restoreAttributes ? [] : ["--no-attributes"])
        }
    }

    func repair(
        _ directory: URL, to destination: URL, progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> URL {
        let result = try await writeOutput(to: destination, progress: progress, message: "正在重建缺损分卷并验证存储数据…") { output in
            ["repair", directory.path, output.path]
        }
        return result.url
    }

    private func writeOutput(
        to destination: URL, password: String = "", reportsMetadata: Bool = false, generatesKeyFile: Bool = false,
        progress: @escaping @Sendable (EngineProgress) -> Void, message: String,
        arguments: (URL) -> [String]
    ) async throws -> ArchiveExtraction {
        try Task.checkCancellation()
        try ArchivePath.validateFilename(destination.lastPathComponent)
        guard !fm.fileExists(atPath: destination.path) else {
            throw ArchiveError.invalidInput("目标已存在，请使用其他名称。")
        }
        let keyDestination = RecoveryArchive.keyFileURL(for: destination)
        var existingKey = stat()
        if generatesKeyFile && lstat(keyDestination.path, &existingKey) == 0 {
            throw ArchiveError.invalidInput("同名密钥文件已存在，请修改归档名称或保存位置。")
        }
        // The outer stage also covers cancellation after rz has published its inner output.
        let stage = destination.deletingLastPathComponent().appendingPathComponent(
            ".7zip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { discardStage(stage) }
        guard let emptyACL = acl_init(0) else { throw ArchiveError.invalidInput("无法创建私有临时目录。") }
        let secured = acl_set_link_np(stage.path, ACL_TYPE_EXTENDED, emptyACL) == 0
        acl_free(UnsafeMutableRawPointer(emptyACL))
        guard secured else { throw ArchiveError.invalidInput("无法清除临时目录的继承权限，已停止操作。") }
        let output = stage.appendingPathComponent("result", isDirectory: true)
        progress(EngineProgress(message: message))
        let result = try await run(
            arguments(output), password: password, captureListing: reportsMetadata,
            readOperation: reportsMetadata ? .extract : nil, progress: progress)
        if !(reportsMetadata && result.status == 5) { try check(result) }
        var warnings: [String] = []
        var count = 0
        if reportsMetadata {
            struct Report: Decodable {
                let outputPublished: Bool
                let warningCount: Int
                let metadataWarnings: [String]
            }
            guard let report = try? JSONDecoder().decode(Report.self, from: Data(result.output.utf8)),
                report.outputPublished, report.warningCount >= 0, report.metadataWarnings.count <= 16,
                report.warningCount >= report.metadataWarnings.count,
                (result.status == 5) == (report.warningCount > 0)
            else { throw ArchiveError.malformedListing }
            count = report.warningCount
            warnings = report.metadataWarnings.map(localizeWarning)
        }
        try Task.checkCancellation()
        var keyLinked = false
        var published = false
        var originalKey = stat()
        defer {
            if keyLinked && !published {
                var current = stat()
                if lstat(keyDestination.path, &current) == 0,
                    current.st_ino == originalKey.st_ino, current.st_dev == originalKey.st_dev
                {
                    _ = unlink(keyDestination.path)
                }
            }
        }
        if generatesKeyFile {
            let keySource = RecoveryArchive.keyFileURL(for: output)
            guard lstat(keySource.path, &originalKey) == 0,
                originalKey.st_mode & S_IFMT == S_IFREG, originalKey.st_mode & 0o777 == 0o600,
                link(keySource.path, keyDestination.path) == 0
            else {
                throw ArchiveError.invalidInput("无法安全保存密钥文件，可能存在同名文件。归档未发布。")
            }
            keyLinked = true
            try syncDirectory(destination.deletingLastPathComponent())
        }
        try Task.checkCancellation()
        guard renameatx_np(AT_FDCWD, output.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw ArchiveError.invalidInput("无法发布输出，目标可能已存在。原文件未覆盖。")
        }
        published = true
        try syncDirectory(destination.deletingLastPathComponent())
        return ArchiveExtraction(
            url: URL(fileURLWithPath: destination.path, isDirectory: true), metadataWarningCount: count,
            metadataWarnings: warnings)
    }

    private func run(
        _ arguments: [String], password: String = "", captureListing: Bool = false,
        readOperation: ArchiveReadOperation? = nil,
        progress: @escaping @Sendable (EngineProgress) -> Void = { _ in }
    ) async throws -> ProcessResult {
        guard fm.isExecutableFile(atPath: runner.executable.path) else { throw ArchiveError.recoveryEngineMissing }
        guard password.utf8.count <= 1024,
            !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw ArchiveError.invalidInput("密码不能包含换行或控制字符，且不能超过 1024 字节。") }
        return try await runner.run(
            arguments: arguments, password: password, captureListing: captureListing, readOperation: readOperation,
            progress: progress)
    }

    private func check(_ result: ProcessResult) throws {
        guard result.status != 0 else { return }
        if result.status == 4 { throw ArchiveError.passwordRequired }
        if result.status == 6 { throw ArchiveError.keyFileRequired }
        if result.output.contains("Recovery key file already exists") {
            throw ArchiveError.invalidInput("同名密钥文件已存在，请修改归档名称。")
        }
        if result.output.contains("AES-256-GCM is unavailable") {
            throw ArchiveError.invalidInput("此设备不支持 AES-256-GCM 硬件加速，无法加密或解锁双层归档。仍可修复密文分卷。")
        }
        if result.output.contains("Unsupported encryption suite") {
            throw ArchiveError.invalidInput("此归档使用了当前版本不支持的加密方式，请升级应用。")
        }
        if result.output.contains("Archive authentication failed") {
            throw ArchiveError.invalidInput("加密认证未通过，归档可能已被修改或损坏。未输出解密内容。")
        }
        if result.output.contains("Unrecoverable stripe") { throw ArchiveError.recoveryUnrecoverable }
        if result.output.contains("run repair first") { throw ArchiveError.recoveryRepairable }
        if result.output.contains("Mixed archive IDs") {
            throw ArchiveError.invalidInput("目录中混入了其他归档的分卷，请将不同归档的分卷分开放置。")
        }
        if result.output.contains("Replicated index does not fit") {
            throw ArchiveError.invalidInput("归档索引无法放入所选大小的分卷，请增大每卷大小后重试。")
        }
        if result.output.contains("Only regular files/directories") {
            throw ArchiveError.invalidInput("可恢复归档只支持普通文件和文件夹，不能包含符号链接或其他特殊文件。")
        }
        if result.output.contains("No valid manifest remains") {
            throw ArchiveError.invalidInput("没有找到完好的归档索引。请补回其他分卷或索引文件后重试。")
        }
        if result.output.contains("Recovery payload too small:")
            || result.output.contains("Recovery payload too large:")
        {
            let pattern = #"(?:minimum|maximum)=(\d+) bytes"#
            if let range = result.output.range(of: pattern, options: .regularExpression) {
                let digits = result.output[range].filter(\.isNumber)
                if let bytes = Int64(digits) {
                    let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
                    let message =
                        result.output.contains("too small")
                        ? "恢复载荷不足以保护所有编码组，本次归档至少需要 \(size)。请增大恢复容量或改用按比例。"
                        : "恢复容量超过本次压缩数据的大小，最多可设置为 \(size)。请减小恢复容量或改用按比例。"
                    throw ArchiveError.invalidInput(message)
                }
            }
        }
        let readable = result.output.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }
        let detail = String(String.UnicodeScalarView(readable))
        throw ArchiveError.recoveryEngineFailed(result.status, String(detail.suffix(2200)))
    }

    private func passwordArguments(_ password: String) -> [String] { password.isEmpty ? [] : ["--password-stdin"] }
    private func credentialArguments(_ password: String, keyFile: URL?) throws -> [String] {
        if let keyFile {
            guard keyFile.isFileURL, password.isEmpty else { throw ArchiveError.invalidInput("请选择一种本地解锁方式。") }
            return ["--key-file", keyFile.path]
        }
        return password.isEmpty ? ["--auto-key-file"] : passwordArguments(password)
    }
    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveError.invalidInput("无法同步输出目录。") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw ArchiveError.invalidInput("无法同步输出目录。") }
    }

    private func localizeWarning(_ text: String) -> String {
        let replacements = [
            "Original owner was retained in the archive but not restored": "原所有者已保存在归档中，未恢复到文件",
            "Special permission bits were not restored": "特殊权限位未恢复",
            "Permissions could not be restored": "文件权限无法恢复",
            "Group could not be restored": "原用户组无法恢复",
            "Extended attribute could not be restored": "扩展属性无法恢复",
            "Privileged/system extended attribute was not restored": "受保护的系统扩展属性未恢复",
            "Creation time could not be restored": "创建时间无法恢复",
            "File times could not be restored": "文件时间无法恢复",
            "ACL could not be restored": "访问控制列表无法恢复",
            "ACL identity is unavailable on this machine": "ACL 中的账号或用户组在当前系统不可用",
            "Immutable/append-only flags were not restored": "锁定或仅追加标记未恢复",
        ]
        return replacements.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    /// Only the private, unpublished stage is reset. Published output is never touched.
    private func discardStage(_ stage: URL) {
        func reset(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { return }
            if let acl = acl_init(0) {
                _ = acl_set_link_np(url.path, ACL_TYPE_EXTENDED, acl)
                acl_free(UnsafeMutableRawPointer(acl))
            }
            _ = lchflags(url.path, 0)
            _ = fchmodat(AT_FDCWD, url.path, kind == S_IFDIR ? 0o700 : 0o600, AT_SYMLINK_NOFOLLOW)
        }
        reset(stage)
        if let enumerator = fm.enumerator(at: stage, includingPropertiesForKeys: nil, errorHandler: { _, _ in true }) {
            for case let url as URL in enumerator { reset(url) }
        }
        try? fm.removeItem(at: stage)
    }
}

import Foundation

public actor ArchiveService {
    private let runner: ProcessRunner
    private let recovery: RecoveryArchiveService
    private let rar: RARArchiveService
    private let fm = FileManager.default

    public init(executable: URL, recoveryExecutable: URL? = nil, rarExecutable: URL? = nil) {
        runner = ProcessRunner(executable: executable)
        recovery = RecoveryArchiveService(
            executable: recoveryExecutable ?? executable.deletingLastPathComponent().appendingPathComponent("rz"))
        rar = RARArchiveService(
            executable: rarExecutable ?? executable.deletingLastPathComponent().appendingPathComponent("rar"),
            listingExecutable: executable)
    }

    public func supportsRecoveryAES() async throws -> Bool { try await recovery.supportsAES() }

    public func list(_ url: URL, password: String = "", keyFile: URL? = nil) async throws -> ArchiveListing {
        if let directory = RecoveryArchive.directory(for: url) {
            return try await recovery.list(directory, password: password, keyFile: keyFile)
        }
        guard keyFile == nil else { throw ArchiveError.invalidInput("独立密钥文件仅适用于 RZ 归档。") }
        if RARArchive.isRAR(url) { return try await rar.list(url, password: password) }
        try validatePassword(password)
        let result = try await runner.run(
            arguments: ["l", "-slt", "-sccUTF-8", "-bd", "--", url.path],
            password: password, captureListing: true)
        try check(result)
        return try ListingParser.parse(result.output, url: url)
    }

    public func test(
        _ url: URL, password: String = "", keyFile: URL? = nil,
        progress: @escaping @Sendable (EngineProgress) -> Void = { _ in }
    ) async throws {
        if let directory = RecoveryArchive.directory(for: url) {
            try await recovery.test(directory, password: password, keyFile: keyFile, progress: progress)
            return
        }
        guard keyFile == nil else { throw ArchiveError.invalidInput("独立密钥文件仅适用于 RZ 归档。") }
        if RARArchive.isRAR(url) {
            try await rar.test(url, password: password, progress: progress)
            return
        }
        try validatePassword(password)
        progress(EngineProgress(message: "正在读取归档索引…"))
        let listing = try await list(url, password: password)
        let result = try await runner.run(
            arguments: ["t", "-sccUTF-8", "-bsp1", "-bse1", "-y", "--", url.path],
            password: password, readOperation: .verify,
            totals: ProcessingMetrics(totalBytes: listing.totalSize, totalFiles: Int64(listing.fileCount)),
            progress: progress)
        try check(result)
    }

    public func compress(
        _ sources: [URL], to destination: URL, options: CompressionOptions,
        progress: @escaping @Sendable (EngineProgress) -> Void = { _ in }
    ) async throws -> URL {
        try await compress(sources, to: destination, options: options, progress: progress) { source in
            try FileManager.default.trashItem(at: source, resultingItemURL: nil)
        }
    }

    // Injectable recycling keeps safety tests confined to their temporary fixtures.
    func compress(
        _ sources: [URL], to destination: URL, options: CompressionOptions,
        progress: @escaping @Sendable (EngineProgress) -> Void = { _ in },
        recycle: @Sendable (URL) throws -> Void
    ) async throws -> URL {
        let cleanup: ArchiveSourceCleanup?
        if options.deleteSourcesAfterVerification {
            try ArchiveSourceCleanup.validate(options)
            progress(EngineProgress(message: "正在记录原文件状态…"))
            cleanup = try ArchiveSourceCleanup(sources: sources)
        } else {
            cleanup = nil
        }
        let output = try await create(cleanup?.sources ?? sources, to: destination, options: options, progress: progress)
        if let cleanup {
            do {
                try Task.checkCancellation()
                progress(EngineProgress(fraction: 0, message: "正在校验压缩包，原文件暂时保留…"))
                try await test(
                    output, password: options.password,
                    keyFile: options.generateRecoveryKeyFile ? RecoveryArchive.keyFileURL(for: output) : nil,
                    progress: progress)
                try Task.checkCancellation()
                try cleanup.recycleUnchangedSources(using: recycle, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ArchiveError.invalidInput(
                    "压缩包已保存到“\(output.path)”，但未完成原文件清理：\(error.localizedDescription)")
            }
        }
        return output
    }

    private func create(
        _ sources: [URL], to destination: URL, options: CompressionOptions,
        progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> URL {
        if options.format == .rar {
            return try await rar.compress(sources, to: destination, options: options, progress: progress)
        }
        if options.format == .recovery {
            return try await recovery.compress(sources, to: destination, options: options, progress: progress)
        }
        guard !options.generateRecoveryKeyFile else { throw ArchiveError.invalidInput("独立密钥文件仅适用于 RZ 归档。") }
        try Task.checkCancellation()
        guard !sources.isEmpty else { throw ArchiveError.invalidInput("请先添加要压缩的文件。") }
        try validatePassword(options.password)
        guard (0...9).contains(options.level) else { throw ArchiveError.invalidInput("压缩等级必须在 0 到 9 之间。") }
        try ensureNewDestination(destination)
        let uniqueSources = Array(Set(sources.map(\.standardizedFileURL)))
        let sources = uniqueSources.filter { source in
            !uniqueSources.contains { $0 != source && source.path.hasPrefix($0.path + "/") }
        }.sorted { $0.path < $1.path }
        for source in sources {
            guard fm.fileExists(atPath: source.path) else {
                throw ArchiveError.invalidInput("文件不存在：\(source.lastPathComponent)")
            }
            let resolvedSource = source.resolvingSymlinksInPath().path
            if resolvedSource == "/" || destination.resolvingSymlinksInPath().path.hasPrefix(resolvedSource + "/") {
                throw ArchiveError.invalidInput("压缩包不能保存在待压缩文件夹内部。请选择其他位置。")
            }
        }
        let parent = commonParent(sources)
        let relative = sources.map { "./" + $0.path.dropFirst(parent.path == "/" ? 1 : parent.path.count + 1) }
        let stage = try stagingDirectory(nextTo: destination)
        defer { try? fm.removeItem(at: stage) }
        let archive = stage.appendingPathComponent("archive.\(options.format.rawValue)")
        // -spf preserves the relative source paths passed below. Never pass
        // absolute input names here: that would store absolute archive entries.
        var arguments = [
            "a", "-t\(options.format.rawValue)", "-sccUTF-8", "-bsp1", "-bse1", "-y", "-spd", "-snl", "-spf",
        ]
        if options.format != .tar { arguments.append("-mx=\(options.level)") }
        if options.format.supportsPassword && !options.password.isEmpty {
            arguments.append("-p")
            if options.format == .sevenZip && options.encryptNames { arguments.append("-mhe=on") }
            if options.format == .zip { arguments.append("-mem=AES256") }
        }
        arguments += ["--", archive.path] + relative
        progress(EngineProgress(message: "正在扫描待压缩文件…"))
        let result = try await runner.run(
            arguments: arguments, directory: parent,
            password: options.password, compressionOutput: archive, progress: progress)
        try check(result)
        try Task.checkCancellation()
        try fm.moveItem(at: archive, to: destination)
        return destination
    }

    public func extract(
        _ url: URL, to destination: URL, password: String = "", keyFile: URL? = nil,
        restoreAttributes: Bool = true,
        progress: @escaping @Sendable (EngineProgress) -> Void = { _ in }
    ) async throws -> ArchiveExtraction {
        if let directory = RecoveryArchive.directory(for: url) {
            return try await recovery.extract(
                directory, to: destination, password: password, keyFile: keyFile, restoreAttributes: restoreAttributes,
                progress: progress
            )
        }
        guard keyFile == nil else { throw ArchiveError.invalidInput("独立密钥文件仅适用于 RZ 归档。") }
        if RARArchive.isRAR(url) {
            return try await rar.extract(url, to: destination, password: password, progress: progress)
        }
        try ensureNewDestination(destination)
        progress(EngineProgress(message: "正在检查归档路径…"))
        let listing = try await list(url, password: password)
        for entry in listing.entries {
            try ArchivePath.validate(entry.path)
            if entry.isLink { throw ArchiveError.unsafeEntry(entry.path) }
        }
        try Task.checkCancellation()
        let stage = try stagingDirectory(nextTo: destination)
        defer { try? fm.removeItem(at: stage) }
        let payload = stage.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: false)
        let result = try await runner.run(
            arguments: ["x", "-o\(payload.path)", "-aou", "-y", "-sccUTF-8", "-bsp1", "-bse1", "--", url.path],
            password: password, readOperation: .extract,
            totals: ProcessingMetrics(totalBytes: listing.totalSize, totalFiles: Int64(listing.fileCount)),
            progress: progress)
        try check(result)
        try Task.checkCancellation()
        progress(EngineProgress(message: "正在检查解压结果并保存…"))
        try validateExtractedTree(payload)
        try fm.moveItem(at: payload, to: destination)
        return ArchiveExtraction(url: destination)
    }

    public func repair(
        _ url: URL, to destination: URL,
        progress: @escaping @Sendable (EngineProgress) -> Void = { _ in }
    ) async throws -> URL {
        guard let directory = RecoveryArchive.directory(for: url) else {
            throw ArchiveError.invalidInput("只有可恢复 RZ 归档支持此修复操作。")
        }
        return try await recovery.repair(directory, to: destination, progress: progress)
    }

    public func performRARTool(
        _ request: RARToolRequest, archive: URL, to destination: URL,
        progress: @escaping @Sendable (EngineProgress) -> Void = { _ in }
    ) async throws -> URL {
        try await rar.perform(request, archive: archive, to: destination, progress: progress)
    }

    private func validateExtractedTree(_ root: URL) throws {
        guard
            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                errorHandler: { _, _ in false })
        else {
            throw ArchiveError.invalidInput("无法检查解压结果。")
        }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw ArchiveError.unsafeEntry(url.lastPathComponent) }
        }
    }

    private func ensureNewDestination(_ url: URL) throws {
        try ArchivePath.validateFilename(url.lastPathComponent)
        guard !fm.fileExists(atPath: url.path) else {
            throw ArchiveError.invalidInput("目标已存在，请使用其他名称：\(url.lastPathComponent)")
        }
    }

    private func stagingDirectory(nextTo destination: URL) throws -> URL {
        let url = destination.deletingLastPathComponent()
            .appendingPathComponent(".7zip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(
            at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private func commonParent(_ urls: [URL]) -> URL {
        var parent = urls[0].deletingLastPathComponent()
        while !urls.allSatisfy({ parent.path == "/" || $0.path.hasPrefix(parent.path + "/") }) {
            parent.deleteLastPathComponent()
        }
        return parent
    }

    private func validatePassword(_ password: String) throws {
        guard password.utf8.count <= 1024,
            !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ArchiveError.invalidInput("密码不能包含换行或控制字符，且不能超过 1024 字节。")
        }
    }

    private func check(_ result: ProcessResult) throws {
        guard result.status != 0 else { return }
        let text = result.output.lowercased()
        if text.contains("wrong password") || text.contains("enter password") || text.contains("password is incorrect")
        {
            throw ArchiveError.passwordRequired
        }
        let readable = result.output.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }
        let detail = String(String.UnicodeScalarView(readable))
        throw ArchiveError.engineFailed(result.status, String(detail.suffix(2200)))
    }
}

import Foundation

public enum RARArchive {
    public static func isRAR(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "rar" || ext == "rev" || ext.range(of: #"^r\d{2}$"#, options: .regularExpression) != nil
    }

    public static func volumeDirectory(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            destination.deletingPathExtension().lastPathComponent + ".rar-parts", isDirectory: true)
    }

    /// A volume family is matched by its exact base, never by a loose prefix.
    static func family(_ url: URL) throws -> [URL] {
        if !isRAR(url) { return [url] }  // A user-selected SFX can have no extension.
        let name = url.lastPathComponent
        let base: String
        let pattern: String
        if let range = name.range(of: #"\.part\d+\.(rar|rev)$"#, options: [.regularExpression, .caseInsensitive]) {
            base = String(name[..<range.lowerBound])
            pattern = "^" + NSRegularExpression.escapedPattern(for: base) + #"\.part\d+\.(rar|rev)$"#
        } else {
            base = url.deletingPathExtension().lastPathComponent
            let suffix =
                url.pathExtension.lowercased() == "rar" && !FileManager.default.fileExists(atPath: url.path)
                ? #"\.part\d+\.(rar|rev)$"# : #"\.(rar|r\d{2}|rev|\d+\.rev)$"#
            pattern = "^" + NSRegularExpression.escapedPattern(for: base) + suffix
        }
        return try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).filter {
            $0.lastPathComponent.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func firstVolume(_ url: URL) throws -> URL {
        if !isRAR(url) { return url }
        let members = try family(url)
        if let first = members.first(where: {
            $0.lastPathComponent.range(of: #"\.part0*1\.rar$"#, options: [.regularExpression, .caseInsensitive]) != nil
        }) {
            return first
        }
        if let first = members.first(where: {
            $0.pathExtension.lowercased() == "rar"
                && $0.lastPathComponent.range(of: #"\.part\d+\.rar$"#, options: [.regularExpression, .caseInsensitive])
                    == nil
        }) {
            return first
        }
        throw ArchiveError.invalidInput("找不到 RAR 首卷。请将同组分卷放在一起，或在“RAR 工具”中使用 REV 重建分卷。")
    }

    static func isMultipart(_ url: URL) throws -> Bool {
        try family(url).contains {
            $0.lastPathComponent.range(
                of: #"\.part\d+\.rar$|\.r\d{2}$"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

actor RARArchiveService {
    private let runner: ProcessRunner
    private let listingRunner: ProcessRunner
    private let executable: URL
    private let fm = FileManager.default
    private let common = ["-cfg-", "-y", "-c-", "-idcd", "-@", "-scf"]

    init(executable: URL, listingExecutable: URL) {
        self.executable = executable
        runner = ProcessRunner(executable: executable)
        listingRunner = ProcessRunner(executable: listingExecutable)
    }

    func list(_ url: URL, password: String) async throws -> ArchiveListing {
        try validateArchivePath(url)
        try RAROptions.validatePassword(password)
        let first = try RARArchive.firstVolume(url)
        let result = try await listingRunner.run(
            arguments: ["l", "-slt", "-sccUTF-8", "-bd", "--", first.path], password: password, captureListing: true)
        if result.status != 0 {
            let text = result.output.lowercased()
            if text.contains("password") { throw ArchiveError.passwordRequired }
            throw ArchiveError.rarFailed(result.status, String(result.output.suffix(2000)))
        }
        return try ListingParser.parse(result.output, url: first)
    }

    func test(_ url: URL, password: String, progress: @escaping @Sendable (EngineProgress) -> Void) async throws {
        let listing = try await list(url, password: password)
        if listing.isEncrypted && password.isEmpty { throw ArchiveError.passwordRequired }
        let stage = try stageDirectory(nextTo: fm.temporaryDirectory.appendingPathComponent("rar-read"))
        defer { try? fm.removeItem(at: stage) }
        let readArchive = try readOnlyFamily(listing.url, in: stage)
        _ = try await run(
            "t", archive: readArchive, password: password, readOperation: .verify,
            totals: ProcessingMetrics(totalBytes: listing.totalSize, totalFiles: Int64(listing.fileCount)),
            progress: progress)
    }

    func compress(
        _ sources: [URL], to destination: URL, options: CompressionOptions,
        progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> URL {
        try options.rar.validate(password: options.password)
        guard !options.generateRecoveryKeyFile else { throw ArchiveError.invalidInput("RAR 不支持 RZ 密钥文件。") }
        try ensureNew(destination)
        let split = options.rar.volumeSizeBytes != nil
        let final = split ? RARArchive.volumeDirectory(for: destination) : destination
        try ensureNew(final)
        let input = try prepareSources(sources, destination: final)
        let stage = try stageDirectory(nextTo: final)
        defer { try? fm.removeItem(at: stage) }
        let payload = stage.appendingPathComponent("result", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: false)
        let archive = payload.appendingPathComponent(destination.lastPathComponent)
        var args = options.rar.compressionArguments()
        if !options.password.isEmpty && options.encryptNames { args.append("-hp") }
        if let comment = try commentFile(options.rar.comment, in: stage) { args.append("-z\(comment.path)") }
        progress(EngineProgress(message: "正在扫描待压缩文件…"))
        let initialMetrics = try inputMetrics(input.relative.map { input.parent.appendingPathComponent($0) })
        let started = ProcessInfo.processInfo.systemUptime
        progress(EngineProgress(fraction: 0, message: "正在压缩 RAR 文件…", compression: initialMetrics))
        _ = try await run(
            "a", archive: archive, arguments: args, files: input.relative, directory: input.parent,
            password: options.password,
            progress: { update in
                guard let fraction = update.fraction else { return }
                var metrics = initialMetrics
                metrics.processedBytes = Int64(Double(metrics.totalBytes) * fraction)
                metrics.completedFiles = Int64(Double(metrics.totalFiles) * fraction)
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                if elapsed > 0 { metrics.bytesPerSecond = Double(metrics.processedBytes) / elapsed }
                progress(
                    EngineProgress(fraction: min(0.99, fraction), message: "正在压缩 RAR / 写入恢复记录…", compression: metrics))
            })
        let first = try RARArchive.firstVolume(archive)
        if options.rar.recoveryVolumeAmount > 0 {
            progress(EngineProgress(message: "正在生成 REV 恢复卷…"))
            try await createRecoveryVolumes(first, options: options.rar, password: options.password, progress: progress)
        }
        let listing = try await list(first, password: options.password)
        if options.rar.testAfterCreation {
            progress(EngineProgress(fraction: 0, message: "正在校验新建 RAR…"))
            _ = try await run(
                "t", archive: first, password: options.password, readOperation: .verify,
                totals: ProcessingMetrics(totalBytes: listing.totalSize, totalFiles: Int64(listing.fileCount)),
                progress: progress)
        }
        var completed = CompressionMetrics()
        completed.totalBytes = listing.totalSize
        completed.processedBytes = listing.totalSize
        completed.totalFiles = Int64(listing.fileCount)
        completed.completedFiles = completed.totalFiles
        completed.compressedBytes = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(Int64(0)) { total, file in
                total + Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if elapsed > 0 { completed.bytesPerSecond = Double(completed.processedBytes) / elapsed }
        try Task.checkCancellation()
        if split {
            try fm.moveItem(at: payload, to: final)
            progress(EngineProgress(fraction: 1, message: "RAR 分卷与恢复文件已保存", compression: completed))
            return final.appendingPathComponent(first.lastPathComponent)
        }
        try fm.moveItem(at: first, to: destination)
        progress(EngineProgress(fraction: 1, message: "RAR 压缩完成", compression: completed))
        return destination
    }

    func extract(
        _ url: URL, to destination: URL, password: String, flatten: Bool = false,
        progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> ArchiveExtraction {
        try ensureNew(destination)
        let listing = try await list(url, password: password)
        if listing.isEncrypted && password.isEmpty { throw ArchiveError.passwordRequired }
        for entry in listing.entries {
            try ArchivePath.validate(entry.path)
            if entry.isLink { throw ArchiveError.unsafeEntry(entry.path) }
        }
        let stage = try stageDirectory(nextTo: destination)
        defer { try? fm.removeItem(at: stage) }
        let payload = stage.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: false)
        let readArchive = try readOnlyFamily(listing.url, in: stage)
        _ = try await run(
            flatten ? "e" : "x", archive: readArchive, arguments: ["-or", "-ol-"],
            files: [payload.path + "/"], password: password, readOperation: .extract,
            totals: ProcessingMetrics(totalBytes: listing.totalSize, totalFiles: Int64(listing.fileCount)),
            progress: progress)
        try validateTree(payload)
        try Task.checkCancellation()
        try fm.moveItem(at: payload, to: destination)
        return ArchiveExtraction(url: destination)
    }

    func perform(
        _ request: RARToolRequest, archive url: URL, to destination: URL,
        progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> URL {
        try RAROptions.validatePassword(request.password)
        try ensureNew(destination)
        if request.operation == .extractFlat {
            return try await extract(
                url, to: destination, password: request.password, flatten: true, progress: progress
            ).url
        }
        let multipart = try RARArchive.isMultipart(url)
        guard !multipart || request.operation.permitsVolumes else {
            throw ArchiveError.invalidInput("RAR 分卷不支持此修改。请重新创建归档，或选择单个 RAR 文件。")
        }
        let stage = try stageDirectory(nextTo: destination)
        defer { try? fm.removeItem(at: stage) }
        let work = stage.appendingPathComponent("work", isDirectory: true)
        let output = stage.appendingPathComponent("output", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        let members = try RARArchive.family(url)
        guard !members.isEmpty else { throw ArchiveError.invalidInput("找不到 RAR 文件或分卷。") }
        for member in members {
            try Task.checkCancellation()
            let values = try member.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ArchiveError.unsafeEntry(member.lastPathComponent)
            }
            try fm.copyItem(at: member, to: work.appendingPathComponent(member.lastPathComponent))
        }
        let copied = work.appendingPathComponent(url.lastPathComponent)
        let archive =
            request.operation == .reconstruct || request.operation == .repair
            ? copied : try RARArchive.firstVolume(copied)
        var publish = work
        let password = request.password
        progress(EngineProgress(message: request.operation.title))
        switch request.operation {
        case .repair:
            let inputs =
                multipart ? try RARArchive.family(archive).filter { $0.pathExtension.lowercased() != "rev" } : [archive]
            for input in inputs {
                _ = try await run(
                    "r", archive: input, files: [output.path + "/"], directory: work, password: password,
                    progress: progress)
                let repaired = try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix("fixed.") || $0.lastPathComponent.hasPrefix("rebuilt.") }
                guard repaired.count <= 1 else { throw ArchiveError.invalidInput("RAR 生成了无法确定的修复结果。") }
                // RAR removes its provisional fixed.* file when the volume is already intact.
                guard let file = repaired.first else {
                    if !multipart {
                        _ = try await run("t", archive: input, password: password, progress: progress)
                        try fm.copyItem(at: input, to: output.appendingPathComponent(input.lastPathComponent))
                    }
                    continue
                }
                if multipart {
                    try fm.removeItem(at: input)
                    try fm.moveItem(at: file, to: input)
                } else {
                    _ = try await run("t", archive: file, password: password, progress: progress)
                }
            }
            if multipart {
                // Repair can rewrite volume headers. Old REV checksums no longer apply.
                for file in try RARArchive.family(archive) where file.pathExtension.lowercased() == "rev" {
                    try fm.removeItem(at: file)
                }
                _ = try await run("t", archive: RARArchive.firstVolume(archive), password: password, progress: progress)
            } else {
                publish = output
            }
        case .reconstruct:
            _ = try await run("rc", archive: archive, directory: work, password: password, progress: progress)
            let first = try RARArchive.firstVolume(archive)
            _ = try await run("t", archive: first, password: password, progress: progress)
        case .recoveryRecord:
            guard (1...100).contains(request.options.recoveryRecordPercent) else {
                throw ArchiveError.invalidInput("恢复记录比例必须在 1–100% 之间。")
            }
            _ = try await run(
                "rr\(request.options.recoveryRecordPercent)p", archive: archive, password: password, progress: progress)
        case .recoveryVolumes:
            try await createRecoveryVolumes(archive, options: request.options, password: password, progress: progress)
        case .comment:
            guard let comment = try commentFile(request.options.comment, in: stage, allowEmpty: true) else {
                throw ArchiveError.invalidInput("无法创建注释。")
            }
            _ = try await run(
                "c", archive: archive, arguments: ["-z\(comment.path)"], password: password, progress: progress)
        case .exportComment:
            _ = try await run(
                "cw", archive: archive, files: [output.appendingPathComponent("comment.txt").path], password: password,
                progress: progress)
            publish = output
        case .lock:
            _ = try await run("k", archive: archive, password: password, progress: progress)
        case .add, .update, .freshen:
            try request.options.validate(password: password)
            guard request.options.volumeSizeBytes == nil, request.options.recoveryVolumeAmount == 0 else {
                throw ArchiveError.invalidInput("更新已有归档不能更改分卷设置。")
            }
            let input = try prepareSources(request.sources, destination: destination)
            let command = request.operation == .add ? "a" : request.operation == .update ? "u" : "f"
            _ = try await run(
                command, archive: archive, arguments: request.options.compressionArguments(),
                files: input.relative, directory: input.parent, password: password, progress: progress)
            _ = try await run("t", archive: archive, password: password, progress: progress)
        case .delete, .rename:
            let names = RAROptions.masks(request.entryNames)
            guard !names.isEmpty else { throw ArchiveError.invalidInput("请输入归档内路径。") }
            for name in names { try ArchivePath.validate(name) }
            var files = names
            if request.operation == .rename {
                guard names.count == 1 else { throw ArchiveError.invalidInput("一次只能重命名一个条目。") }
                try ArchivePath.validate(request.renamedPath)
                let listing = try await list(archive, password: password)
                guard listing.entries.contains(where: { $0.path == names[0] }),
                    !listing.entries.contains(where: { $0.path == request.renamedPath }),
                    ![names[0], request.renamedPath].contains(where: { $0.contains("*") || $0.contains("?") })
                else { throw ArchiveError.invalidInput("原条目不存在、新名称已存在，或路径包含通配符。") }
                files.append(request.renamedPath)
            }
            _ = try await run(
                request.operation == .delete ? "d" : "rn", archive: archive,
                files: files, password: password, progress: progress)
        case .list, .technicalList:
            let result = try await run(
                request.operation == .list ? "lb" : "lta", archive: archive,
                arguments: ["-v"], password: password, capture: true, progress: progress)
            try Data(result.output.utf8).write(to: output.appendingPathComponent("RAR-清单.txt"))
            publish = output
        case .convertSFX:
            let module = executable.deletingLastPathComponent().appendingPathComponent("default.sfx")
            guard fm.fileExists(atPath: module.path) else { throw ArchiveError.invalidInput("找不到 default.sfx 模块。") }
            _ = try await run("s\(module.path)", archive: archive, password: password, progress: progress)
        case .removeSFX:
            _ = try await run("s-", archive: archive, password: password, progress: progress)
        case .extractFlat: break
        }
        try validateTree(publish)
        try Task.checkCancellation()
        try fm.moveItem(at: publish, to: destination)
        return destination
    }

    private func createRecoveryVolumes(
        _ archive: URL, options: RAROptions, password: String,
        progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws {
        let count = try RARArchive.family(archive).filter { $0.pathExtension.lowercased() == "rar" }.count
        guard count > 1, options.recoveryVolumeAmount > 0,
            options.recoveryVolumeMode == .count
                ? options.recoveryVolumeAmount < count : options.recoveryVolumeAmount <= 100
        else { throw ArchiveError.invalidInput("REV 需要至少两个数据卷；恢复卷数量须小于数据卷数，或使用 1–100% 比例。") }
        _ = try await run(options.recoveryVolumeCommand, archive: archive, password: password, progress: progress)
    }

    private func run(
        _ command: String, archive: URL, arguments: [String] = [], files: [String] = [], directory: URL? = nil,
        password: String = "", capture: Bool = false, readOperation: ArchiveReadOperation? = nil,
        totals: ProcessingMetrics? = nil, progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        try validateArchivePath(archive)
        guard fm.isExecutableFile(atPath: executable.path) else { throw ArchiveError.rarEngineMissing }
        try RAROptions.validatePassword(password)
        // RAR 7 treats the former -p- switch as a literal password "-".
        // With no password, omit encryption switches and close stdin instead.
        let authentication = arguments.contains("-hp") || password.isEmpty ? [] : ["-p"]
        let result = try await runner.run(
            arguments: [command] + common + arguments + authentication + ["--", archive.path] + files,
            directory: directory, password: password, captureListing: capture,
            readOperation: readOperation, totals: totals, progress: progress)
        guard result.status == 0 else {
            if result.status == 11 || result.output.lowercased().contains("password") {
                throw ArchiveError.passwordRequired
            }
            let scalars = result.output.unicodeScalars.filter {
                $0 == "\n" || !CharacterSet.controlCharacters.contains($0)
            }
            throw ArchiveError.rarFailed(
                result.status, String(String.UnicodeScalarView(scalars)).suffix(2200).description)
        }
        return result
    }

    private func validateArchivePath(_ url: URL) throws {
        guard !url.path.contains("*"), !url.path.contains("?"),
            !url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw ArchiveError.invalidInput("RAR 归档路径不能包含 *、? 或控制字符。请先重命名文件或所在文件夹。") }
    }

    /// RAR can automatically reconstruct volumes during x/t if REV files are nearby.
    /// Present only data volumes through a private directory, without copying archive
    /// bytes or allowing a read operation to rebuild files beside the user's originals.
    private func readOnlyFamily(_ archive: URL, in stage: URL) throws -> URL {
        let directory = stage.appendingPathComponent("input", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        for file in try RARArchive.family(archive) where file.pathExtension.lowercased() != "rev" {
            try fm.createSymbolicLink(
                at: directory.appendingPathComponent(file.lastPathComponent), withDestinationURL: file)
        }
        return directory.appendingPathComponent(archive.lastPathComponent)
    }

    private func commentFile(_ text: String, in stage: URL, allowEmpty: Bool = false) throws -> URL? {
        if text.isEmpty && !allowEmpty { return nil }
        guard text.utf8.count <= 256 * 1024, !text.contains("\0") else {
            throw ArchiveError.invalidInput("注释不能超过 256 KiB 或包含 NUL 字符。")
        }
        let url = stage.appendingPathComponent("comment.txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func ensureNew(_ url: URL) throws {
        try ArchivePath.validateFilename(url.lastPathComponent)
        guard !url.path.contains("*"), !url.path.contains("?"), !fm.fileExists(atPath: url.path) else {
            throw ArchiveError.invalidInput("输出已存在或路径包含 RAR 通配符（*、?），请选择其他位置。")
        }
    }

    private func stageDirectory(nextTo url: URL) throws -> URL {
        let stage = url.deletingLastPathComponent().appendingPathComponent(
            ".7zip-rar-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return stage
    }

    private func prepareSources(_ sources: [URL], destination: URL) throws -> (parent: URL, relative: [String]) {
        let unique = Array(Set(sources.map(\.standardizedFileURL)))
        let sources = unique.filter { source in
            !unique.contains { $0 != source && source.path.hasPrefix($0.path + "/") }
        }
        .sorted { $0.path < $1.path }
        guard !sources.isEmpty else { throw ArchiveError.invalidInput("请先添加要压缩的文件。") }
        for source in sources {
            try Task.checkCancellation()
            let path = source.resolvingSymlinksInPath().path
            guard fm.fileExists(atPath: source.path), path != "/",
                !destination.resolvingSymlinksInPath().path.hasPrefix(path + "/"),
                !source.path.contains("*"), !source.path.contains("?"),
                !source.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw ArchiveError.invalidInput("来源不存在、包含 RAR 通配符/控制字符，或输出位于来源内部。通配符文件名可通过选择其父文件夹打包。") }
        }
        var parent = sources[0].deletingLastPathComponent()
        while !sources.allSatisfy({ parent.path == "/" || $0.path.hasPrefix(parent.path + "/") }) {
            parent.deleteLastPathComponent()
        }
        return (parent, sources.map { "./" + $0.path.dropFirst(parent.path == "/" ? 1 : parent.path.count + 1) })
    }

    private func inputMetrics(_ sources: [URL]) throws -> CompressionMetrics {
        var metrics = CompressionMetrics()
        metrics.isEstimated = true  // User filters and skipped links may reduce the final totals.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        func add(_ url: URL) throws {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            if values.isDirectory != true && values.isSymbolicLink != true {
                let (bytes, overflow) = metrics.totalBytes.addingReportingOverflow(Int64(values.fileSize ?? 0))
                guard !overflow else { throw ArchiveError.invalidInput("来源总大小超出支持范围。") }
                metrics.totalBytes = bytes
                metrics.totalFiles += 1
            }
        }
        for source in sources {
            try add(source)
            if try source.resourceValues(forKeys: keys).isDirectory == true,
                let iterator = fm.enumerator(at: source, includingPropertiesForKeys: Array(keys))
            {
                for case let item as URL in iterator { try add(item) }
            }
        }
        return metrics
    }

    private func validateTree(_ root: URL) throws {
        var failed = false
        guard
            let iterator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                errorHandler: { _, _ in
                    failed = true
                    return false
                })
        else { throw ArchiveError.invalidInput("无法检查 RAR 输出。") }
        for case let item as URL in iterator {
            try Task.checkCancellation()
            if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw ArchiveError.unsafeEntry(item.lastPathComponent)
            }
        }
        if failed { throw ArchiveError.invalidInput("无法完整检查 RAR 输出。") }
    }
}

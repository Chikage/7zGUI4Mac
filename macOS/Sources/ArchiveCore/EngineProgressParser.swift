import Foundation

/// Consumes the console stream, including 7-Zip's backspace-delimited updates
/// and the optional, versioned RZ statistics protocol. Owned by the I/O worker.
struct EngineProgressParser {
    private var buffer = Data()
    private var metrics: CompressionMetrics?
    private var processing: ProcessingMetrics?
    private let readOperation: ArchiveReadOperation?
    private var recoveryRead = false
    private var reportsFiles = false
    private var fraction: Double?
    private var message = "正在处理文件…"
    private var startedAt: TimeInterval?
    private var lastProgress: EngineProgress?
    private let compressionOutput: URL?

    init(
        compressionOutput: URL? = nil, readOperation: ArchiveReadOperation? = nil,
        totals: ProcessingMetrics? = nil
    ) {
        self.compressionOutput = compressionOutput
        self.readOperation = readOperation
        processing = totals
        if let readOperation { message = readOperation.message }
    }

    mutating func start(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> EngineProgress? {
        guard processing != nil else { return nil }
        startedAt = now
        processing?.isEstimated = true
        fraction = 0
        return snapshot(now: now)
    }

    mutating func consume(_ data: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [EngineProgress] {
        buffer.append(data)
        var updates: [EngineProgress] = []
        while let index = buffer.firstIndex(where: { $0 == 10 || $0 == 13 || $0 == 8 }) {
            let line = String(decoding: buffer[..<index], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(...index)
            if let update = parse(line, now: now) { updates.append(update) }
        }
        // Console percentages are flushed without a newline. Read the current
        // tail as well, so a slow single file does not wait for the next update.
        let tail = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if tail.range(of: #"^\d{1,3}%($|\s)"#, options: .regularExpression) != nil,
            let update = parse(tail, now: now)
        {
            updates.append(update)
        }
        if buffer.count > 8192 { buffer.removeFirst(buffer.count - 8192) }
        return updates
    }

    mutating func finish(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> EngineProgress? {
        if var value = processing, !recoveryRead {
            value.processedBytes = value.totalBytes
            value.completedFiles = value.totalFiles ?? value.completedFiles
            value.isEstimated = false
            processing = value
            fraction = 1
            message = readOperation?.completionMessage ?? "处理完成"
            return snapshot(now: now)
        }
        guard var value = metrics else { return nil }
        value.processedBytes = value.totalBytes
        value.completedFiles = value.totalFiles
        value.isEstimated = false
        metrics = value
        fraction = 1
        message = "压缩完成，正在保存…"
        return snapshot(now: now)
    }

    private mutating func parse(_ line: String, now: TimeInterval) -> EngineProgress? {
        if line.hasPrefix("RZREADPROGRESS1\t") { return parseReadProgress(line, now: now) }
        if line.hasPrefix("RZPROGRESS1\t") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 8 else { return nil }
            let values = parts.dropFirst(2).compactMap { Int64($0) }
            guard values.count == 6, values.allSatisfy({ $0 >= 0 }),
                values[0] <= values[1], values[2] <= values[3]
            else { return nil }
            var value = CompressionMetrics()
            value.processedBytes = values[0]
            value.totalBytes = values[1]
            value.completedFiles = values[2]
            value.totalFiles = values[3]
            value.compressedBytes = values[4]
            value.excludesRecovery = true
            // RZ reports the compression time separately, excluding parity and verification.
            if values[5] > 0 { value.bytesPerSecond = Double(values[0]) * 1000 / Double(values[5]) }
            switch parts[1] {
            case "compressing":
                fraction = value.totalBytes > 0 ? Double(value.processedBytes) / Double(value.totalBytes) : 0
                message = "正在压缩文件…"
            case "recovery":
                fraction = nil
                message = "文件压缩完成，正在生成恢复卷…"
            case "writing":
                fraction = nil
                message = "正在写入数据卷和恢复卷…"
            case "verifying":
                fraction = 0
                message = "正在校验压缩结果…"
            case "completed":
                fraction = 1
                message = "压缩完成，正在保存…"
            default: return nil
            }
            processing = nil
            metrics = value
            return snapshot(now: now)
        }
        if compressionOutput != nil, line.hasPrefix("Add new data to archive:") {
            var value = CompressionMetrics()
            value.totalBytes = number(in: line, pattern: #"(\d+) bytes"#) ?? 0
            value.totalFiles = number(in: line, pattern: #"(\d+) files?\b"#) ?? 0
            value.isEstimated = true
            metrics = value
            startedAt = now
            message = "正在压缩文件…"
            fraction = 0
            return snapshot(now: now)
        }
        guard let match = line.range(of: #"^\d{1,3}%(?=$|\s)"#, options: .regularExpression),
            let percentage = Double(line[match].dropLast()), percentage <= 100
        else { return nil }
        fraction = percentage / 100
        if var value = processing {
            // Percentage is supplied by 7-Zip; byte counts and speed are estimates.
            value.processedBytes =
                percentage == 100 ? value.totalBytes : Int64(Double(value.totalBytes) * percentage / 100)
            if let files = number(in: line, pattern: #"^\d+%\s+(\d+)(?=$|\s)"#), let total = value.totalFiles {
                value.completedFiles = min(total, max(value.completedFiles, files))
            }
            processing = value
            fraction = min(0.99, percentage / 100)
        }
        if var value = metrics {
            value.processedBytes = Int64(Double(value.totalBytes) * (fraction ?? 0))
            let files = number(in: line, pattern: #"^\d+%\s+(\d+)(?=$|\s)"#) ?? 0
            value.completedFiles = min(value.totalFiles, max(value.completedFiles, files))
            metrics = value
        }
        return snapshot(now: now)
    }

    private mutating func parseReadProgress(_ line: String, now: TimeInterval) -> EngineProgress? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 7 else { return nil }
        let values = parts.dropFirst(2).compactMap { Int64($0) }
        guard values.count == 5, values.allSatisfy({ $0 >= 0 }),
            values[0] <= values[1], values[2] <= values[3]
        else { return nil }
        let phase = parts[1]
        switch phase {
        case "preparing": message = "正在读取归档索引…"
        case "storage": message = "正在校验数据卷、恢复卷和索引…"
        case "extracting": message = "正在解压并校验文件…"
        case "checking": message = "正在校验文件内容和属性…"
        case "attributes": message = "文件解压完成，正在恢复属性…"
        case "publishing": message = "正在保存解压结果…"
        case "completed": message = readOperation?.completionMessage ?? "处理完成"
        default: return nil
        }
        recoveryRead = true
        if phase == "storage" { reportsFiles = false }
        if phase == "extracting" || phase == "checking" { reportsFiles = true }
        var value = ProcessingMetrics(totalBytes: values[1], totalFiles: reportsFiles ? values[3] : nil)
        value.processedBytes = values[0]
        value.completedFiles = values[2]
        if values[4] > 0 { value.bytesPerSecond = Double(values[0]) * 1000 / Double(values[4]) }
        processing = phase == "preparing" ? nil : value
        switch phase {
        case "completed": fraction = 1
        case "storage", "extracting", "checking":
            // Reserve completion for the result: hashes, attributes and publishing can still fail.
            fraction = value.totalBytes > 0 ? min(0.99, Double(value.processedBytes) / Double(value.totalBytes)) : 0
        default: fraction = nil
        }
        return snapshot(now: now)
    }

    private mutating func snapshot(now: TimeInterval) -> EngineProgress? {
        if var value = metrics, let output = compressionOutput {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
                let size = attributes[.size] as? NSNumber, size.int64Value > 0
            {
                value.compressedBytes = size.int64Value
            }
            if let startedAt, now - startedAt > 0, value.processedBytes > 0 {
                value.bytesPerSecond = Double(value.processedBytes) / (now - startedAt)
            }
            metrics = value
        }
        if var value = processing, !recoveryRead, let startedAt, now > startedAt, value.processedBytes > 0 {
            value.bytesPerSecond = Double(value.processedBytes) / (now - startedAt)
            processing = value
        }
        let update = EngineProgress(fraction: fraction, message: message, compression: metrics, processing: processing)
        guard
            lastProgress?.fraction != update.fraction || lastProgress?.message != update.message
                || lastProgress?.compression != update.compression || lastProgress?.processing != update.processing
        else { return nil }
        lastProgress = update
        return update
    }

    private func number(in text: String, pattern: String) -> Int64? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int64(text[range])
    }
}

import Foundation

/// Consumes the console stream, including 7-Zip's backspace-delimited updates
/// and the optional, versioned RZ statistics protocol. Owned by the I/O worker.
struct EngineProgressParser {
    private var buffer = Data()
    private var metrics: CompressionMetrics?
    private var fraction: Double?
    private var message = "正在处理文件…"
    private var startedAt: TimeInterval?
    private var lastProgress: EngineProgress?
    private let compressionOutput: URL?

    init(compressionOutput: URL? = nil) { self.compressionOutput = compressionOutput }

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
                fraction = nil
                message = "正在校验压缩结果…"
            case "completed":
                fraction = 1
                message = "压缩完成，正在保存…"
            default: return nil
            }
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
        if var value = metrics {
            value.processedBytes = Int64(Double(value.totalBytes) * (fraction ?? 0))
            let files = number(in: line, pattern: #"^\d+%\s+(\d+)(?=$|\s)"#) ?? 0
            value.completedFiles = min(value.totalFiles, max(value.completedFiles, files))
            metrics = value
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
        let update = EngineProgress(fraction: fraction, message: message, compression: metrics)
        guard
            lastProgress?.fraction != update.fraction || lastProgress?.message != update.message
                || lastProgress?.compression != update.compression
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

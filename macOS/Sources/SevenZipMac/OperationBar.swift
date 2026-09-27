import ArchiveCore
import SwiftUI

struct OperationBar: View {
    let operation: OperationState
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(operation.title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let fraction = operation.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .accessibilityLabel("\(operation.title)进度")
                        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
                }
                Button(operation.cancelling ? "正在取消…" : "取消", action: cancel)
                    .controlSize(.small).disabled(operation.cancelling)
            }
            Group {
                if let fraction = operation.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .accessibilityLabel(operation.title)
            if operation.showsCompression {
                CompressionStatistics(metrics: operation.compression)
            }
            HStack(spacing: 12) {
                Text(operation.detail).lineLimit(1).truncationMode(.middle).help(operation.detail)
                Spacer(minLength: 0)
                TimelineView(.periodic(from: operation.startedAt, by: 1)) { context in
                    Text(
                        "用时 \(Duration.seconds(max(0, context.date.timeIntervalSince(operation.startedAt))).formatted(.time(pattern: .hourMinuteSecond)))"
                    )
                    .monospacedDigit().fixedSize()
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(.bar).overlay(alignment: .top) { Divider() }
    }
}

private struct CompressionStatistics: View {
    let metrics: CompressionMetrics?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 10) {
            CompressionStatistic(label: "平均速度", value: speed)
                .help("已处理的原始数据大小 ÷ 压缩用时。7z、ZIP 和 TAR 依据内核百分比估算。")
            CompressionStatistic(label: "文件进度", value: files)
                .help("已处理文件数 / 总文件数；空文件会在压缩完成时计入。")
            CompressionStatistic(label: "压缩率", value: ratio)
                .help(
                    metrics?.excludesRecovery == true
                        ? "压缩后文件数据 ÷ 已处理的原始数据，越低越小；不含恢复卷、索引和文件属性。"
                        : "已写入的压缩包大小 ÷ 已处理的原始数据，越低越小。压缩期间为估算值，可能超过 100%。")
            CompressionStatistic(label: "已处理", value: bytes)
        }
    }

    private var speed: String {
        guard let value = metrics?.bytesPerSecond, value.isFinite, value > 0 else { return "—" }
        return estimate
            + ByteCountFormatter.string(fromByteCount: Int64(min(value, Double(Int64.max / 2))), countStyle: .file)
            + "/s"
    }
    private var files: String {
        guard let metrics else { return "— / —" }
        return "\(metrics.completedFiles) / \(metrics.totalFiles)"
    }
    private var ratio: String {
        guard let ratio = metrics?.ratio else { return "—" }
        return estimate + ratio.formatted(.percent.precision(.fractionLength(1)))
    }
    private var bytes: String {
        guard let metrics else { return "— / —" }
        return estimate + ByteCountFormatter.string(fromByteCount: metrics.processedBytes, countStyle: .file)
            + " / " + ByteCountFormatter.string(fromByteCount: metrics.totalBytes, countStyle: .file)
    }
    private var estimate: String { metrics?.isEstimated == true ? "约 " : "" }
}

private struct CompressionStatistic: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

#Preview("压缩进度 · 窄窗口") {
    OperationBar(operation: OperationState(title: "创建压缩包", detail: "正在压缩文件…", fraction: 0.42, showsCompression: true)) {
    }
    .frame(width: 490)
}

import ArchiveCore
import Charts
import SwiftUI

struct FileTransferView: View {
    @Bindable var transfer: FileTransferStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: transfer.kind == .copy ? "doc.on.doc" : "folder.badge.arrowshape.right")
                    .font(.title).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(transfer.title).font(.title2.weight(.semibold))
                    Text("\(transfer.kind.title) \(transfer.sources.count) 个所选项目")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let fraction = transfer.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.largeTitle.weight(.medium)).monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                pathRow("从", value: sourceDescription)
                pathRow("到", value: transfer.destination.path)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("速度与总进度").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(speedDescription).font(.subheadline).monospacedDigit()
                }
                TransferProgressChart(
                    samples: transfer.samples, fraction: transfer.fraction,
                    bytesPerSecond: transfer.bytesPerSecond, speedDescription: speedDescription)
                HStack {
                    if let fraction = transfer.fraction {
                        Text("总进度 \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                    } else {
                        Text("正在计算总进度…")
                    }
                    Spacer()
                    Text("用时 \(duration(transfer.elapsed))")
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            Group {
                if let fraction = transfer.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }.accessibilityLabel("文件传输进度")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                detailRow("当前项目", value: transfer.progress.currentSource?.lastPathComponent ?? "正在准备…")
                detailRow("项目进度", value: "\(transfer.progress.completedItems) / \(transfer.progress.totalItems)")
                detailRow(
                    "已处理大小",
                    value:
                        "\(formatBytes(transfer.progress.completedBytes)) / \(formatBytes(transfer.progress.totalBytes))"
                )
                detailRow("预计剩余", value: remainingDescription)
            }.font(.callout)
            if let current = transfer.progress.currentSource {
                Text(current.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).help(current.path).textSelection(.enabled)
            }
            if let error = transfer.result?.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center) {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                if transfer.isRunning {
                    Button(transfer.isPaused ? "继续" : "暂停", systemImage: transfer.isPaused ? "play.fill" : "pause.fill")
                    {
                        transfer.togglePause()
                    }.disabled(transfer.isCancelling)
                    Button(transfer.isCancelling ? "正在取消…" : "取消") { transfer.cancel() }
                        .disabled(transfer.isCancelling).keyboardShortcut(.cancelAction)
                } else {
                    Button("完成") { transfer.isPresented = false }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24).frame(width: 570)
        .interactiveDismissDisabled(transfer.isRunning)
    }

    private var sourceDescription: String {
        let parents = Array(Set(transfer.sources.map { $0.deletingLastPathComponent().path })).sorted()
        return parents.joined(separator: "、")
    }

    private var speedDescription: String {
        if transfer.isPaused { return "已暂停" }
        if transfer.progress.phase == .moving { return "同一磁盘内移动" }
        guard transfer.bytesPerSecond > 0 else { return "—" }
        return formatBytes(Int64(min(transfer.bytesPerSecond, Double(Int64.max / 2)))) + "/s"
    }

    private var remainingDescription: String {
        if let result = transfer.result { return result.succeeded ? "已完成" : "已停止" }
        if transfer.isPaused { return "已暂停" }
        guard let remaining = transfer.remainingSeconds else { return "正在计算…" }
        return remaining < 1 ? "即将完成" : "约 " + duration(remaining)
    }

    private var footer: String {
        if let result = transfer.result, !result.succeeded {
            return "已完成 \(result.completedSources.count) 个所选项目；已完成的项目会保留。"
        }
        return "同名项目自动保留两个副本。文件夹进度包含其中的文件和子文件夹。"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .hourMinuteSecond))
    }

    private func pathRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            Text(value).lineLimit(2).truncationMode(.middle).help(value).textSelection(.enabled)
        }.font(.callout)
    }

    private func detailRow(_ title: String, value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().lineLimit(1).truncationMode(.middle).help(value)
        }
    }
}

struct TransferProgressChart: View {
    let samples: [TransferSpeedSample]
    let fraction: Double?
    let bytesPerSecond: Double
    let speedDescription: String

    private var maximumSpeed: Double {
        let peak = max(samples.map(\.bytesPerSecond).max() ?? 0, bytesPerSecond)
        return peak > 0 ? peak * 1.15 : 1_048_576
    }

    var body: some View {
        Chart {
            if let fraction {
                RectangleMark(
                    xStart: .value("开始", 0), xEnd: .value("总进度", fraction),
                    yStart: .value("基线", 0), yEnd: .value("速度上限", maximumSpeed)
                ).foregroundStyle(Color.accentColor.opacity(0.06))
            }
            ForEach(samples) { sample in
                AreaMark(x: .value("总进度", sample.fraction), y: .value("字节/秒", sample.bytesPerSecond))
                    .foregroundStyle(Color.accentColor.opacity(0.18))
                LineMark(x: .value("总进度", sample.fraction), y: .value("字节/秒", sample.bytesPerSecond))
                    .foregroundStyle(Color.accentColor).lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let fraction {
                RuleMark(x: .value("当前进度", fraction))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: fraction > 0.85 ? .trailing : .leading) {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.weight(.semibold)).monospacedDigit()
                    }
                if !samples.isEmpty {
                    PointMark(x: .value("当前进度", fraction), y: .value("当前速度", bytesPerSecond))
                        .foregroundStyle(Color.accentColor).symbolSize(36)
                }
            }
        }
        .chartXScale(domain: 0...1)
        .chartYScale(domain: 0...maximumSpeed)
        .chartXAxis {
            AxisMarks(values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(anchor: value.as(Double.self) == 1 ? .topTrailing : .topLeading) {
                    if let fraction = value.as(Double.self) {
                        Text(fraction, format: .percent.precision(.fractionLength(0))).font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let speed = value.as(Double.self) {
                        Text(formatBytes(Int64(speed)) + "/s").font(.caption2)
                    }
                }
            }
        }
        .frame(height: 150).padding(.top, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("传输速度与总进度，横轴百分之零至百分之一百，纵轴每秒传输速度")
        .accessibilityValue(
            "进度 \(fraction?.formatted(.percent.precision(.fractionLength(0))) ?? "正在计算")，速度 \(speedDescription)"
        )
        .transaction { $0.animation = nil }
    }
}

#Preview("文件传输") { FileTransferView(transfer: FileTransferStore()) }
#Preview("文件传输 · 深色") { FileTransferView(transfer: FileTransferStore()).preferredColorScheme(.dark) }

#Preview("速度与总进度 · 65%") {
    TransferProgressChart(
        samples: [
            TransferSpeedSample(fraction: 0, bytesPerSecond: 0),
            TransferSpeedSample(fraction: 0.1, bytesPerSecond: 90_000_000),
            TransferSpeedSample(fraction: 0.3, bytesPerSecond: 55_000_000),
            TransferSpeedSample(fraction: 0.5, bytesPerSecond: 120_000_000),
            TransferSpeedSample(fraction: 0.65, bytesPerSecond: 85_000_000),
        ], fraction: 0.65, bytesPerSecond: 85_000_000, speedDescription: "85 MB/s"
    ).padding(24).frame(width: 540)
}

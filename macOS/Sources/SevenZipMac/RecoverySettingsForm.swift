import ArchiveCore
import SwiftUI

struct RecoverySettingsDraft {
    var dataVolumes = "10"
    var recoveryVolumes = "2"

    func counts() throws -> RecoveryVolumeCounts {
        let counts = RecoveryVolumeCounts(
            data: try RecoveryInput.volumeCount(dataVolumes),
            recovery: try RecoveryInput.volumeCount(recoveryVolumes))
        try counts.validate()
        return counts
    }

    var dataError: String? {
        do {
            _ = try RecoveryInput.volumeCount(dataVolumes)
            return nil
        } catch { return error.localizedDescription }
    }

    var recoveryError: String? {
        do {
            _ = try RecoveryInput.volumeCount(recoveryVolumes)
            if dataError == nil { _ = try counts() }
            return nil
        } catch { return error.localizedDescription }
    }

    var isValid: Bool { dataError == nil && recoveryError == nil }
}

struct RecoverySettingsForm: View {
    @Binding var settings: RecoverySettingsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("分卷与恢复保护", systemImage: "checkmark.shield").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("数据卷数量").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("1–100", text: $settings.dataVolumes).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("数据卷数量").accessibilityIdentifier("recovery-data-volumes")
                            .accessibilityHint("输入 1 到 100 之间的整数")
                        if let error = settings.dataError {
                            Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                GridRow {
                    Text("恢复卷数量").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("不超过数据卷数量", text: $settings.recoveryVolumes).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("恢复卷数量").accessibilityIdentifier("recovery-parity-volumes")
                            .accessibilityHint("至少 1 卷，不能超过数据卷数量")
                        if let error = settings.recoveryError {
                            Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            if let counts = try? settings.counts() {
                Text(
                    "共 \(counts.data + counts.recovery) 卷 · 恢复载荷比例 \((Double(counts.recovery) / Double(counts.data)).formatted(.percent.precision(.fractionLength(1))))"
                )
                .font(.subheadline).accessibilityIdentifier("recovery-volume-summary")
                Text("任意丢失 \(counts.recovery) 卷仍可修复，前提是其余卷完整。局部损坏会共同消耗恢复能力。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("所有数据卷和恢复卷大小相同，具体大小在压缩完成后确定。小归档选择过多分卷会增加填充和索引开销。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview("Light") {
    RecoverySettingsForm(settings: .constant(RecoverySettingsDraft())).padding().frame(width: 530).preferredColorScheme(
        .light)
}
#Preview("Dark") {
    RecoverySettingsForm(settings: .constant(RecoverySettingsDraft())).padding().frame(width: 530).preferredColorScheme(
        .dark)
}

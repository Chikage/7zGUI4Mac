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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 24) {
                RecoveryVolumeCountField(
                    title: "数据卷数量", value: $settings.dataVolumes, error: settings.dataError,
                    identifier: "recovery-data-volumes", hint: "输入 1 到 100 之间的整数")
                RecoveryVolumeCountField(
                    title: "恢复卷数量", value: $settings.recoveryVolumes, error: settings.recoveryError,
                    identifier: "recovery-parity-volumes", hint: "至少 1 卷，不能超过数据卷数量")
            }
            if let counts = try? settings.counts() {
                Text(
                    "共 \(counts.data + counts.recovery) 卷 · 恢复载荷 \((Double(counts.recovery) / Double(counts.data)).formatted(.percent.precision(.fractionLength(0...1)))) · 其余卷完整时，可恢复任意丢失的 \(counts.recovery) 卷"
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("recovery-volume-summary")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RecoveryVolumeCountField: View {
    let title: String
    @Binding var value: String
    let error: String?
    let identifier: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                TextField("1–100", text: $value).textFieldStyle(.roundedBorder).frame(width: 80)
                    .accessibilityLabel(title).accessibilityIdentifier(identifier).accessibilityHint(hint)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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

import ArchiveCore
import SwiftUI

struct RARCompressionLevelPicker: View {
    @Binding var level: Int

    var body: some View {
        Picker("压缩等级", selection: $level) {
            Text("仅打包").tag(0)
            Text("最快").tag(1)
            Text("快速").tag(2)
            Text("标准（推荐）").tag(3)
            Text("较好").tag(4)
            Text("最佳").tag(5)
        }.accessibilityIdentifier("rar-compression-level")
    }
}

struct RARSettingsForm: View {
    @Binding var options: RAROptions
    var allowsVolumes = true
    var showsCompressionLevel = true
    var showsAdvancedOptions = true
    @State private var volumeSize = "100"
    @State private var volumeUnit: RecoverySizeUnit = .mib

    private var splitsVolumes: Binding<Bool> {
        Binding(
            get: { options.volumeSizeBytes != nil },
            set: {
                if $0 {
                    updateVolumeSize()
                } else {
                    options.volumeSizeBytes = nil
                    options.recoveryVolumeAmount = 0
                }
            })
    }

    private var validationError: String? {
        do {
            try options.validate()
            return nil
        } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsCompressionLevel { RARCompressionLevelPicker(level: $options.level) }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    Toggle("固实压缩", isOn: $options.solid)
                        .help("将相似文件连续压缩，可减小体积，但逐项读取和损坏恢复可能更慢。")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("创建后测试完整性", isOn: $options.testAfterCreation)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    if allowsVolumes {
                        Toggle("拆分为多个 RAR 分卷", isOn: splitsVolumes)
                            .accessibilityIdentifier("rar-split-volumes")
                    }
                    Toggle(
                        "添加恢复记录",
                        isOn: Binding(
                            get: { options.recoveryRecordPercent > 0 },
                            set: { options.recoveryRecordPercent = $0 ? 3 : 0 }))
                }
            }
            if allowsVolumes && options.volumeSizeBytes != nil { volumeFields }
            if options.recoveryRecordPercent > 0 {
                Stepper("恢复记录：\(options.recoveryRecordPercent)%", value: $options.recoveryRecordPercent, in: 1...100)
                Text("在每个 RAR 文件内部保存冗余数据，用于修复局部损坏。实际开销会略高于设定比例。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showsAdvancedOptions { RARAdvancedSettingsForm(options: $options) }
            if let validationError {
                Label(validationError, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            }
        }.onAppear(perform: initializeVolumeSize)
    }

    private var volumeFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("每卷上限")
                TextField("大小", text: $volumeSize).textFieldStyle(.roundedBorder).frame(width: 100)
                    .accessibilityLabel("RAR 每卷大小")
                    .onChange(of: volumeSize) { updateVolumeSize() }
                Picker("单位", selection: $volumeUnit) {
                    ForEach(RecoverySizeUnit.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 100).onChange(of: volumeUnit) { updateVolumeSize() }
            }
            Text("所有 .partN.rar 和 .rev 将保存在同一个 .rar-parts 文件夹。至少 64 KiB；最后一卷可以较小。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle(
                "生成 REV 恢复卷",
                isOn: Binding(
                    get: { options.recoveryVolumeAmount > 0 }, set: { options.recoveryVolumeAmount = $0 ? 1 : 0 })
            ).accessibilityIdentifier("rar-recovery-volumes")
            if options.recoveryVolumeAmount > 0 { RARRecoveryVolumeFields(options: $options) }
        }
    }

    private func initializeVolumeSize() {
        if let bytes = options.volumeSizeBytes {
            volumeSize = String(Double(bytes) / Double(volumeUnit.multiplier))
        }
    }

    private func updateVolumeSize() {
        guard let amount = Double(volumeSize), amount.isFinite, amount > 0,
            amount * Double(volumeUnit.multiplier) < Double(Int64.max)
        else {
            options.volumeSizeBytes = 0
            return
        }
        options.volumeSizeBytes = Int64(amount * Double(volumeUnit.multiplier))
    }
}

struct RARRecoveryVolumeFields: View {
    @Binding var options: RAROptions
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("数量", value: $options.recoveryVolumeAmount, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 90).accessibilityLabel("RAR 恢复卷数量或比例")
                Picker("恢复卷计量方式", selection: $options.recoveryVolumeMode) {
                    ForEach(RARRecoveryVolumeMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            Text("每个完整 REV 可重建一个缺失或损坏的数据卷。至少需要两个数据卷；指定个数须小于数据卷数。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

#Preview { RARSettingsForm(options: .constant(RAROptions())).padding().frame(width: 540) }

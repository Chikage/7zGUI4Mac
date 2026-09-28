import ArchiveCore
import SwiftUI

struct RARAdvancedSettingsForm: View {
    @Binding var options: RAROptions
    @State private var isExpanded = false
    @State private var section: Section = .compression

    private enum Section: String, CaseIterable, Identifiable {
        case compression = "压缩参数"
        case filters = "筛选与路径"
        case comment = "注释"
        var id: String { rawValue }
    }

    private var customizationCount: Int {
        let defaults = RAROptions()
        let changes = [
            options.dictionaryMB != defaults.dictionaryMB, options.threads != defaults.threads,
            options.quickOpen != defaults.quickOpen, options.useBlake2 != defaults.useBlake2,
            options.lockArchive != defaults.lockArchive,
            options.excludeEmptyDirectories != defaults.excludeEmptyDirectories,
            options.disableNameSort != defaults.disableNameSort, options.ignoreAttributes != defaults.ignoreAttributes,
            options.storeLinks != defaults.storeLinks, options.saveCreationTime != defaults.saveCreationTime,
            options.saveAccessTime != defaults.saveAccessTime, options.archiveTime != defaults.archiveTime,
            options.archivePath != defaults.archivePath, options.nameCase != defaults.nameCase,
            options.includeMasks != defaults.includeMasks, options.excludeMasks != defaults.excludeMasks,
            options.storeExtensions != defaults.storeExtensions, options.minimumSize != defaults.minimumSize,
            options.maximumSize != defaults.maximumSize, options.modifiedAfter != defaults.modifiedAfter,
            options.modifiedBefore != defaults.modifiedBefore, options.comment != defaults.comment,
        ]
        return changes.filter { $0 }.count
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("高级设置类别", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("rar-advanced-section")
                switch section {
                case .compression: advanced
                case .filters: filters
                case .comment:
                    Text("归档注释").font(.subheadline)
                    TextEditor(text: $options.comment).font(.body).frame(height: 90)
                        .border(.quaternary).accessibilityLabel("RAR 归档注释")
                    Text("最多 256 KiB；留空表示不添加注释。").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text("高级设置")
                Text(customizationCount == 0 ? "压缩参数、筛选与路径、注释" : "已自定义 \(customizationCount) 项")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityIdentifier("rar-advanced-settings")
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("字典大小", selection: $options.dictionaryMB) {
                ForEach([1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024], id: \.self) { Text("\($0) MiB").tag($0) }
            }
            Text("较大字典会增加压缩和解压所需内存。大于 64 MiB 的字典要求较新的 RAR 解压软件。")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(options.threads == 0 ? "线程：自动" : "线程上限：\(options.threads)", value: $options.threads, in: 0...64)
            Picker("快速打开信息", selection: $options.quickOpen) {
                Text("自动").tag("auto")
                Text("全部文件").tag("always")
                Text("不保存").tag("never")
            }
            Toggle("使用 BLAKE2 文件校验和", isOn: $options.useBlake2)
            Toggle("锁定归档，防止 RAR 意外修改", isOn: $options.lockArchive)
            Toggle("不添加空文件夹", isOn: $options.excludeEmptyDirectories)
            Toggle("不按扩展名排序固实文件", isOn: $options.disableNameSort)
            Toggle("忽略文件属性", isOn: $options.ignoreAttributes)
            Toggle("将符号链接保存为链接", isOn: $options.storeLinks)
            if options.storeLinks {
                Text("本应用的安全解压会拒绝含链接的归档；默认跳过符号链接。").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("保存创建时间", isOn: $options.saveCreationTime)
            Toggle("保存访问时间", isOn: $options.saveAccessTime)
            Picker("归档时间", selection: $options.archiveTime) {
                Text("当前时间").tag("current")
                Text("最新文件时间").tag("latest")
                Text("保留原时间").tag("keep")
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("归档内前缀目录（可选）", text: $options.archivePath).textFieldStyle(.roundedBorder)
            Picker("文件名大小写", selection: $options.nameCase) {
                Text("保持原样").tag("original")
                Text("小写").tag("lower")
                Text("大写").tag("upper")
            }
            Text("仅包含（每行一个匹配规则）").font(.subheadline)
            TextEditor(text: $options.includeMasks).frame(height: 65).border(.quaternary).accessibilityLabel("RAR 包含规则")
            Text("排除（每行一个匹配规则）").font(.subheadline)
            TextEditor(text: $options.excludeMasks).frame(height: 65).border(.quaternary).accessibilityLabel("RAR 排除规则")
            Text("支持 * 和 ?，例如 *.tmp；文件夹匹配规则以 / 结尾。留空表示不额外筛选。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("仅存储的扩展名（例如 jpg;mp4;zip）", text: $options.storeExtensions).textFieldStyle(.roundedBorder)
            sizeFilter("仅处理大于（字节）", value: $options.minimumSize)
            sizeFilter("仅处理小于（字节）", value: $options.maximumSize)
            dateFilter("修改时间晚于", value: $options.modifiedAfter)
            dateFilter("修改时间早于", value: $options.modifiedBefore)
        }
    }

    private func sizeFilter(_ title: String, value: Binding<Int64?>) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? 1 : nil }))
            if value.wrappedValue != nil {
                TextField(
                    title, value: Binding(get: { value.wrappedValue ?? 1 }, set: { value.wrappedValue = $0 }),
                    format: .number
                )
                .textFieldStyle(.roundedBorder).frame(width: 130).labelsHidden()
            }
        }
    }

    private func dateFilter(_ title: String, value: Binding<Date?>) -> some View {
        VStack(alignment: .leading) {
            Toggle(
                title,
                isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? Date() : nil }))
            if value.wrappedValue != nil {
                DatePicker(
                    title, selection: Binding(get: { value.wrappedValue ?? Date() }, set: { value.wrappedValue = $0 }))
            }
        }
    }
}

#Preview { RARAdvancedSettingsForm(options: .constant(RAROptions())).padding().frame(width: 540) }

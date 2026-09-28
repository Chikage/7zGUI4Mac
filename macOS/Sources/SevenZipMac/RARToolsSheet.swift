import AppKit
import ArchiveCore
import SwiftUI

struct RARToolsSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var source: URL?
    @State private var directory = FileManager.default.homeDirectoryForCurrentUser
    @State private var name = "RAR-处理结果"
    @State private var request = RARToolRequest()
    @State private var validation: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "RAR 工具", subtitle: "修复、恢复、编辑与导出", symbol: "wrench.and.screwdriver")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(source?.lastPathComponent ?? "选择 RAR、分卷或 REV 文件").lineLimit(2).help(source?.path ?? "")
                        Spacer()
                        Button("选择归档…") { chooseSource() }
                    }
                    Picker("操作", selection: $request.operation) {
                        ForEach(RARToolOperation.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("rar-tool-operation")
                    Text(explanation).font(.subheadline).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                    SecureField("密码（加密归档需要）", text: $request.password).textFieldStyle(.roundedBorder)
                    operationFields
                    Divider()
                    Text("结果保存位置").font(.headline)
                    FolderPicker(directory: $directory)
                    TextField("新建结果文件夹名称", text: $name).textFieldStyle(.roundedBorder)
                    Text("处理结果保存到一个新的文件夹。原归档和源文件始终保留。").font(.caption).foregroundStyle(.secondary)
                    if let validation {
                        Label(validation, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.caption)
                    }
                }.padding(24)
            }
            Divider()
            HStack {
                Button("参数说明") { openHelp() }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("开始处理") { submit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(
                        source == nil || name.isEmpty || (request.operation.needsSources && request.sources.isEmpty))
            }.padding(20)
        }.frame(width: 620, height: 720)
            .onChange(of: request.operation) {
                if request.operation.needsSources { request.options.recoveryVolumeAmount = 0 }
                if request.operation == .recoveryVolumes && request.options.recoveryVolumeAmount == 0 {
                    request.options.recoveryVolumeAmount = 1
                }
            }
            .onAppear {
                request.operation = store.rarToolOperation
                request.options.recoveryRecordPercent = 3
                request.options.recoveryVolumeAmount = 1
                if let url = store.rarToolSource { select(url) }
            }
    }

    @ViewBuilder private var operationFields: some View {
        switch request.operation {
        case .recoveryRecord:
            Stepper(
                "恢复记录：\(request.options.recoveryRecordPercent)%", value: $request.options.recoveryRecordPercent,
                in: 1...100)
        case .recoveryVolumes:
            RARRecoveryVolumeFields(options: $request.options)
        case .comment:
            TextEditor(text: $request.options.comment).frame(height: 130).border(.quaternary).accessibilityLabel("归档注释")
        case .delete, .rename:
            Text(request.operation == .delete ? "归档内路径或匹配规则（每行一个）" : "原条目的完整归档内路径")
            TextEditor(text: $request.entryNames).frame(height: 80).border(.quaternary).accessibilityLabel("归档内路径")
            if request.operation == .rename {
                TextField("新的归档内路径", text: $request.renamedPath).textFieldStyle(.roundedBorder)
            }
        case .add, .update, .freshen:
            HStack {
                Text("\(request.sources.count) 个来源项目")
                Spacer()
                Button("添加文件…") { chooseFiles() }
                Button("清空") { request.sources = [] }.disabled(request.sources.isEmpty)
            }
            ForEach(request.sources, id: \.self) { Text($0.path).font(.caption).lineLimit(1).truncationMode(.middle) }
            RARSettingsForm(options: $request.options, allowsVolumes: false)
        default: EmptyView()
        }
    }

    private var explanation: String {
        switch request.operation {
        case .repair: "用 RAR 内部的恢复记录修复损坏。没有恢复记录时只能尝试重建结构。仅在修复结果通过完整性测试后交付。"
        case .reconstruct: "先将同组 .rar 和 .rev 放在同一目录，可选择任意现存分卷或 REV。副本重建后会进行完整性测试。"
        case .recoveryRecord: "向单个 RAR 副本添加恢复记录。分卷归档的恢复记录须在创建时设置。"
        case .recoveryVolumes: "从完整的 RAR 分卷生成额外 .rev 文件。生成后不要修改原数据卷，否则恢复信息将失效。"
        case .lock: "锁定副本，防止 RAR 后续意外修改。此功能不提供加密，也不能阻止其他程序修改文件。"
        case .delete: "只删除新副本内匹配的条目。支持 * 和 ?，请核对规则；删除全部条目会得到空的结果文件夹。"
        case .rename: "重命名副本内的一个条目，必须输入完整路径，不支持通配符或重名目标。"
        case .add, .update, .freshen: "只适用于非分卷归档。路径相对于所选文件的共同上级目录，匹配路径才会更新原条目。"
        case .extractFlat: "忽略目录层级，将文件解压到同一文件夹；重名文件自动改名。含链接或不安全路径的归档会被拒绝。"
        case .convertSFX: "为单个 RAR 添加 Apple Silicon macOS 自解压模块。生成的是可执行程序，本应用不会自动运行它。"
        case .removeSFX: "从所选自解压程序中移除 SFX 模块，保留标准 RAR 归档副本。"
        case .comment: "设置副本的归档注释，最多 256 KiB；留空可清除注释。"
        case .exportComment: "将归档注释保存到结果文件夹的 comment.txt。"
        case .list, .technicalList: "将整个归档的文件名或技术信息导出为 UTF-8 文本。加密文件名的归档需要密码。"
        }
    }

    private func select(_ url: URL) {
        source = url
        directory = url.deletingLastPathComponent()
        name = url.deletingPathExtension().lastPathComponent + "-处理结果"
        if store.listing?.url == url { request.password = store.archivePassword }
        if url.pathExtension.lowercased() == "rev" { request.operation = .reconstruct }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "选择 RAR、分卷、REV 或自解压程序"
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !request.sources.contains(url) { request.sources.append(url) }
        }
    }

    private func openHelp() {
        let url =
            Bundle.main.url(forResource: "rar", withExtension: "txt", subdirectory: "RAR")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
                "Vendor/rar/rar.txt")
        NSWorkspace.shared.open(url)
    }

    private func submit() {
        do {
            guard let source else { return }
            try ArchivePath.validateFilename(name)
            let destination = directory.appendingPathComponent(name, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw ArchiveError.invalidInput("结果文件夹已存在，请修改名称。")
            }
            var submitted = request
            if request.operation.needsSources {
                submitted.options.recoveryVolumeAmount = 0
                try submitted.options.validate(password: submitted.password)
            }
            store.performRARTool(submitted, archive: source, destination: destination)
            request.password = ""
        } catch { validation = error.localizedDescription }
    }
}

#Preview { RARToolsSheet(store: AppStore()) }

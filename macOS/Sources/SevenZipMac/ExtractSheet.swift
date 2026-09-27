import ArchiveCore
import SwiftUI

struct ExtractSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    @State private var name = "解压文件"
    @State private var reveal = true
    @State private var restoreAttributes = true
    @State private var validation: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "解压归档", subtitle: store.listing?.url.lastPathComponent ?? "", symbol: "arrow.up.bin")
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("目标位置").font(.headline)
                    FolderPicker(directory: $directory)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("新建文件夹").font(.headline)
                    TextField("文件夹名称", text: $name).textFieldStyle(.roundedBorder)
                    Text("文件将解压到独立文件夹，保留原有目录结构。").font(.caption).foregroundStyle(.secondary)
                }
                if store.listing?.requiresKeyFile == true {
                    Text(store.archiveKeyFile.map { "使用密钥：\($0.lastPathComponent)" } ?? "自动使用同目录中匹配的恢复密钥文件。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if store.listing?.isEncrypted == true {
                    SecureField("归档密码", text: $store.archivePassword).textFieldStyle(.roundedBorder)
                }
                if store.listing?.preservesMetadata == true {
                    Toggle("恢复文件权限与扩展属性", isOn: $restoreAttributes)
                    Text("受系统限制的属性可能无法还原；文件内容会保留，并在完成后显示属性报告。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("完成后在 Finder 中显示", isOn: $reveal)
                if let validation {
                    Label(validation, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.caption)
                }
            }.padding(24)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("开始解压") { submit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(
                    name.isEmpty)
            }.padding(20)
        }.frame(width: 540)
            .onAppear {
                guard let archive = store.listing?.url else { return }
                directory = archive.deletingLastPathComponent()
                let base = ArchivePath.extractionName(for: archive)
                name = base
                var suffix = 2
                while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                    name = "\(base) \(suffix)"
                    suffix += 1
                }
            }
    }

    private func submit() {
        do {
            try ArchivePath.validateFilename(name)
            let destination = directory.appendingPathComponent(name, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                validation = "此文件夹已存在，请选择一个新的名称。"
                return
            }
            store.extract(to: destination, reveal: reveal, restoreAttributes: restoreAttributes)
        } catch { validation = error.localizedDescription }
    }
}

struct PasswordSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("归档需要密码", systemImage: "lock.shield").font(.title2.weight(.bold))
            Text(store.passwordError ?? "请输入归档密码。")
                .font(.subheadline).foregroundStyle(store.passwordError == nil ? Color.secondary : Color.red)
            SecureField("密码", text: $password).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit {
                    if !password.isEmpty {
                        store.submitPassword(password)
                        password = ""
                    }
                }
            HStack {
                Spacer()
                Button("取消") {
                    store.passwordAction = nil
                    store.passwordError = nil
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                Button("继续") {
                    store.submitPassword(password)
                    password = ""
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }.padding(28).frame(width: 420).onAppear { focused = true }
    }
}

#Preview { ExtractSheet(store: AppStore()) }

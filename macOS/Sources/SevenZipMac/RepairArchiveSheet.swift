import ArchiveCore
import SwiftUI

struct RepairArchiveSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    @State private var name = "已修复归档"
    @State private var validation: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "修复归档", subtitle: store.listing?.url.lastPathComponent ?? "", symbol: "bandage")
            VStack(alignment: .leading, spacing: 20) {
                Text("使用可用分卷和恢复卷生成完整副本，原有归档会保留。请先将找到的分卷放回同一个归档包。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if store.listing?.isEncrypted == true {
                    Text("修复无需密码或密钥，只校验密文存储。完成后仍需解锁并进行完整性测试，才能验证加密内容。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("保存到").font(.headline)
                    FolderPicker(directory: $directory)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("新归档名称").font(.headline)
                    HStack {
                        TextField("新归档名称", text: $name).textFieldStyle(.roundedBorder)
                        Text(".rz").foregroundStyle(.secondary)
                    }
                }
                if let validation {
                    Label(validation, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                }
            }.padding(24)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("重建分卷") { submit() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }.padding(20)
        }.frame(width: 540)
            .onAppear {
                guard let url = store.listing?.url else { return }
                directory = url.deletingLastPathComponent()
                let base = ArchivePath.extractionName(for: url) + "-已修复"
                name = base
                var suffix = 2
                while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".rz").path) {
                    name = "\(base) \(suffix)"
                    suffix += 1
                }
            }
    }

    private func submit() {
        do {
            try ArchivePath.validateFilename(name)
            let output = directory.appendingPathComponent(name + ".rz", isDirectory: true)
            guard !FileManager.default.fileExists(atPath: output.path) else {
                validation = "同名归档已存在，请修改名称或保存位置。"
                return
            }
            store.repair(to: output)
        } catch { validation = error.localizedDescription }
    }
}

#Preview { RepairArchiveSheet(store: AppStore()) }

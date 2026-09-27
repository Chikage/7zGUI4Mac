import AppKit
import ArchiveCore
import SwiftUI

struct RecoveryKeyFileSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var keyFile: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("选择恢复密钥", systemImage: "key.fill").font(.title2.weight(.bold))
            Text(store.keyFileError ?? "同目录中未找到可用的密钥文件。请选择创建此归档时生成的 .rzkey 文件。")
                .font(.subheadline).foregroundStyle(store.keyFileError == nil ? Color.secondary : Color.red)
            HStack {
                Text(keyFile?.lastPathComponent ?? "尚未选择密钥文件")
                    .lineLimit(2).truncationMode(.middle)
                Spacer()
                Button("选择密钥文件…") {
                    let panel = NSOpenPanel()
                    panel.title = "选择恢复密钥"
                    panel.message = "选择此归档的 .rzkey 文件，文件名可以不同。"
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = store.listing?.url.deletingLastPathComponent()
                    if panel.runModal() == .OK { keyFile = panel.url }
                }.accessibilityIdentifier("choose-recovery-key")
            }
            Text("密钥丢失后，恢复卷也无法解密内容。将密钥放回归档同目录后，后续可自动解锁。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") {
                    store.passwordAction = nil
                    store.keyFileError = nil
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                Button("解锁") {
                    if let keyFile { store.submitKeyFile(keyFile) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(keyFile == nil)
            }
        }.padding(28).frame(width: 480)
    }
}

#Preview { RecoveryKeyFileSheet(store: AppStore()) }

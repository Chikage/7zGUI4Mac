import ArchiveCore
import SwiftUI

enum RecoveryProtectionMode: String, CaseIterable, Identifiable {
    case none, password, keyFile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "不加密"
        case .password: "密码"
        case .keyFile: "自动生成密钥文件"
        }
    }
}

struct RecoveryProtectionForm: View {
    @Binding var mode: RecoveryProtectionMode
    @Binding var password: String
    @Binding var confirmation: String
    @Binding var standardEncryption: RecoveryEncryption
    @Binding var keyEncryption: RecoveryEncryption
    let aesAvailable: Bool?
    let capabilityError: String?
    let archiveName: String

    private var encryption: Binding<RecoveryEncryption> { mode == .keyFile ? $keyEncryption : $standardEncryption }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("保护方式", selection: $mode) {
                ForEach(RecoveryProtectionMode.allCases) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("recovery-protection")
            if mode == .password {
                SecureField("密码", text: $password).textFieldStyle(.roundedBorder)
                SecureField("再次输入密码", text: $confirmation).textFieldStyle(.roundedBorder)
                if !confirmation.isEmpty && password != confirmation {
                    Text("两次输入的密码不一致").font(.caption).foregroundStyle(.red)
                }
            } else if mode == .keyFile {
                Text("无需设置密码，将在同目录生成 \(archiveName).rzkey。打开时自动匹配同目录密钥，找不到时提示选择。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("请备份密钥。持有归档和密钥即可解密，需要保密时请分开存放；密钥丢失后恢复卷也无法解密。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if mode != .none {
                Picker("加密方式", selection: encryption) {
                    Text(RecoveryEncryption.standard.title).tag(RecoveryEncryption.standard)
                    if aesAvailable == true || encryption.wrappedValue == .dual {
                        Text(RecoveryEncryption.dual.title).tag(RecoveryEncryption.dual)
                    }
                }
                .disabled(aesAvailable != true && encryption.wrappedValue == .standard)
                .accessibilityIdentifier("recovery-encryption")
                Text(encryption.wrappedValue.algorithms).font(.caption).foregroundStyle(.secondary)
                if let capabilityError {
                    Text(capabilityError).font(.caption).foregroundStyle(.red)
                } else if aesAvailable == false {
                    Text("此设备不支持 AES 硬件加速。可手动选择标准加密。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if aesAvailable == nil {
                    Text("正在检测 AES 支持…").font(.caption).foregroundStyle(.secondary)
                }
                Text("同时加密内容、文件名和属性。无需解锁也可修复密文；验证内容和解压需要对应密码或密钥。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    RecoveryProtectionForm(
        mode: .constant(.keyFile), password: .constant(""), confirmation: .constant(""),
        standardEncryption: .constant(.standard), keyEncryption: .constant(.dual), aesAvailable: true,
        capabilityError: nil, archiveName: "资料")
}

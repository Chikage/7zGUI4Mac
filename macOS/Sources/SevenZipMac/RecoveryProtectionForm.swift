import ArchiveCore
import SwiftUI

enum RecoveryProtectionMode: String, CaseIterable, Identifiable {
    case none, password, keyFile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "不加密"
        case .password: "密码"
        case .keyFile: "生成密钥文件"
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                Picker("保护方式", selection: $mode) {
                    ForEach(RecoveryProtectionMode.allCases) { Text($0.title).tag($0) }
                }.frame(maxWidth: .infinity).accessibilityIdentifier("recovery-protection")
                if mode != .none {
                    Picker("加密方式", selection: encryption) {
                        Text(RecoveryEncryption.standard.title).tag(RecoveryEncryption.standard)
                        if aesAvailable == true || encryption.wrappedValue == .dual {
                            Text("双层（增加 AES）").tag(RecoveryEncryption.dual)
                        }
                    }
                    .disabled(aesAvailable != true && encryption.wrappedValue == .standard)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("recovery-encryption")
                }
            }
            if mode == .password {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("密码").foregroundStyle(.secondary)
                        SecureField("密码", text: $password).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("recovery-password")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("再次输入").foregroundStyle(.secondary)
                        SecureField("再次输入密码", text: $confirmation).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("recovery-password-confirmation")
                    }
                }
                if !confirmation.isEmpty && password != confirmation {
                    Label("两次输入的密码不一致", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("请妥善保存密码；恢复卷不能找回丢失的密码。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if mode == .keyFile {
                Text("将在同目录生成 \(archiveName).rzkey。密钥丢失后无法解密，请备份。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("需要保密时，请将密钥与归档分开存放。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("不加密内容、文件名和属性；仍提供恢复保护。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if mode != .none {
                if let capabilityError {
                    Text(capabilityError).font(.caption).foregroundStyle(.red)
                } else if aesAvailable == false {
                    Text(
                        encryption.wrappedValue == .dual
                            ? "此设备不支持 AES 硬件加速，请选择标准加密。"
                            : "此设备不支持 AES 硬件加速，当前使用标准加密。"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                } else if aesAvailable == nil {
                    Text("正在检测 AES 支持…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct RecoveryFormatDetails: View {
    let mode: RecoveryProtectionMode
    let encryption: RecoveryEncryption
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("所有数据卷和恢复卷大小相同，具体大小在压缩完成后确定。小归档选择过多分卷会增加填充和索引开销；局部损坏也会消耗恢复能力。")
                Text("保留文件属性包括权限、时间、ACL、Finder 信息和资源叉。无法恢复的属性会在解压完成后单独报告。")
                if mode != .none {
                    Text("加密算法：\(encryption.algorithms)")
                    Text("同时加密内容、文件名和属性。无需解锁也可修复密文；验证内容和解压需要对应密码或密钥。")
                    if mode == .keyFile {
                        Text("打开时自动匹配同目录密钥，找不到时提示选择。持有归档和密钥即可解密。")
                    }
                }
            }.font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text("更多说明")
                Text("分卷、文件属性与加密").font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityIdentifier("recovery-format-details")
    }
}

#Preview("Light") {
    VStack(alignment: .leading, spacing: 12) {
        RecoveryProtectionForm(
            mode: .constant(.keyFile), password: .constant(""), confirmation: .constant(""),
            standardEncryption: .constant(.standard), keyEncryption: .constant(.dual), aesAvailable: true,
            capabilityError: nil, archiveName: "资料")
        RecoveryFormatDetails(mode: .keyFile, encryption: .dual)
    }.padding(16).frame(width: 580).preferredColorScheme(.light)
}

#Preview("Password / Dark") {
    VStack(alignment: .leading, spacing: 12) {
        RecoveryProtectionForm(
            mode: .constant(.password), password: .constant(""), confirmation: .constant(""),
            standardEncryption: .constant(.standard), keyEncryption: .constant(.dual), aesAvailable: true,
            capabilityError: nil, archiveName: "资料")
        RecoveryFormatDetails(mode: .password, encryption: .standard)
    }.padding(16).frame(width: 580).preferredColorScheme(.dark)
}

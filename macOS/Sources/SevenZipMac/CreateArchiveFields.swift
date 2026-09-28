import ArchiveCore
import SwiftUI

struct CreateArchiveFields: View {
    @Binding var name: String
    @Binding var directory: URL
    @Binding var format: ArchiveFormat
    @Binding var level: Int
    @Binding var rarLevel: Int

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("名称").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("压缩包名称", text: $name).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("archive-name")
                    Text(".\(format.rawValue)").foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .leading)
                }
            }
            GridRow {
                Text("保存到").foregroundStyle(.secondary)
                FolderPicker(directory: $directory)
            }
            GridRow {
                Text("格式").foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Picker("格式", selection: $format) {
                        ForEach(ArchiveFormat.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 130).accessibilityIdentifier("archive-format")
                        .help(format.explanation)
                    if format == .rar {
                        RARCompressionLevelPicker(level: $rarLevel)
                    } else if format.supportsCompressionLevel {
                        Picker("压缩等级", selection: $level) {
                            Text("仅打包 · 不压缩").tag(0)
                            Text("快速 · 更省时间").tag(1)
                            Text("标准 · 推荐").tag(5)
                            Text("极限 · 更小体积").tag(9)
                        }.accessibilityIdentifier("archive-compression-level")
                    } else if format == .recovery {
                        Text("实验格式，仅本应用支持").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        // Compatibility limitations stay visible; routine format details are available as help.
        if format == .zip || format == .tar {
            Text(format.explanation).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ArchiveSourcesSection: View {
    @Binding var sources: [URL]
    let addFiles: () -> Void
    @State private var isExpanded = false

    private var summary: String {
        if sources.count == 1, let source = sources.first { return "来源：\(source.lastPathComponent)" }
        return "来源：\(sources.count) 个项目"
    }

    private var hasDifferentParents: Bool {
        guard let parent = sources.first?.deletingLastPathComponent() else { return false }
        return sources.dropFirst().contains { $0.deletingLastPathComponent() != parent }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if sources.isEmpty {
                    Label("选择要压缩的文件或文件夹", systemImage: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption).frame(width: 12).accessibilityHidden(true)
                            Text(summary).lineLimit(1).truncationMode(.middle)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(summary).accessibilityValue(isExpanded ? "已展开" : "已折叠")
                        .accessibilityHint("展开或折叠来源文件列表")
                        .accessibilityIdentifier("archive-sources-disclosure")
                        .help(sources.count == 1 ? sources[0].path : summary)
                }
                Spacer(minLength: 8)
                Button(action: addFiles) { Label("添加文件…", systemImage: "plus") }
            }
            if isExpanded && !sources.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sources, id: \.self) { url in
                            HStack(spacing: 8) {
                                Image(systemName: url.hasDirectoryPath ? "folder.fill" : "doc")
                                    .foregroundStyle(.blue).accessibilityHidden(true)
                                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle).help(url.path)
                                Spacer(minLength: 4)
                                Button {
                                    sources.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain).accessibilityLabel("移除 \(url.lastPathComponent)")
                            }.padding(.horizontal, 8).frame(height: 30)
                        }
                    }
                }.frame(height: CGFloat(min(sources.count, 4)) * 30)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("待压缩的文件").accessibilityIdentifier("archive-sources")
            }
            if hasDifferentParents {
                Text("来自不同位置的文件会保留相对于共同上级目录的路径。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ArchivePasswordFields: View {
    let format: ArchiveFormat
    @Binding var isEnabled: Bool
    @Binding var password: String
    @Binding var confirmation: String
    @Binding var encryptNames: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isEnabled) { Label("使用密码保护", systemImage: "lock") }
                .accessibilityIdentifier("archive-password-enabled")
            if isEnabled {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("密码").foregroundStyle(.secondary)
                        SecureField("密码", text: $password).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("archive-password")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("再次输入").foregroundStyle(.secondary)
                        SecureField("再次输入密码", text: $confirmation).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("archive-password-confirmation")
                    }
                }
                if !confirmation.isEmpty && password != confirmation {
                    Label("两次输入的密码不一致", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
                if format == .sevenZip || format == .rar {
                    Toggle("同时加密文件名", isOn: $encryptNames)
                }
                Text(format == .rar ? "密码仅用于本次操作，最多 127 个字符，请妥善保存。" : "密码仅用于本次操作，请自行妥善保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 14) {
        ArchiveSourcesSection(
            sources: .constant([URL(fileURLWithPath: "/Users/Shared/资料", isDirectory: true)]), addFiles: {})
        CreateArchiveFields(
            name: .constant("资料"), directory: .constant(URL(fileURLWithPath: "/Users/Shared")),
            format: .constant(.rar), level: .constant(5), rarLevel: .constant(3))
        ArchivePasswordFields(
            format: .rar, isEnabled: .constant(true), password: .constant(""),
            confirmation: .constant(""), encryptNames: .constant(true))
    }.padding(16).frame(width: 580)
}

import AppKit
import ArchiveCore
import SwiftUI

struct CreateArchiveSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "归档"
    @State private var directory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    @State private var format: ArchiveFormat = .sevenZip
    @State private var level = 5
    @State private var recoverySettings = RecoverySettingsDraft()
    @State private var preserveMetadata = true
    @State private var usePassword = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var encryptNames = true
    @State private var recoveryEncryption: RecoveryEncryption = .standard
    @State private var recoveryProtection: RecoveryProtectionMode = .keyFile
    @State private var keyFileEncryption: RecoveryEncryption = .dual
    @State private var aesAvailable: Bool?
    @State private var aesCapabilityError: String?
    @State private var validation: String?

    private var usesPassword: Bool {
        format == .recovery ? recoveryProtection == .password : usePassword && format.supportsPassword
    }
    private var selectedRecoveryEncryption: RecoveryEncryption {
        recoveryProtection == .keyFile ? keyFileEncryption : recoveryEncryption
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "新建压缩包", subtitle: "整理文件，打包成一份。", symbol: "archivebox")
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sourceSection
                    VStack(alignment: .leading, spacing: 12) {
                        Text("归档选项").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                            GridRow {
                                Text("名称").foregroundStyle(.secondary)
                                HStack {
                                    TextField("压缩包名称", text: $name).textFieldStyle(.roundedBorder)
                                    Text(".\(format.rawValue)").foregroundStyle(.secondary).frame(
                                        width: 40, alignment: .leading)
                                }
                            }
                            GridRow {
                                Text("保存到").foregroundStyle(.secondary)
                                FolderPicker(directory: $directory)
                            }
                            GridRow {
                                Text("格式").foregroundStyle(.secondary)
                                Picker("格式", selection: $format) {
                                    ForEach(ArchiveFormat.allCases) { Text($0.title).tag($0) }
                                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("archive-format")
                            }
                            if format.supportsCompressionLevel {
                                GridRow {
                                    Text("压缩等级").foregroundStyle(.secondary)
                                    Picker("压缩等级", selection: $level) {
                                        Text("仅打包 · 不压缩").tag(0)
                                        Text("快速 · 更省时间").tag(1)
                                        Text("标准 · 推荐").tag(5)
                                        Text("极限 · 更小体积").tag(9)
                                    }.labelsHidden()
                                }
                            }
                        }
                        Text(format.explanation)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if format == .recovery { RecoverySettingsForm(settings: $recoverySettings) }
                    if format == .recovery {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("保留文件权限与扩展属性", isOn: $preserveMetadata)
                                .accessibilityIdentifier("recovery-preserve-metadata")
                            Text("保存普通权限、时间、ACL、Finder 信息和资源叉。无法恢复的属性会在解压完成后单独报告。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if format == .recovery {
                        RecoveryProtectionForm(
                            mode: $recoveryProtection, password: $password, confirmation: $confirmation,
                            standardEncryption: $recoveryEncryption, keyEncryption: $keyFileEncryption,
                            aesAvailable: aesAvailable, capabilityError: aesCapabilityError, archiveName: name)
                    } else if format.supportsPassword {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $usePassword) { Label("使用密码保护", systemImage: "lock") }
                            if usePassword {
                                SecureField("密码", text: $password).textFieldStyle(.roundedBorder)
                                SecureField("再次输入密码", text: $confirmation).textFieldStyle(.roundedBorder)
                                if !confirmation.isEmpty && password != confirmation {
                                    Label("两次输入的密码不一致", systemImage: "exclamationmark.circle").font(.caption)
                                        .foregroundStyle(.red)
                                }
                                if format == .sevenZip { Toggle("同时加密文件名", isOn: $encryptNames) }
                                Text("密码仅用于本次操作，请自行妥善保存。").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let validation {
                        Label(validation, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    }
                }.padding(24)
            }
            Divider()
            HStack {
                Text("\(store.createSources.count) 个来源项目 · \(format.title)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("创建压缩包") { submit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(
                        store.createSources.isEmpty || name.isEmpty
                            || (format == .recovery && !recoverySettings.isValid)
                            || (format == .recovery && recoveryProtection != .none
                                && selectedRecoveryEncryption == .dual
                                && aesAvailable != true)
                            || (usesPassword
                                && (password.isEmpty || password != confirmation))
                    )
            }.padding(20)
        }.frame(width: 580, height: 730)
            .task(id: format) {
                guard format == .recovery else { return }
                do {
                    aesAvailable = try await store.supportsRecoveryAES()
                    aesCapabilityError = nil
                } catch is CancellationError {
                } catch {
                    aesAvailable = nil
                    aesCapabilityError = "无法检测 AES 支持：\(error.localizedDescription)"
                }
            }
            .onAppear {
                if let first = store.createSources.first {
                    name = store.createSources.count == 1 ? first.deletingPathExtension().lastPathComponent : "归档"
                    directory = first.deletingLastPathComponent()
                }
            }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("待压缩的文件").font(.headline)
                Spacer()
                Button {
                    addFiles()
                } label: {
                    Label("添加文件", systemImage: "plus")
                }
            }
            if store.createSources.isEmpty {
                Button {
                    addFiles()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus").font(.title2)
                        Text("选择文件或文件夹").font(.subheadline)
                    }.foregroundStyle(.blue).frame(maxWidth: .infinity).padding(24)
                        .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.createSources, id: \.self) { url in
                            HStack {
                                Image(systemName: url.hasDirectoryPath ? "folder.fill" : "doc").foregroundStyle(.blue)
                                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle).help(url.path)
                                Spacer()
                                Button {
                                    store.createSources.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain).accessibilityLabel("移除 \(url.lastPathComponent)")
                            }.padding(10)
                            if url != store.createSources.last { Divider() }
                        }
                    }
                }
                // Keep archive options visible even when hundreds of files are selected.
                .frame(height: CGFloat(min(store.createSources.count, 4)) * 40)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("待压缩的文件")
                .accessibilityIdentifier("archive-sources")
                if store.createSources.count > 4 {
                    Text("可在上方列表中滚动查看和移除文件。").font(.caption).foregroundStyle(.secondary)
                }
                Text("来自不同位置的文件会保留相对于共同上级目录的路径。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "添加到压缩包"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !store.createSources.contains(url) { store.createSources.append(url) }
        if store.createSources.count == panel.urls.count, let first = panel.urls.first {
            directory = first.deletingLastPathComponent()
            if panel.urls.count == 1 { name = first.deletingPathExtension().lastPathComponent }
        }
    }

    private func submit() {
        do {
            try ArchivePath.validateFilename(name)
            let destination = directory.appendingPathComponent(
                name + "." + format.rawValue, isDirectory: format == .recovery)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                validation = "同名文件已存在，请修改名称或保存位置。"
                return
            }
            var options = CompressionOptions(
                format: format, level: level,
                password: usesPassword ? password : "", encryptNames: encryptNames)
            if format == .recovery {
                options.recoveryVolumeCounts = try recoverySettings.counts()
                options.preserveMetadata = preserveMetadata
                options.recoveryEncryption = recoveryProtection == .none ? .standard : selectedRecoveryEncryption
                options.generateRecoveryKeyFile = recoveryProtection == .keyFile
                if options.generateRecoveryKeyFile
                    && FileManager.default.fileExists(atPath: RecoveryArchive.keyFileURL(for: destination).path)
                {
                    validation = "同名密钥文件已存在，请修改名称或保存位置。"
                    return
                }
            }
            store.createArchive(
                to: destination,
                options: options)
            password = ""
            confirmation = ""
        } catch { validation = error.localizedDescription }
    }
}

struct SheetHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title).foregroundStyle(.blue)
                .frame(width: 48, height: 48).background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(24).frame(maxWidth: .infinity).background(.bar)
    }
}

struct FolderPicker: View {
    @Binding var directory: URL
    var body: some View {
        HStack {
            Image(systemName: "folder").foregroundStyle(.blue)
            Text(directory.path).lineLimit(1).truncationMode(.middle).help(directory.path)
            Spacer(minLength: 4)
            Button("选择…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.directoryURL = directory
                panel.prompt = "选择文件夹"
                if panel.runModal() == .OK, let url = panel.url { directory = url }
            }
        }
    }
}

#Preview { CreateArchiveSheet(store: AppStore()) }

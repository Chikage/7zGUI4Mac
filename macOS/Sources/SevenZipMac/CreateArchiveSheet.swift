import AppKit
import ArchiveCore
import SwiftUI

struct CreateArchiveSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "归档"
    @State private var suggestedName = "归档"
    @State private var deleteSourcesAfterVerification = false
    @State private var directory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    @State private var format: ArchiveFormat = .sevenZip
    @State private var level = 5
    @State private var rarOptions = RAROptions()
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
        CreateArchiveSheetLayout {
            ArchiveSourcesSection(sources: $store.createSources, addFiles: addFiles)
            Divider()
            CreateArchiveFields(
                name: $name, directory: $directory, format: $format, level: $level, rarLevel: $rarOptions.level)
            if format == .rar {
                Divider()
                RARSettingsForm(options: $rarOptions, showsCompressionLevel: false, showsAdvancedOptions: false)
            }
            if format == .recovery {
                Divider()
                RecoverySettingsForm(settings: $recoverySettings)
                Toggle("保留文件权限与扩展属性", isOn: $preserveMetadata)
                    .accessibilityIdentifier("recovery-preserve-metadata")
                Divider()
                RecoveryProtectionForm(
                    mode: $recoveryProtection, password: $password, confirmation: $confirmation,
                    standardEncryption: $recoveryEncryption, keyEncryption: $keyFileEncryption,
                    aesAvailable: aesAvailable, capabilityError: aesCapabilityError, archiveName: name)
                RecoveryFormatDetails(mode: recoveryProtection, encryption: selectedRecoveryEncryption)
            } else if format.supportsPassword {
                ArchivePasswordFields(
                    format: format, isEnabled: $usePassword, password: $password,
                    confirmation: $confirmation, encryptNames: $encryptNames)
            }
            if format == .rar {
                Divider()
                RARAdvancedSettingsForm(options: $rarOptions)
            }
            Divider()
            Toggle("校验压缩包完好后自动删除原文件", isOn: $deleteSourcesAfterVerification)
                .accessibilityIdentifier("archive-delete-sources")
            Text("仅在压缩和完整性校验成功后，将原文件移入废纸篓。压缩或校验取消、校验失败、来源发生变化时保留原文件。")
                .font(.caption).foregroundStyle(.secondary)
            if let validation {
                Label(validation, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            }
        } actions: {
            Text("\(store.createSources.count) 个来源项目 · \(format.title)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("创建压缩包", action: submit)
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
        .task(id: format) { await checkAESCapability() }
        .onAppear(perform: initializeDestination)
        .onChange(of: store.createSources) { _, _ in updateSuggestedName() }
    }

    private var canSubmit: Bool {
        !store.createSources.isEmpty && !name.isEmpty
            && (format != .recovery || recoverySettings.isValid)
            && (format != .rar || (try? rarOptions.validate()) != nil)
            && !(format == .recovery && recoveryProtection != .none
                && selectedRecoveryEncryption == .dual && aesAvailable != true)
            && (!usesPassword || (!password.isEmpty && password == confirmation))
    }

    private func checkAESCapability() async {
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

    private func initializeDestination() {
        updateSuggestedName()
        if let first = store.createSources.first {
            directory = first.deletingLastPathComponent()
        }
    }

    private func updateSuggestedName() {
        let suggestion = ArchiveNameSuggestion.name(for: store.createSources)
        if name == suggestedName { name = suggestion }
        suggestedName = suggestion
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
                password: usesPassword ? password : "", encryptNames: encryptNames,
                deleteSourcesAfterVerification: deleteSourcesAfterVerification)
            if format == .rar {
                try rarOptions.validate(password: options.password)
                options.rar = rarOptions
                if rarOptions.volumeSizeBytes != nil
                    && FileManager.default.fileExists(atPath: RARArchive.volumeDirectory(for: destination).path)
                {
                    validation = "同名 RAR 分卷文件夹已存在，请修改名称或保存位置。"
                    return
                }
            }
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

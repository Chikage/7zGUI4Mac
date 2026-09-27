import AppKit
import ArchiveCore
import SwiftUI

struct ArchiveBrowser: View {
    @Bindable var store: AppStore
    private var rows: [BrowserEntry] {
        store.archiveIndex.entries(in: store.folder, search: store.search)
    }

    var body: some View {
        if let listing = store.listing {
            VStack(spacing: 0) {
                navigationBar
                header(listing)
                Divider()
                if listing.directoryUnavailable {
                    ContentUnavailableView {
                        Label("目录索引需要修复", systemImage: "bandage")
                    } description: {
                        Text("部分索引数据已损坏或缺失。可以先使用恢复卷重建归档。")
                    } actions: {
                        Button("修复归档…") { store.requestRepair() }.buttonStyle(.borderedProminent).disabled(store.isBusy)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if listing.isLocked {
                    ContentUnavailableView {
                        Label("归档已加密", systemImage: "lock.shield")
                    } description: {
                        Text(
                            listing.requiresKeyFile
                                ? "请选择对应的恢复密钥文件以查看内容。无需密钥也可以修复存储损坏。" : "输入密码以查看文件。无需密码也可以使用恢复卷修复存储损坏。")
                    } actions: {
                        Button("解锁归档") { store.requestUnlock() }.buttonStyle(.borderedProminent).disabled(store.isBusy)
                        Button("修复归档…") { store.requestRepair() }.disabled(store.isBusy)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    BrowserItemsView(
                        entries: rows, selection: $store.selection,
                        searchActive: !store.search.isEmpty, open: open
                    ) { ids in
                        contextMenu(ids)
                    }
                    Divider()
                    HStack {
                        Text("\(rows.count) 个项目")
                        if !store.selection.isEmpty { Text("· 已选择 \(store.selection.count) 项") }
                        Spacer()
                        Text("双击文件夹以浏览 · 文件需解压后打开")
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        } else {
            ContentUnavailableView {
                Label("还没有打开归档", systemImage: "archivebox")
            } description: {
                Text("打开压缩包，查看文件内容、大小和加密状态。")
            } actions: {
                Button("打开压缩包…") { store.chooseArchive() }.buttonStyle(.borderedProminent).disabled(store.isBusy)
                Button("浏览本地文件") { store.page = .files }
            }
        }
    }

    private func header(_ listing: ArchiveListing) -> some View {
        HStack(spacing: 12) {
            ArchiveMark(size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(listing.url.lastPathComponent).font(.title3.bold()).lineLimit(1).truncationMode(.middle)
                Text(
                    listing.directoryUnavailable
                        ? "\(listing.format.uppercased()) · \(formatBytes(listing.physicalSize)) · 目录待修复"
                        : listing.isLocked
                            ? "\(listing.format.uppercased()) · \(formatBytes(listing.physicalSize)) · 目录已加密"
                            : "\(listing.format.uppercased()) · \(formatBytes(listing.physicalSize)) · \(listing.fileCount) 个文件 · 原始大小 \(formatBytes(listing.totalSize))"
                )
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let recovery = listing.recoveryDetails {
                    if recovery.profile == 4, let size = recovery.volumeSizeBytes,
                        let losses = recovery.toleratedVolumeLosses
                    {
                        Text(
                            "\(recovery.dataVolumes) 个数据卷 + \(recovery.recoveryVolumes) 个恢复卷 · 每卷 \(formatRecoveryBytes(size))"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Text("其余卷完整时，可修复任意 \(losses) 个缺失卷。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(
                            "每卷上限 \(formatRecoveryBytes(recovery.volumeLimitBytes)) · 恢复载荷 \(formatRecoveryBytes(recovery.payloadBytes)) · 实际比例 \(recovery.actualRatio.formatted(.percent.precision(.fractionLength(1))))"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                } else if listing.supportsRecovery {
                    Text("旧版归档 · 固定 10+2 恢复配置").font(.caption).foregroundStyle(.secondary)
                }
                if listing.preservesMetadata {
                    Text("包含文件权限与扩展属性").font(.caption).foregroundStyle(.secondary)
                }
                if let encryption = listing.recoveryEncryption {
                    Text(encryption.algorithms).font(.caption).foregroundStyle(.secondary)
                }
                if listing.requiresKeyFile {
                    Text("独立密钥文件保护").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if listing.supportsRecovery || listing.isEncrypted {
                Label(
                    listing.isEncrypted ? "已加密" : "冗余恢复",
                    systemImage: listing.isEncrypted ? "lock" : "shield.checkered"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            BrowserViewMenu()
        }.padding(16).help(listing.url.path)
    }

    private var navigationBar: some View {
        HStack(spacing: 10) {
            Button {
                store.browserBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(store.browserHistory.back.isEmpty || !store.canNavigateBrowser).accessibilityLabel("后退")
            .help("后退 ⌘[").keyboardShortcut("[", modifiers: .command)
            Button {
                store.browserForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(store.browserHistory.forward.isEmpty || !store.canNavigateBrowser).accessibilityLabel("前进")
            .help("前进 ⌘]").keyboardShortcut("]", modifiers: .command)
            Button {
                store.browserUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(!store.canNavigateBrowser)
            .help(store.folder.isEmpty ? "返回压缩包所在文件夹 ⌘↑" : "上一级文件夹 ⌘↑")
            .accessibilityLabel(store.folder.isEmpty ? "返回压缩包所在文件夹" : "上一级文件夹")
            .keyboardShortcut(.upArrow, modifiers: .command)
            Menu {
                Button("返回所在文件夹") { store.showArchiveParent() }
                Divider()
                Button("归档根目录") { store.navigate(to: "") }
                let components = store.folder.split(separator: "/")
                ForEach(components.indices, id: \.self) { index in
                    Button(String(components[index])) {
                        store.navigate(to: components.prefix(index + 1).joined(separator: "/"))
                    }
                }
            } label: {
                Label(archivePath, systemImage: "doc.zipper")
                    .lineLimit(1).truncationMode(.middle)
            }.menuStyle(.borderlessButton).disabled(!store.canNavigateBrowser).help(archivePath)
            Spacer(minLength: 8)
            BrowserSearchField(text: $store.search, placeholder: "搜索整个归档").frame(width: 190)
        }.padding(12).background(.bar)
    }

    private var archivePath: String {
        let path = store.listing?.url.path ?? ""
        return store.folder.isEmpty ? path : path + "/" + store.folder
    }

    @ViewBuilder private func contextMenu(_ ids: Set<String>) -> some View {
        if ids.count == 1, let entry = rows.first(where: { ids.contains($0.id) }), entry.isDirectory {
            Button("打开文件夹") { store.navigate(to: entry.id) }
            Divider()
        }
        Button("解压整个归档…") { store.requestExtract() }.disabled(store.isBusy)
        Button("测试完整性") { store.testArchive() }.disabled(store.isBusy)
        if store.listing?.supportsRecovery == true {
            Button("修复归档…") { store.requestRepair() }.disabled(store.isBusy)
        }
        Divider()
        Button("复制归档内路径") { copyBrowserPaths(ids.sorted()) }.disabled(ids.isEmpty)
        Button("在 Finder 中显示压缩包") {
            if let url = store.listing?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func open(_ ids: Set<String>) {
        guard ids.count == 1, let entry = rows.first(where: { ids.contains($0.id) }) else { return }
        if entry.isDirectory { store.navigate(to: entry.id) } else { store.requestExtract() }
    }
}

func formatBytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

#Preview { ArchiveBrowser(store: AppStore()) }

private func formatRecoveryBytes(_ count: Int64) -> String {
    let unit: RecoverySizeUnit =
        count >= RecoverySizeUnit.gib.multiplier
        ? .gib
        : count >= RecoverySizeUnit.mib.multiplier ? .mib : .kib
    let amount = Double(count) / Double(unit.multiplier)
    return "\(amount.formatted(.number.precision(.fractionLength(0...3)))) \(unit.rawValue)"
}

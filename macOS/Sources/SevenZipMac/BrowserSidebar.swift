import AppKit
import ArchiveCore
import SwiftUI

struct FileBrowserSidebar: View {
    @Bindable var store: AppStore
    private var files: FileBrowserStore { store.files }

    var body: some View {
        Section("常用位置") {
            location("个人文件夹", symbol: "house", url: files.home)
            location("桌面", symbol: "desktopcomputer", url: files.home.appendingPathComponent("Desktop"))
            location("文稿", symbol: "doc.text", url: files.home.appendingPathComponent("Documents"))
            location("下载", symbol: "arrow.down.circle", url: files.home.appendingPathComponent("Downloads"))
            Button {
                store.chooseDirectory()
            } label: {
                Label("选择文件夹…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.plain)
        }.disabled(!store.canNavigateBrowser)
        MTPBrowserSidebar(store: store, mtp: store.mtp)
        Section("文件夹") {
            DirectoryTreeRow(store: store, url: URL(fileURLWithPath: "/Volumes", isDirectory: true), title: "磁盘与卷")
            DirectoryTreeRow(store: store, url: files.home, title: "个人文件夹")
            DirectoryTreeRow(store: store, url: URL(fileURLWithPath: "/", isDirectory: true), title: "此 Mac")
        }
    }

    private func location(_ title: String, symbol: String, url: URL) -> some View {
        Button {
            store.navigate(to: url)
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.plain).help(url.path)
    }
}

private struct DirectoryTreeRow: View {
    @Bindable var store: AppStore
    private var files: FileBrowserStore { store.files }
    let url: URL
    var title: String? = nil
    private var isExpanded: Bool { files.expanded.contains(url.path) }
    private var isSelected: Bool { !store.isBrowsingArchive && !store.isBrowsingMTP && files.directory.path == url.path }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { isExpanded }, set: { files.setExpanded(url, $0) })) {
            if let children = files.treeChildren[url.path] {
                if children.isEmpty { Text("无子文件夹").font(.caption).foregroundStyle(.secondary) }
                ForEach(children) { child in
                    if let childURL = child.url { DirectoryTreeRow(store: store, url: childURL) }
                }
            } else if let error = files.treeErrors[url.path] {
                Button("无法读取 · 重试") { Task { await files.loadChildren(url) } }
                    .buttonStyle(.plain).font(.caption).help(error)
            } else {
                ProgressView().controlSize(.mini)
            }
        } label: {
            Button {
                store.navigate(to: url)
            } label: {
                Label(title ?? url.lastPathComponent, systemImage: "folder.fill")
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3).contentShape(Rectangle())
            }.buttonStyle(.plain).help(url.path)
                .disabled(!store.canNavigateBrowser)
                .listRowBackground(isSelected ? Color.accentColor.opacity(0.16) : .clear)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .contextMenu {
                    Button("打开文件夹") { store.navigate(to: url) }
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("复制路径") { copyBrowserPaths([url.path]) }
                }
        }
        .task(id: isExpanded) { if isExpanded { await files.loadChildren(url) } }
    }
}

struct ArchiveBrowserSidebar: View {
    @Bindable var store: AppStore
    var body: some View {
        if let listing = store.listing {
            Section("归档目录") {
                Button {
                    store.navigate(to: "")
                } label: {
                    Label(listing.url.lastPathComponent, systemImage: "archivebox")
                        .lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain).help(listing.url.path)
                    .foregroundStyle(store.folder.isEmpty ? Color.accentColor : .primary)
                ForEach(store.archiveIndex.folders(in: "")) { entry in
                    ArchiveTreeRow(store: store, entry: entry)
                }
                Button {
                    store.showArchiveParent()
                } label: {
                    Label("打开所在文件夹", systemImage: "arrow.turn.up.left")
                }
                .buttonStyle(.plain)
            }.disabled(!store.canNavigateBrowser)
        }
    }
}

private struct ArchiveTreeRow: View {
    @Bindable var store: AppStore
    let entry: BrowserEntry
    @State private var expanded = false
    var body: some View {
        let children = store.archiveIndex.folders(in: entry.id)
        Group {
            if children.isEmpty {
                label
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(children) { child in ArchiveTreeRow(store: store, entry: child) }
                } label: {
                    label
                }
            }
        }
        .onChange(of: store.folder, initial: true) { _, path in
            if path.hasPrefix(entry.id + "/") { expanded = true }
        }
    }
    private var label: some View {
        Button {
            store.navigate(to: entry.id)
        } label: {
            Label(entry.name, systemImage: "folder.fill").lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help(entry.id)
            .foregroundStyle(store.folder == entry.id ? Color.accentColor : .primary)
            .accessibilityAddTraits(store.folder == entry.id ? .isSelected : [])
            .contextMenu {
                Button("打开文件夹") { store.navigate(to: entry.id) }
                Button("复制归档内路径") { copyBrowserPaths([entry.id]) }
                Button("解压整个归档…") { store.requestExtract() }.disabled(store.isBusy)
            }
    }
}

#Preview {
    let store = AppStore()
    List { FileBrowserSidebar(store: store) }.frame(width: 260)
}

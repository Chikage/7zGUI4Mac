import AppKit
import ArchiveCore
import QuickLook
import SwiftUI

struct MTPBrowserSidebar: View {
    @Bindable var store: AppStore
    @Bindable var mtp: MTPBrowserStore

    var body: some View {
        Section("MTP 设备") {
            ForEach(mtp.devices) { device in
                Button {
                    store.navigate(to: MTPDirectory(device: device))
                } label: {
                    Label(device.name, systemImage: "externaldrive")
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain).disabled(!store.canNavigateBrowser)
                .foregroundStyle(
                    store.isBrowsingMTP && mtp.directory?.device.id == device.id ? Color.accentColor : .primary
                )
                .help("浏览 \(device.name) 的存储空间")
            }
            if let error = mtp.scanError {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else if mtp.hasScanned && !mtp.isScanning && mtp.devices.isEmpty {
                Text("连接设备，解锁后选择“文件传输 / MTP”，再刷新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                mtp.scan()
            } label: {
                Label(mtp.isScanning ? "正在查找设备…" : "刷新 MTP 设备", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain).disabled(!store.canNavigateBrowser)
            .accessibilityIdentifier("mtp-refresh-devices")
        }
        .task(id: store.canNavigateBrowser) {
            if store.canNavigateBrowser { mtp.scanIfNeeded() }
        }
    }
}

struct MTPBrowser: View {
    @Bindable var store: AppStore
    @Bindable var mtp: MTPBrowserStore
    @State private var previewURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            HStack(spacing: 14) {
                Label(mtp.directory?.title ?? "MTP 设备", systemImage: "externaldrive")
                    .font(.headline).lineLimit(1)
                Text("只读浏览").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    preview(mtp.selection)
                } label: {
                    Label("预览", systemImage: "eye")
                }.disabled(selectedFile(mtp.selection) == nil || store.isBusy)
                    .help("下载本地副本后快速查看（空格键）")
                Toggle("显示隐藏文件", isOn: $mtp.showHidden).toggleStyle(.checkbox)
                BrowserViewMenu()
            }.padding(12).background(.bar)
            Divider()
            Group {
                if let error = mtp.directoryError {
                    ContentUnavailableView {
                        Label("无法读取 MTP 目录", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { mtp.refresh() }.disabled(store.isBusy)
                        Button("刷新设备") { mtp.scan() }.disabled(store.isBusy)
                    }
                } else {
                    BrowserItemsView(
                        entries: mtp.visibleEntries, selection: $mtp.selection,
                        searchActive: !mtp.search.isEmpty, open: open, preview: preview
                    ) { ids in
                        contextMenu(ids)
                    }.disabled(store.isBusy)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if mtp.isLoading || mtp.isDownloading {
                    VStack(spacing: 12) {
                        ProgressView(mtp.isDownloading ? "正在下载文件到 Mac…" : "正在读取 MTP 目录…")
                        Button("取消") { mtp.cancel() }
                    }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Divider()
            HStack {
                Text("\(mtp.visibleEntries.count) 个项目")
                if !mtp.selection.isEmpty { Text("· 已选择 \(mtp.selection.count) 项") }
                Spacer()
                Text("双击打开 · 空格预览 · 文件下载到本机后查看，修改不会同步至设备")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .quickLookPreview($previewURL)
        .onChange(of: mtp.directory) { previewURL = nil }
        .onDisappear { previewURL = nil }
    }

    private var navigationBar: some View {
        HStack(spacing: 10) {
            Button {
                store.browserBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(store.browserHistory.back.isEmpty || !store.canNavigateBrowser)
            .accessibilityLabel("后退").help("后退 ⌘[").keyboardShortcut("[", modifiers: .command)
            Button {
                store.browserForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(store.browserHistory.forward.isEmpty || !store.canNavigateBrowser)
            .accessibilityLabel("前进").help("前进 ⌘]").keyboardShortcut("]", modifiers: .command)
            Button {
                store.browserUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(mtp.directory?.parent == nil || !store.canNavigateBrowser)
            .accessibilityLabel("上一级").help("上一级 ⌘↑").keyboardShortcut(.upArrow, modifiers: .command)
            Menu {
                if let directory = mtp.directory {
                    Button(directory.device.name) { store.navigate(to: MTPDirectory(device: directory.device)) }
                    ForEach(directory.trail.indices, id: \.self) { index in
                        Button(directory.trail[index].name) {
                            var destination = directory
                            for _ in 0..<(directory.trail.count - index - 1) {
                                if let parent = destination.parent { destination = parent }
                            }
                            store.navigate(to: destination)
                        }
                    }
                }
            } label: {
                Text(mtp.directory?.displayPath ?? "MTP 设备").lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(!store.canNavigateBrowser).help(mtp.directory?.displayPath ?? "")
            Button {
                mtp.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!store.canNavigateBrowser).accessibilityLabel("刷新 MTP 目录")
            .help("刷新 ⌘R").keyboardShortcut("r", modifiers: .command)
            BrowserSearchField(text: $mtp.search, placeholder: "搜索当前文件夹").frame(width: 180)
        }.padding(12).background(.bar)
    }

    @ViewBuilder private func contextMenu(_ ids: Set<String>) -> some View {
        if ids.count == 1, let entry = mtp.entries.first(where: { ids.contains($0.id) }) {
            Button(entry.isDirectory ? "打开文件夹" : "下载并打开") { open(ids) }
                .disabled(store.isBusy)
            if !entry.isDirectory {
                Button("下载并快速查看") { preview(ids) }.disabled(store.isBusy)
            }
            Button("复制设备内路径") {
                copyBrowserPaths([(mtp.directory?.displayPath ?? "") + " / " + entry.name])
            }
        }
    }

    private func selectedFile(_ ids: Set<String>) -> MTPEntry? {
        guard ids.count == 1 else { return nil }
        return mtp.entries.first { ids.contains($0.id) && !$0.isDirectory }
    }

    private func open(_ ids: Set<String>) {
        guard !store.isBusy, ids.count == 1,
            let entry = mtp.entries.first(where: { ids.contains($0.id) })
        else { return }
        if let destination = mtp.directory?.appending(entry) {
            store.navigate(to: destination)
        } else if !entry.isDirectory {
            let source = mtp.directory
            mtp.download(entry) { url in
                if BrowserEntry.isArchiveName(entry.name) {
                    if let source { store.openMTPArchive(url, from: source) }
                } else if !NSWorkspace.shared.open(url) {
                    mtp.errorMessage = "文件已下载，但没有可用于打开此文件的应用。请尝试快速查看。"
                }
            }
        }
    }

    @discardableResult private func preview(_ ids: Set<String>) -> Bool {
        guard !store.isBusy, let entry = selectedFile(ids) else { return false }
        mtp.download(entry) { url in previewURL = url }
        return true
    }
}

#Preview { MTPBrowser(store: AppStore(), mtp: MTPBrowserStore()) }

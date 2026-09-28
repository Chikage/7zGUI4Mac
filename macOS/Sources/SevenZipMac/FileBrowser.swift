import AppKit
import ArchiveCore
import QuickLook
import SwiftUI

struct FileBrowser: View {
    @Bindable var store: AppStore
    @Bindable var files: FileBrowserStore
    @State private var edit: FileNameEdit?
    @State private var address = ""
    @State private var previewURL: URL?
    @State private var previewURLs: [URL] = []
    @Environment(\.controlActiveState) private var activeState

    private var visibleEntries: [BrowserEntry] {
        files.search.isEmpty
            ? files.entries : files.entries.filter { $0.name.localizedCaseInsensitiveContains(files.search) }
    }

    var body: some View {
        Group {
            if store.isBrowsingArchive {
                ArchiveBrowser(store: store)
            } else {
                localBrowser
            }
        }
        .alert(
            "文件操作未完成",
            isPresented: Binding(
                get: { files.errorMessage != nil }, set: { if !$0 { files.errorMessage = nil } }
            )
        ) {
            Button("好") { files.errorMessage = nil }
        } message: {
            Text(files.errorMessage ?? "")
        }
    }

    private var localBrowser: some View {
        VStack(spacing: 0) {
            navigationBar
            commandBar
            Divider()
            Group {
                if let error = files.directoryError {
                    ContentUnavailableView {
                        Label("无法读取文件夹", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { files.refresh() }
                        Button("选择其他文件夹…") { store.chooseDirectory() }
                    }
                } else {
                    BrowserItemsView(
                        entries: visibleEntries, selection: $files.selection,
                        searchActive: !files.search.isEmpty, open: open, preview: preview,
                        cutPaths: files.clipboard.cutPaths
                    ) { ids in
                        contextMenu(ids)
                    }
                    .disabled(files.isLoading || files.isMutating)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if files.isLoading {
                    ProgressView("正在读取文件夹…").padding(20).background(
                        .regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .allowsHitTesting(!files.isLoading && !files.isMutating)
            Divider()
            HStack {
                Text("\(visibleEntries.count) 个项目")
                if !files.selection.isEmpty { Text("· 已选择 \(files.selection.count) 项") }
                Spacer()
                if !files.clipboard.cutPaths.isEmpty {
                    Text("已剪切 \(files.clipboard.cutPaths.count) 项 · 到目标文件夹粘贴")
                } else {
                    Text("双击文件夹或压缩包以浏览 · 空格预览")
                }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .task {
            files.clipboard.refresh()
            await files.loadIfNeeded()
            address = files.directory.path
            // NSPasteboard has no change notification. Read URLs only when its change count changes.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                files.clipboard.refresh()
            }
        }
        .quickLookPreview($previewURL, in: previewURLs)
        .onChange(of: files.directory) { _, url in
            address = url.path
            closePreview()
        }
        .onChange(of: files.entries) { _, entries in
            let available = Set(entries.compactMap(\.url))
            previewURLs.removeAll { !available.contains($0) }
            if let previewURL, !available.contains(previewURL) { closePreview() }
        }
        .onDisappear { closePreview() }
        .onChange(of: files.showHidden) { files.refresh() }
        .onChange(of: activeState) { _, value in
            if value != .inactive {
                files.clipboard.refresh()
                files.refresh()
            }
        }
        .onCommand(#selector(NSText.copy(_:))) {
            guard !store.isBusy else { return }
            files.copySelection(files.selection, kind: .copy)
        }
        .onCommand(#selector(NSText.cut(_:))) {
            guard !store.isBusy else { return }
            files.copySelection(files.selection, kind: .move)
        }
        .onCommand(#selector(NSText.paste(_:))) {
            guard !store.isBusy else { return }
            files.paste()
        }
        .sheet(item: $edit) { item in
            FileNameSheet(edit: item, files: files)
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 10) {
            Button {
                store.browserBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(store.browserHistory.back.isEmpty || !store.canNavigateBrowser).help("后退 ⌘[")
            .accessibilityLabel("后退").keyboardShortcut("[", modifiers: .command)
            Button {
                store.browserForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(store.browserHistory.forward.isEmpty || !store.canNavigateBrowser).help("前进 ⌘]")
            .accessibilityLabel("前进").keyboardShortcut("]", modifiers: .command)
            Button {
                store.browserUp()
            } label: {
                Image(systemName: "arrow.up")
            }.disabled(!files.canGoUp || !store.canNavigateBrowser).help("上一级 ⌘↑")
                .accessibilityLabel("上一级文件夹").keyboardShortcut(.upArrow, modifiers: .command)
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("文件夹路径", text: $address)
                    .textFieldStyle(.plain).accessibilityLabel("文件夹路径，按回车前往")
                    .onSubmit {
                        let path = (address as NSString).expandingTildeInPath
                        let url =
                            path.hasPrefix("/")
                            ? URL(fileURLWithPath: path, isDirectory: true)
                            : files.directory.appendingPathComponent(path, isDirectory: true)
                        store.navigate(to: url)
                    }
                Button {
                    files.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).disabled(files.isLoading).help("刷新 ⌘R")
                .accessibilityLabel("刷新文件夹").keyboardShortcut("r", modifiers: .command)
            }.padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            BrowserSearchField(text: $files.search, placeholder: "搜索当前文件夹")
                .frame(width: 180)
        }.padding(12).background(.bar)
    }

    private var commandBar: some View {
        HStack(spacing: 14) {
            Button {
                files.copySelection(files.selection, kind: .copy)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }.disabled(files.selection.isEmpty || store.isBusy || files.isMutating || files.isLoading)
                .help("复制所选项目 ⌘C")
            Button {
                files.copySelection(files.selection, kind: .move)
            } label: {
                Label("剪切", systemImage: "scissors")
            }.disabled(files.selection.isEmpty || store.isBusy || files.isMutating || files.isLoading)
                .help("剪切所选项目 ⌘X，粘贴完成后移动源文件")
            Button {
                files.paste()
            } label: {
                Label("粘贴", systemImage: "doc.on.clipboard")
            }.disabled(
                !files.clipboard.hasFiles || store.isBusy || files.isMutating || files.isLoading
                    || files.directoryError != nil
            )
            .help("粘贴到当前文件夹 ⌘V")
            Divider().frame(height: 16)
            Button {
                edit = FileNameEdit(directory: files.directory)
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }.disabled(store.isBusy || files.isMutating || files.isLoading || files.directoryError != nil)
            Button {
                store.beginCreate(selectedURLs(files.selection))
            } label: {
                Label("压缩…", systemImage: "archivebox")
            }.disabled(files.selection.isEmpty || store.isBusy || files.isMutating || files.isLoading)
            Button {
                preview(files.selection)
            } label: {
                Label("预览", systemImage: "eye")
            }
            .disabled(previewableURLs(files.selection).isEmpty || files.isLoading || files.isMutating)
            .help("快速查看所选文件（空格键）")
            Menu {
                contextMenu(files.selection)
            } label: {
                Label("操作", systemImage: "ellipsis.circle")
            }
            .disabled(files.isLoading || files.isMutating)
            Spacer(minLength: 0)
            Menu {
                Toggle("显示隐藏文件", isOn: $files.showHidden)
                Button("选择文件夹…") { store.chooseDirectory() }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("浏览选项")
            BrowserViewMenu()
        }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder private func contextMenu(_ ids: Set<String>) -> some View {
        let selected = files.entries.filter { ids.contains($0.id) }
        let urls = selected.compactMap(\.url)
        Button("复制") { files.copySelection(ids, kind: .copy) }
            .disabled(urls.isEmpty || store.isBusy || files.isMutating)
        Button("剪切") { files.copySelection(ids, kind: .move) }
            .disabled(urls.isEmpty || store.isBusy || files.isMutating)
        Button("粘贴到当前文件夹") { files.paste() }
            .disabled(!files.clipboard.hasFiles || store.isBusy || files.isMutating || files.directoryError != nil)
        Divider()
        if let entry = selected.first, selected.count == 1, let url = entry.url {
            Button(entry.isDirectory ? "打开文件夹" : entry.isArchive ? "打开压缩包" : "打开") { open([entry.id]) }
                .disabled(entry.isArchive && store.isBusy)
            if entry.isArchive {
                Button("解压到…") { store.openArchive(url, action: .extract) }.disabled(store.isBusy)
                Button("测试完整性") { store.openArchive(url, action: .test) }.disabled(store.isBusy)
                if ["rz", "rzv", "rzr", "rzm"].contains(url.pathExtension.lowercased()) {
                    Button("修复归档…") { store.openArchive(url, action: .repair) }.disabled(store.isBusy)
                }
                if RARArchive.isRAR(url) {
                    Button("RAR 工具 / 修复…") { store.beginRARTools(url) }.disabled(store.isBusy)
                }
            }
            Divider()
            Button("重命名…") { edit = FileNameEdit(directory: files.directory, target: url) }
                .disabled(store.isBusy || files.isMutating)
        }
        if !selected.isEmpty {
            if !previewableURLs(ids).isEmpty {
                Button("快速查看") { preview(ids) }
                    .disabled(files.isLoading || files.isMutating)
            }
            Button("压缩所选项目…") { store.beginCreate(urls) }.disabled(store.isBusy)
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            Button("复制路径") { copyBrowserPaths(urls.map(\.path)) }
            Divider()
            Button("移到废纸篓", role: .destructive) { files.trash(urls) }
                .disabled(store.isBusy || files.isMutating)
        } else {
            Button("新建文件夹…") { edit = FileNameEdit(directory: files.directory) }
                .disabled(store.isBusy || files.isMutating || files.directoryError != nil)
            Button("在 Finder 中打开当前文件夹") { NSWorkspace.shared.open(files.directory) }
            Button("复制当前路径") { copyBrowserPaths([files.directory.path]) }
            Button("刷新") { files.refresh() }
        }
    }

    private func selectedURLs(_ ids: Set<String>) -> [URL] {
        files.entries.filter { ids.contains($0.id) }.compactMap(\.url)
    }

    private func previewableURLs(_ ids: Set<String>) -> [URL] {
        visibleEntries.filter { ids.contains($0.id) && !$0.isDirectory && !$0.isArchive }.compactMap(\.url)
    }

    @discardableResult
    private func preview(_ ids: Set<String>) -> Bool {
        guard !files.isLoading, !files.isMutating else { return false }
        let urls = previewableURLs(ids)
        guard let first = urls.first else { return false }
        previewURLs = urls
        previewURL = first
        return true
    }

    private func closePreview() {
        previewURL = nil
        previewURLs = []
    }

    private func open(_ ids: Set<String>) {
        guard ids.count == 1, let entry = files.entries.first(where: { ids.contains($0.id) }), let url = entry.url
        else { return }
        if entry.isDirectory {
            store.navigate(to: url)
        } else if entry.isArchive {
            store.openArchive(url)
        } else if !NSWorkspace.shared.open(url) {
            files.errorMessage = "无法打开“\(entry.name)”，请在 Finder 中为它选择可用的应用。"
        }
    }
}

struct BrowserSearchField: View {
    @Binding var text: String
    let placeholder: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(placeholder, text: $text).textFieldStyle(.plain).accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
            }
        }.padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct FileNameEdit: Identifiable {
    let id = UUID()
    let directory: URL
    var target: URL?
}

private struct FileNameSheet: View {
    let edit: FileNameEdit
    @Bindable var files: FileBrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(edit.target == nil ? "新建文件夹" : "重命名").font(.title2.bold())
            Text(edit.directory.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    Task {
                        let success: Bool
                        if let target = edit.target {
                            success = await files.rename(target, to: name)
                        } else {
                            success = await files.createFolder(named: name)
                        }
                        if success { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(files.isMutating)
        }.padding(24).frame(width: 400)
            .onAppear {
                name = edit.target?.lastPathComponent ?? "新建文件夹"
                focused = true
            }
            .alert(
                "无法保存",
                isPresented: Binding(
                    get: { files.errorMessage != nil }, set: { if !$0 { files.errorMessage = nil } }
                )
            ) {
                Button("好") { files.errorMessage = nil }
            } message: {
                Text(files.errorMessage ?? "")
            }
    }
}

#Preview {
    let store = AppStore()
    FileBrowser(store: store, files: store.files)
}

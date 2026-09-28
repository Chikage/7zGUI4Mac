import AppKit
import ArchiveCore
import SwiftUI

struct ContentView: View {
    @Bindable var store: AppStore
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch store.page ?? .home {
                    case .home: HomeView(store: store)
                    case .files: FileBrowser(store: store, files: store.files)
                    case .activity: ActivityView(store: store)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let operation = store.operation {
                    OperationBar(operation: operation, cancel: store.cancel)
                } else {
                    statusBar
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle(
            store.page == .files && store.isBrowsingArchive
                ? (store.listing?.url.lastPathComponent ?? "文件浏览") : "7-Zip for Mac"
        )
        .toolbar { toolbar }
        .frame(minWidth: 850, minHeight: 600)
        .tint(.blue)
        .dropDestination(for: URL.self) { urls, _ in
            store.receive(urls)
        } isTargeted: {
            dropTargeted = $0
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.blue, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $store.showCreate) { CreateArchiveSheet(store: store) }
        .sheet(isPresented: $store.showExtract) { ExtractSheet(store: store) }
        .sheet(isPresented: $store.showRepair) { RepairArchiveSheet(store: store) }
        .sheet(isPresented: $store.showRARTools) { RARToolsSheet(store: store) }
        .sheet(isPresented: $store.showPassword) { PasswordSheet(store: store) }
        .sheet(isPresented: $store.showKeyFile) { RecoveryKeyFileSheet(store: store) }
        .sheet(
            isPresented: Binding(
                get: { store.files.transfer.isPresented }, set: { store.files.transfer.isPresented = $0 }
            )
        ) { FileTransferView(transfer: store.files.transfer) }
        .alert(
            store.errorMessage == nil && store.metadataWarningMessage != nil ? "部分属性未恢复" : "操作未完成",
            isPresented: Binding(
                get: { store.errorMessage != nil || store.metadataWarningMessage != nil },
                set: {
                    if !$0 {
                        store.errorMessage = nil
                        store.metadataWarningMessage = nil
                    }
                })
        ) {
            Button("好") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? store.metadataWarningMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ArchiveMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("7-Zip").font(.title2.weight(.bold))
                    Text("FOR MAC").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
            List(selection: $store.page) {
                Section("资料库") {
                    ForEach(WorkspacePage.allCases) { page in
                        Label(page.title, systemImage: page.symbol).tag(page).padding(.vertical, 5)
                    }
                }
                if store.page == .files {
                    if store.isBrowsingArchive { ArchiveBrowserSidebar(store: store).id(store.listing?.url) }
                    FileBrowserSidebar(store: store)
                }
                if !store.recent.isEmpty {
                    Section("最近打开") {
                        ForEach(store.recent.prefix(5)) { item in
                            Button {
                                store.openArchive(item.url)
                            } label: {
                                Label(item.url.lastPathComponent, systemImage: "doc.zipper")
                                    .lineLimit(1).help(item.path)
                            }.buttonStyle(.plain).disabled(store.isBusy).padding(.vertical, 4)
                        }
                    }
                }
            }.listStyle(.sidebar)
            Spacer(minLength: 16)
            Text(
                "7-Zip 26.03 · GUI \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")"
            )
            .font(.caption2).foregroundStyle(.secondary).padding(20)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.chooseArchive()
            } label: {
                Label("打开", systemImage: "folder")
            }
            .help("打开压缩包 ⌘O").disabled(store.isBusy)
            Button {
                store.beginCreate()
            } label: {
                Label("新建", systemImage: "plus")
            }
            .help("新建压缩包 ⌘N").disabled(store.isBusy)
            Menu {
                Button("RAR 工具…") { store.beginRARTools() }
            } label: {
                Label("工具", systemImage: "wrench.and.screwdriver")
            }.disabled(store.isBusy)
            if store.page == .files && store.isBrowsingArchive {
                Divider()
                Button {
                    store.testArchive()
                } label: {
                    Label("测试", systemImage: "checkmark.shield")
                }
                .disabled(store.listing == nil || store.isBusy)
                if store.listing?.supportsRecovery == true {
                    Button {
                        store.requestRepair()
                    } label: {
                        Label("修复归档", systemImage: "bandage")
                    }.disabled(store.isBusy)
                }
                Button {
                    store.requestExtract()
                } label: {
                    Label("解压到…", systemImage: "arrow.up.bin")
                }
                .disabled(store.listing == nil || store.isBusy)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: store.notice == nil ? "checkmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(store.notice == nil ? Color.secondary : Color.green)
            Text(store.notice ?? "准备就绪").lineLimit(1)
            Spacer()
            if let output = store.lastOutput {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([output]) }.buttonStyle(.link)
                if !output.hasDirectoryPath || output.pathExtension.lowercased() == "rz" {
                    Button("打开归档") { store.openArchive(output) }.buttonStyle(.link)
                }
            } else {
                Text("本地处理").foregroundStyle(.secondary)
            }
        }
        .font(.caption).padding(.horizontal, 24).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct ArchiveMark: View {
    var size: CGFloat = 64
    var body: some View {
        Image(systemName: "shippingbox.fill")
            .resizable().scaledToFit().foregroundStyle(.white)
            .padding(size * 0.23).frame(width: size, height: size)
            .background(.blue.gradient, in: RoundedRectangle(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}

#Preview { ContentView(store: AppStore(defaults: UserDefaults(suiteName: "SevenZipPreview") ?? .standard)) }

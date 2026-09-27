import AppKit
import SwiftUI

@main
struct SevenZipMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()

    var body: some Scene {
        Window("7-Zip for Mac", id: "main") {
            ContentView(store: store)
                .onAppear { delegate.store = store }
                .onOpenURL { url in
                    if store.isBusy { store.errorMessage = "请等待当前操作完成后再打开文件。" } else { _ = store.receive([url]) }
                }
        }
        .defaultSize(width: 1100, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建压缩包…") { store.beginCreate() }.keyboardShortcut("n").disabled(store.isBusy)
                Button("打开压缩包…") { store.chooseArchive() }.keyboardShortcut("o").disabled(store.isBusy)
                Button("浏览文件夹…") {
                    store.chooseDirectory()
                }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!store.canNavigateBrowser)
            }
            CommandMenu("浏览") {
                Button("文件浏览") { store.page = .files }.keyboardShortcut("1", modifiers: .command)
                Button("返回压缩包所在文件夹") { store.showArchiveParent() }
                    .disabled(!store.isBrowsingArchive || !store.canNavigateBrowser)
            }
            CommandMenu("归档") {
                Button("解压到…") { store.requestExtract() }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.listing == nil || store.isBusy)
                Button("测试完整性") { store.testArchive() }.keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(store.listing == nil || store.isBusy)
                Button("修复归档…") { store.requestRepair() }
                    .disabled(store.listing?.supportsRecovery != true || store.isBusy)
                Divider()
                Button("在 Finder 中显示") {
                    if let url = store.listing?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }.disabled(store.listing == nil)
            }
            CommandGroup(replacing: .help) {
                Button("7-Zip for Mac 使用说明") {
                    if let url = Bundle.main.url(forResource: "使用说明", withExtension: "md") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("开源许可证") {
                    if let url = Bundle.main.url(forResource: "7zip-License", withExtension: "txt") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = store.files.transfer.isRunning ? "正在传输文件" : "正在处理归档"
        alert.informativeText = "退出将取消当前操作，并清理未完成的临时文件。"
        alert.addButton(withTitle: "继续处理")
        alert.addButton(withTitle: "取消操作并退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        store.cancel()
        Task {
            while store.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

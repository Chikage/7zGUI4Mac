import AppKit
import ArchiveCore
import Observation
import SwiftUI

enum WorkspacePage: String, CaseIterable, Identifiable {
    case home, files, activity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "工作台"
        case .files: "文件浏览"
        case .activity: "操作记录"
        }
    }
    var symbol: String {
        switch self {
        case .home: "square.grid.2x2"
        case .files: "folder"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

struct RecentArchive: Codable, Identifiable {
    var id: String { path }
    let path: String
    let date: Date
    var url: URL { URL(fileURLWithPath: path) }
}

struct ActivityItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let date = Date()
    let success: Bool
    let output: URL?
}

struct OperationState {
    let id = UUID()
    let startedAt = Date()
    let title: String
    var detail: String
    var fraction: Double?
    var cancelling = false
    var showsCompression = false
    var compression: CompressionMetrics?
    var showsProcessing = false
    var processing: ProcessingMetrics?
    var lastProgressAt: ContinuousClock.Instant?

    mutating func apply(_ progress: EngineProgress) {
        guard !cancelling, lastProgressAt.map({ progress.timestamp >= $0 }) ?? true else { return }
        lastProgressAt = progress.timestamp
        fraction = progress.fraction
        detail = progress.message
        if let metrics = progress.compression { compression = metrics }
        if let metrics = progress.processing { processing = metrics }
    }
}

enum ArchiveOpenAction {
    case browse, extract, test, repair
}

enum BrowserLocation: Equatable, Sendable {
    case directory(URL)
    case archive(URL, folder: String)
}

enum PasswordAction {
    case open(URL, ArchiveOpenAction, BrowserHistory<BrowserLocation>?)
    case test, extract
}

@MainActor @Observable
final class AppStore {
    var page: WorkspacePage? = .home
    var listing: ArchiveListing?
    var archiveIndex = ArchiveDirectoryIndex(entries: [])
    var browserHistory = BrowserHistory(BrowserLocation.directory(FileManager.default.homeDirectoryForCurrentUser))
    let files = FileBrowserStore()
    var search = ""
    var folder = ""
    var selection: Set<String> = []
    var recent: [RecentArchive] = []
    var activity: [ActivityItem] = []
    var operation: OperationState?
    var errorMessage: String?
    var metadataWarningMessage: String?
    var notice: String?
    var lastOutput: URL?
    var showCreate = false
    var showExtract = false
    var showRepair = false
    var showPassword = false
    var passwordError: String?
    var createSources: [URL] = []
    var archivePassword = ""
    var archiveKeyFile: URL?
    var showKeyFile = false
    var keyFileError: String?
    var passwordAction: PasswordAction?
    private var task: Task<Void, Never>?
    private let service: ArchiveService
    private let defaults: UserDefaults
    var isBusy: Bool { operation != nil }
    var isBrowsingArchive: Bool {
        if case .archive = browserHistory.current { return true }
        return false
    }
    var canNavigateBrowser: Bool { !isBusy && !files.isLoading && !files.isMutating }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let executable =
            Bundle.main.url(forAuxiliaryExecutable: "7zz")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor/7zip/7zz")
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let recoveryExecutable =
            Bundle.main.url(forAuxiliaryExecutable: "rz")
            ?? workingDirectory.appendingPathComponent("build/recovery/rz")
        service = ArchiveService(executable: executable, recoveryExecutable: recoveryExecutable)
        if let data = defaults.data(forKey: "recentArchives"),
            let saved = try? JSONDecoder().decode([RecentArchive].self, from: data)
        {
            recent = saved
        }
    }

    func supportsRecoveryAES() async throws -> Bool { try await service.supportsRecoveryAES() }

    func chooseArchive() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "打开压缩包"
        panel.message = "选择压缩包、可恢复 RZ 归档包，或其中任意分卷。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { openArchive(url) }
    }

    func beginCreate(_ urls: [URL] = []) {
        guard !isBusy else { return }
        createSources = urls
        showCreate = true
    }

    func receive(_ urls: [URL]) -> Bool {
        guard !isBusy, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        if urls.count == 1, let url = urls.first,
            RecoveryArchive.directory(for: url) != nil
                || ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                    && BrowserEntry.isArchiveName(url.lastPathComponent))
        {
            openArchive(url)
        } else {
            beginCreate(urls)
        }
        return true
    }

    func openArchive(
        _ url: URL, password: String = "", keyFile: URL? = nil, action: ArchiveOpenAction = .browse,
        history: BrowserHistory<BrowserLocation>? = nil
    ) {
        guard canNavigateBrowser else { return }
        start("打开归档", detail: url.lastPathComponent) { [self] in
            let result = try await service.list(url, password: password, keyFile: keyFile)
            listing = result
            archiveIndex = ArchiveDirectoryIndex(entries: result.entries)
            archivePassword = password
            archiveKeyFile = keyFile
            search = ""
            folder = ""
            selection = []
            if let history {
                browserHistory = history
                if case .archive(_, let path) = history.current { folder = path }
            } else {
                // An archive opened from Finder or Recents still has a local parent to return to.
                if !isBrowsingArchive {
                    browserHistory.visit(.directory(result.url.deletingLastPathComponent().standardizedFileURL))
                }
                browserHistory.visit(.archive(result.url, folder: ""))
            }
            page = .files
            remember(result.url)
            NSDocumentController.shared.noteNewRecentDocumentURL(result.url)
            return nil
        } onPassword: { [self] in
            passwordError = password.isEmpty ? nil : "密码未通过验证，请重试。"
            passwordAction = .open(url, action, history)
            showPassword = true
        } onKeyFile: { [self] in
            keyFileError = ArchiveError.keyFileRequired.localizedDescription
            passwordAction = .open(url, action, history)
            showKeyFile = true
        } onSuccess: { [self] in
            if listing?.directoryUnavailable == true {
                if case .repair = action { requestRepair() }
                return
            }
            if listing?.isLocked == true {
                if case .repair = action { requestRepair() } else { requestUnlock(action: action) }
                return
            }
            switch action {
            case .browse: break
            case .extract: requestExtract()
            case .test: testArchive()
            case .repair: requestRepair()
            }
        }
    }

    func requestUnlock(action: ArchiveOpenAction = .browse) {
        guard !isBusy, let listing else { return }
        passwordError = nil
        passwordAction = .open(listing.url, action, browserHistory)
        if listing.requiresKeyFile {
            keyFileError = nil
            showKeyFile = true
        } else {
            showPassword = true
        }
    }

    func createArchive(to url: URL, options: CompressionOptions) {
        guard !isBusy else { return }
        let sources = createSources
        showCreate = false
        start("创建压缩包", detail: url.lastPathComponent, showsCompression: true) { [self] in
            let output = try await service.compress(sources, to: url, options: options, progress: progressHandler())
            remember(output)
            createSources = []
            return output
        } onSuccess: { [self] in
            if options.generateRecoveryKeyFile {
                notice = "归档与 \(RecoveryArchive.keyFileURL(for: url).lastPathComponent) 已生成。请备份密钥；需要保密时分开存放。"
            }
        }
    }

    func requestExtract() {
        guard !isBusy, let listing else { return }
        guard !listing.directoryUnavailable else {
            errorMessage = ArchiveError.recoveryRepairable.localizedDescription
            return
        }
        if listing.requiresKeyFile {
            if listing.isLocked { requestUnlock(action: .extract) } else { showExtract = true }
        } else if listing.isEncrypted && archivePassword.isEmpty {
            passwordError = nil
            passwordAction = .extract
            showPassword = true
        } else {
            showExtract = true
        }
    }

    func extract(to url: URL, reveal: Bool, restoreAttributes: Bool = true) {
        guard !isBusy, let listing else { return }
        showExtract = false
        let password = archivePassword
        let keyFile = archiveKeyFile
        start("解压归档", detail: listing.url.lastPathComponent, showsProcessing: true) { [self] in
            let result = try await service.extract(
                listing.url, to: url, password: password, keyFile: keyFile, restoreAttributes: restoreAttributes,
                progress: progressHandler())
            if result.metadataWarningCount > 0 {
                let details = result.metadataWarnings.prefix(6).map { String($0.prefix(280)) }.joined(separator: "\n")
                let more = result.metadataWarningCount > 6 ? "\n另有 \(result.metadataWarningCount - 6) 项属性问题。" : ""
                metadataWarningMessage = "文件内容已成功解压，共有 \(result.metadataWarningCount) 项属性未完整恢复。\n\n\(details)\(more)"
            }
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
            return result.url
        } onPassword: { [self] in
            archivePassword = ""
            passwordError = "密码未通过验证，请重试。"
            passwordAction = .extract
            showPassword = true
        } onKeyFile: { [self] in
            archiveKeyFile = nil
            keyFileError = ArchiveError.keyFileRequired.localizedDescription
            passwordAction = .extract
            showKeyFile = true
        }
    }

    func testArchive() {
        guard !isBusy, let listing else { return }
        if listing.requiresKeyFile && listing.isLocked {
            requestUnlock(action: .test)
            return
        }
        if listing.isEncrypted && !listing.requiresKeyFile && archivePassword.isEmpty {
            passwordError = nil
            passwordAction = .test
            showPassword = true
            return
        }
        let password = archivePassword
        let keyFile = archiveKeyFile
        start("完整性测试", detail: listing.url.lastPathComponent, showsProcessing: true) { [self] in
            try await service.test(listing.url, password: password, keyFile: keyFile, progress: progressHandler())
            return nil
        } onPassword: { [self] in
            archivePassword = ""
            passwordError = "密码未通过验证，请重试。"
            passwordAction = .test
            showPassword = true
        } onKeyFile: { [self] in
            archiveKeyFile = nil
            keyFileError = ArchiveError.keyFileRequired.localizedDescription
            passwordAction = .test
            showKeyFile = true
        }
    }

    func requestRepair() {
        guard !isBusy, listing?.supportsRecovery == true else { return }
        showRepair = true
    }

    func repair(to url: URL) {
        guard !isBusy, let listing, listing.supportsRecovery else { return }
        showRepair = false
        start("修复归档", detail: listing.url.lastPathComponent) { [self] in
            let output = try await service.repair(listing.url, to: url, progress: progressHandler())
            remember(output)
            return output
        } onSuccess: { [self] in
            if listing.isEncrypted {
                notice = "密文重建完成，存储校验通过；尚未完成加密认证。解锁后可测试全部内容。"
            }
        }
    }

    func submitPassword(_ password: String) {
        showPassword = false
        let action = passwordAction
        passwordAction = nil
        switch action {
        case .open(let url, let action, let history):
            openArchive(url, password: password, action: action, history: history)
        case .test:
            archivePassword = password
            testArchive()
        case .extract:
            archivePassword = password
            showExtract = true
        case nil: break
        }
    }
    func submitKeyFile(_ keyFile: URL) {
        showKeyFile = false
        let action = passwordAction
        passwordAction = nil
        switch action {
        case .open(let url, let action, let history):
            openArchive(url, keyFile: keyFile, action: action, history: history)
        case .test, .extract:
            guard let listing else { return }
            let next: ArchiveOpenAction = if case .test = action { .test } else { .extract }
            openArchive(listing.url, keyFile: keyFile, action: next, history: browserHistory)
        case nil: break
        }
    }

    func cancel() {
        operation?.cancelling = true
        operation?.detail = "正在取消并清理临时文件…"
        task?.cancel()
    }

    func clearRecent() {
        recent = []
        defaults.removeObject(forKey: "recentArchives")
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    func navigate(to path: String) {
        guard canNavigateBrowser, let listing else { return }
        var next = browserHistory
        next.visit(.archive(listing.url, folder: path))
        restoreBrowserLocation(next)
    }

    func navigate(to url: URL) {
        var next = browserHistory
        next.visit(.directory(url.standardizedFileURL))
        restoreBrowserLocation(next)
    }

    func browserBack() {
        var next = browserHistory
        next.goBack()
        restoreBrowserLocation(next)
    }

    func browserForward() {
        var next = browserHistory
        next.goForward()
        restoreBrowserLocation(next)
    }

    func browserUp() {
        if isBrowsingArchive {
            if folder.isEmpty {
                showArchiveParent()
            } else {
                navigate(to: folder.split(separator: "/").dropLast().joined(separator: "/"))
            }
        } else {
            navigate(to: files.directory.deletingLastPathComponent())
        }
    }

    func showArchiveParent() {
        guard let listing else { return }
        navigate(to: listing.url.deletingLastPathComponent())
    }

    func chooseDirectory() {
        guard canNavigateBrowser else { return }
        let panel = NSOpenPanel()
        panel.title = "浏览文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = isBrowsingArchive ? listing?.url.deletingLastPathComponent() : files.directory
        if panel.runModal() == .OK, let url = panel.url { navigate(to: url) }
    }

    private func restoreBrowserLocation(_ next: BrowserHistory<BrowserLocation>) {
        guard canNavigateBrowser else { return }
        switch next.current {
        case .directory(let url):
            let archiveURL = isBrowsingArchive ? listing?.url : nil
            // Mark loading before scheduling work so rapid clicks cannot race history updates.
            files.isLoading = true
            Task {
                guard await files.navigate(to: url) else {
                    if isBrowsingArchive, let error = files.directoryError { files.errorMessage = error }
                    return
                }
                browserHistory = next
                page = .files
                if let archiveURL, archiveURL.deletingLastPathComponent().standardizedFileURL == url.standardizedFileURL
                {
                    files.selection = Set(files.entries.filter { $0.name == archiveURL.lastPathComponent }.map(\.id))
                }
            }
        case .archive(let url, let path):
            if listing?.url == url {
                browserHistory = next
                folder = path
                selection = []
                search = ""
                page = .files
            } else {
                openArchive(url, history: next)
            }
        }
    }

    private func start(
        _ title: String, detail: String, showsCompression: Bool = false, showsProcessing: Bool = false,
        action: @escaping @MainActor () async throws -> URL?,
        onPassword: (@MainActor () -> Void)? = nil,
        onKeyFile: (@MainActor () -> Void)? = nil,
        onSuccess: (@MainActor () -> Void)? = nil
    ) {
        operation = OperationState(
            title: title, detail: detail, showsCompression: showsCompression, showsProcessing: showsProcessing)
        notice = nil
        metadataWarningMessage = nil
        lastOutput = nil
        task = Task { [self] in
            var succeeded = false
            do {
                let output = try await action()
                succeeded = true
                notice = title == "完整性测试" ? "完整性测试通过，归档中的文件数据完整。" : "\(title)完成"
                if metadataWarningMessage != nil { notice = "解压完成，部分属性未恢复" }
                lastOutput = output
                if output != nil { files.refresh() }
                if title != "打开归档" {
                    activity.insert(
                        ActivityItem(
                            title: title, detail: metadataWarningMessage ?? detail, success: true, output: output),
                        at: 0)
                }
            } catch is CancellationError {
                notice = "操作已取消"
                activity.insert(
                    ActivityItem(title: title, detail: "已取消 · \(detail)", success: false, output: nil), at: 0)
            } catch ArchiveError.keyFileRequired {
                if let onKeyFile {
                    onKeyFile()
                } else {
                    errorMessage = ArchiveError.keyFileRequired.localizedDescription
                }
            } catch ArchiveError.passwordRequired {
                if let onPassword {
                    onPassword()
                } else {
                    errorMessage = ArchiveError.passwordRequired.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
                activity.insert(
                    ActivityItem(title: title, detail: error.localizedDescription, success: false, output: nil), at: 0)
            }
            if activity.count > 100 { activity = Array(activity.prefix(100)) }
            operation = nil
            task = nil
            if succeeded { onSuccess?() }
        }
    }

    private func progressHandler() -> @Sendable (EngineProgress) -> Void {
        let operationID = operation?.id
        return { [weak self] progress in
            Task { @MainActor in
                guard let self, self.operation?.id == operationID else { return }
                self.operation?.apply(progress)
            }
        }
    }

    private func remember(_ url: URL) {
        recent.removeAll { $0.path == url.path }
        recent.insert(RecentArchive(path: url.path, date: Date()), at: 0)
        recent = Array(recent.prefix(12))
        if let data = try? JSONEncoder().encode(recent) { defaults.set(data, forKey: "recentArchives") }
    }
}

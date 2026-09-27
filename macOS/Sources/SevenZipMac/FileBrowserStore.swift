import AppKit
import ArchiveCore
import Observation

@MainActor @Observable
final class FileBrowserStore {
    private(set) var directory = FileManager.default.homeDirectoryForCurrentUser
    var entries: [BrowserEntry] = []
    var selection: Set<String> = []
    var search = ""
    var showHidden = false
    var isLoading = false
    var isMutating = false
    var errorMessage: String?
    var directoryError: String?
    var treeChildren: [String: [BrowserEntry]] = [:]
    var treeErrors: [String: String] = [:]
    var expanded: Set<String> = []
    private var loadingTree: Set<String> = []
    private var generation = 0
    private var treeGeneration = 0
    private let service = FileBrowserService()

    var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    var canGoUp: Bool { directory.path != "/" }

    func loadIfNeeded() async {
        guard entries.isEmpty, !isLoading else { return }
        await load(directory)
    }

    func navigate(to url: URL) async -> Bool {
        await load(url.standardizedFileURL)
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        treeGeneration += 1
        treeChildren = [:]
        treeErrors = [:]
        loadingTree = []
        let paths = expanded
        Task {
            await load(directory, preserveSelection: true)
            for path in paths { await loadChildren(URL(fileURLWithPath: path)) }
        }
    }

    func setExpanded(_ url: URL, _ value: Bool) {
        if value {
            expanded.insert(url.path)
            Task { await loadChildren(url) }
        } else {
            expanded.remove(url.path)
        }
    }

    func loadChildren(_ url: URL) async {
        let path = url.path
        guard treeChildren[path] == nil, !loadingTree.contains(path) else { return }
        let request = treeGeneration
        loadingTree.insert(path)
        treeErrors[path] = nil
        do {
            let children = try await service.contents(of: url, showHidden: showHidden)
            guard request == treeGeneration else { return }
            treeChildren[path] = children.filter(\.isDirectory)
        } catch {
            guard request == treeGeneration else { return }
            treeErrors[path] = error.localizedDescription
        }
        loadingTree.remove(path)
    }

    func createFolder(named name: String) async -> Bool {
        await mutate { [self] in try await service.createFolder(in: directory, name: name) }
    }

    func rename(_ url: URL, to name: String) async -> Bool {
        await mutate { [self] in try await service.rename(url, to: name) }
    }

    func trash(_ urls: [URL]) {
        Task {
            _ = await mutate { [self] in
                try await service.trash(urls)
                return nil
            }
        }
    }

    private func mutate(_ action: () async throws -> URL?) async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            let result = try await action()
            await load(directory, preserveSelection: true)
            if let result { selection = [result.path] }
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            refresh()  // A multi-file operation may have succeeded for some of the items.
            return false
        }
    }

    @discardableResult
    private func load(_ url: URL, preserveSelection: Bool = false) async -> Bool {
        generation += 1
        let request = generation
        isLoading = true
        directoryError = nil
        defer { if request == generation { isLoading = false } }
        do {
            let result = try await service.contents(of: url, showHidden: showHidden)
            guard request == generation else { return false }
            directory = url
            entries = result
            selection = preserveSelection ? selection.intersection(Set(result.map(\.id))) : []
            if !preserveSelection { search = "" }
            treeChildren[directory.path] = result.filter(\.isDirectory)
            expanded.insert(directory.path)
            var parent = directory
            while parent.path != "/", parent.path != home.path, parent.path != "/Volumes" {
                parent = parent.deletingLastPathComponent()
                if parent.path != "/" { expanded.insert(parent.path) }
            }
            return true
        } catch {
            guard request == generation else { return false }
            if url == directory {
                entries = []
                selection = []
                directoryError = error.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }
}

import ArchiveCore
import Foundation
import Observation

@MainActor @Observable
final class MTPBrowserStore {
    private(set) var devices: [MTPDevice] = []
    private(set) var directory: MTPDirectory?
    private(set) var entries: [MTPEntry] = []
    private(set) var isScanning = false
    private(set) var isLoading = false
    private(set) var isDownloading = false
    private(set) var hasScanned = false
    var selection: Set<String> = []
    var search = ""
    var showHidden = false
    var scanError: String?
    var directoryError: String?
    var errorMessage: String?
    private var task: Task<Void, Never>?
    private let service: any MTPBrowsing
    var isWorking: Bool { isScanning || isLoading || isDownloading }
    var visibleEntries: [BrowserEntry] {
        entries.filter {
            (showHidden || !$0.name.hasPrefix("."))
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }.map(\.browserEntry)
    }

    init(service: (any MTPBrowsing)? = nil) {
        self.service =
            service
            ?? MTPService(
                executable: Bundle.main.url(forAuxiliaryExecutable: "mtp-browser")
                    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("build/mtp/mtp-browser"))
    }

    func scanIfNeeded() { if !hasScanned { scan() } }

    func scan() {
        guard !isWorking else { return }
        isScanning = true
        hasScanned = true
        scanError = nil
        task = Task {
            defer {
                isScanning = false
                task = nil
            }
            do {
                let found = try await service.devices()
                try Task.checkCancellation()
                devices = found
                if let directory, !found.contains(where: { $0.id == directory.device.id }) {
                    entries = []
                    selection = []
                    directoryError = "设备已断开。重新连接后，请从左侧重新选择设备。"
                }
            } catch is CancellationError {
                // Keep the last scan result when the user cancels.
            } catch {
                devices = []
                scanError = error.localizedDescription
            }
        }
    }

    func navigate(to location: MTPDirectory, didNavigate: @escaping @MainActor () -> Void) {
        guard !isWorking else { return }
        isLoading = true
        task = Task {
            defer {
                isLoading = false
                task = nil
            }
            if await load(location, preserveSelection: false) { didNavigate() }
        }
    }

    func refresh() {
        guard !isWorking, let directory else { return }
        isLoading = true
        task = Task {
            defer {
                isLoading = false
                task = nil
            }
            _ = await load(directory, preserveSelection: true)
        }
    }

    func download(_ entry: MTPEntry, completion: @escaping @MainActor (URL) -> Void) {
        guard !isWorking, !entry.isDirectory, let directory,
            entries.contains(entry), directoryError == nil
        else { return }
        isDownloading = true
        task = Task {
            var downloaded: URL?
            do {
                downloaded = try await service.download(entry, from: directory.device)
                try Task.checkCancellation()
            } catch is CancellationError {
                downloaded = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isDownloading = false
            task = nil
            if let downloaded { completion(downloaded) }
        }
    }

    func cancel() { task?.cancel() }

    private func load(_ location: MTPDirectory, preserveSelection: Bool) async -> Bool {
        do {
            let result = try await service.contents(of: location)
            try Task.checkCancellation()
            directory = location
            entries = result
            directoryError = nil
            errorMessage = nil
            selection = preserveSelection ? selection.intersection(Set(result.map(\.id))) : []
            if !preserveSelection { search = "" }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if directory == location {
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

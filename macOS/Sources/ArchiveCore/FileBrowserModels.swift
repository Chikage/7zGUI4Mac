import Foundation

public struct BrowserEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDirectory: Bool
    public let isArchive: Bool
    public let isLink: Bool
    public let isEncrypted: Bool
    public let size: Int64
    public let modified: String
    public let url: URL?

    public var kind: String {
        if isDirectory { return "文件夹" }
        if isArchive { return "压缩文件" }
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "文件" : "\(ext) 文件"
    }

    public init(
        id: String, name: String, isDirectory: Bool, isArchive: Bool = false,
        isLink: Bool = false, isEncrypted: Bool = false, size: Int64 = 0,
        modified: String = "", url: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.isArchive = isArchive
        self.isLink = isLink
        self.isEncrypted = isEncrypted
        self.size = size
        self.modified = modified
        self.url = url
    }

    public init(archiveEntry: ArchiveEntry) {
        self.init(
            id: archiveEntry.path, name: archiveEntry.name, isDirectory: archiveEntry.isDirectory,
            isArchive: !archiveEntry.isDirectory && Self.isArchiveName(archiveEntry.name),
            isLink: archiveEntry.isLink, isEncrypted: archiveEntry.isEncrypted,
            size: archiveEntry.size, modified: archiveEntry.modified)
    }

    public static func isArchiveName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["7z", "zip", "rar", "tar", "gz", "bz2", "xz", "tgz", "tbz", "tbz2", "txz",
                "iso", "cab", "wim", "zst", "zstd", "lzma", "001", "rz", "rzv", "rzr", "rzm", "rev"].contains(ext)
            || ext.range(of: #"^r\d{2}$"#, options: .regularExpression) != nil
    }
}

/// Builds implicit parent folders once, so tree expansion does not rescan an entire archive.
public struct ArchiveDirectoryIndex: Sendable {
    private var children: [String: [BrowserEntry]] = [:]
    private var all: [BrowserEntry] = []

    public init(entries: [ArchiveEntry]) {
        var indexed: [String: BrowserEntry] = [:]
        for entry in entries {
            // Malformed paths may still be visible in search, but must not form cyclic trees.
            guard (try? ArchivePath.validate(entry.path)) != nil else { continue }
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty, !components.contains(".") else { continue }
            for depth in 1..<components.count {
                let path = components.prefix(depth).joined(separator: "/")
                if indexed[path] == nil {
                    indexed[path] = BrowserEntry(id: path, name: components[depth - 1], isDirectory: true)
                }
            }
            let path = components.joined(separator: "/")
            indexed[path] = BrowserEntry(
                id: path, name: entry.name, isDirectory: entry.isDirectory,
                isArchive: !entry.isDirectory && BrowserEntry.isArchiveName(entry.name),
                isLink: entry.isLink, isEncrypted: entry.isEncrypted, size: entry.size, modified: entry.modified)
        }
        all = entries.map { BrowserEntry(archiveEntry: $0) }
        for entry in indexed.values {
            let parent = entry.id.split(separator: "/").dropLast().joined(separator: "/")
            children[parent, default: []].append(entry)
        }
        for path in Array(children.keys) {
            children[path]?.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public func entries(in folder: String, search: String = "") -> [BrowserEntry] {
        search.isEmpty ? children[folder, default: []] : all.filter { $0.id.localizedCaseInsensitiveContains(search) }
    }

    public func folders(in folder: String) -> [BrowserEntry] {
        children[folder, default: []].filter(\.isDirectory)
    }
}

public struct BrowserHistory<Location: Equatable & Sendable>: Sendable {
    public private(set) var current: Location
    public private(set) var back: [Location] = []
    public private(set) var forward: [Location] = []

    public init(_ location: Location) { current = location }

    public mutating func visit(_ location: Location) {
        guard location != current else { return }
        back.append(current)
        if back.count > 100 { back.removeFirst() }
        current = location
        forward = []
    }

    public mutating func goBack() {
        guard let location = back.popLast() else { return }
        forward.append(current)
        current = location
    }

    public mutating func goForward() {
        guard let location = forward.popLast() else { return }
        back.append(current)
        current = location
    }
}

public actor FileBrowserService {
    public init() {}

    public func contents(of directory: URL, showHidden: Bool) throws -> [BrowserEntry] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: showHidden ? [] : [.skipsHiddenFiles])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return try urls.map { url in
            let values = try url.resourceValues(forKeys: keys)
            let archive = BrowserEntry.isArchiveName(url.lastPathComponent)
                && (values.isDirectory != true || url.pathExtension.lowercased() == "rz")
            return BrowserEntry(
                id: url.path, name: url.lastPathComponent,
                isDirectory: values.isDirectory == true && values.isPackage != true && !archive,
                isArchive: archive, isLink: values.isSymbolicLink == true,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate.map { formatter.string(from: $0) } ?? "", url: url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func createFolder(in directory: URL, name: String) throws -> URL {
        let url = try destination(in: directory, name: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    public func rename(_ url: URL, to name: String) throws -> URL {
        try Self.validateName(name)
        if name == url.lastPathComponent { return url }
        let target = try destination(in: url.deletingLastPathComponent(), name: name)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    public func trash(_ urls: [URL]) throws {
        for url in urls { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    private func destination(in directory: URL, name: String) throws -> URL {
        try Self.validateName(name)
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path),
              (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
            throw ArchiveError.invalidInput("此位置已存在同名项目，请换一个名称。")
        }
        return url
    }

    private static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ArchiveError.invalidInput("请输入有效的名称，不要包含斜杠、冒号或控制字符。")
        }
    }
}

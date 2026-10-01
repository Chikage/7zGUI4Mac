import Foundation

public struct MTPDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct MTPEntry: Codable, Equatable, Identifiable, Sendable {
    public let objectID: UInt32
    public let storageID: UInt32
    public let name: String
    public let isDirectory: Bool
    public let isStorage: Bool
    public let size: UInt64
    public let modified: Int64
    public var id: String { "\(storageID):\(isStorage ? "storage" : String(objectID))" }

    public init(
        objectID: UInt32, storageID: UInt32, name: String, isDirectory: Bool,
        isStorage: Bool = false, size: UInt64 = 0, modified: Int64 = 0
    ) {
        self.objectID = objectID
        self.storageID = storageID
        self.name = name
        self.isDirectory = isDirectory
        self.isStorage = isStorage
        self.size = size
        self.modified = modified
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public var browserEntry: BrowserEntry {
        return BrowserEntry(
            id: id, name: name, isDirectory: isDirectory,
            isArchive: !isDirectory && BrowserEntry.isArchiveName(name),
            size: Int64(clamping: size),
            modified: modified > 0
                ? Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(modified))) : "")
    }
}

/// Object handles are device-scoped, never local filesystem paths. The first
/// breadcrumb is a storage volume; subsequent breadcrumbs are folders.
public struct MTPDirectory: Equatable, Sendable {
    public let device: MTPDevice
    public private(set) var trail: [MTPEntry] = []
    public init(device: MTPDevice) { self.device = device }
    public var storageID: UInt32 { trail.first?.storageID ?? 0 }
    public var parentID: UInt32 { trail.last?.objectID ?? .max }
    public var title: String { trail.last?.name ?? device.name }
    public var displayPath: String { ([device.name] + trail.map(\.name)).joined(separator: " / ") }
    public var parent: Self? {
        guard !trail.isEmpty else { return nil }
        var copy = self
        copy.trail.removeLast()
        return copy
    }

    public func appending(_ entry: MTPEntry) -> Self? {
        guard entry.isDirectory, entry.storageID != 0,
            entry.isStorage == trail.isEmpty,
            trail.isEmpty || entry.storageID == storageID,
            !trail.contains(where: { $0.id == entry.id })
        else { return nil }
        var copy = self
        copy.trail.append(entry)
        return copy
    }
}

public enum MTPError: Error, LocalizedError {
    case helperMissing, connection, read, changed, invalidResponse, invalidName, timeout, localWrite

    public var errorDescription: String? {
        switch self {
        case .helperMissing: "缺少 MTP 组件。请使用完整打包的应用，或先运行 Scripts/build_mtp_engine.sh。"
        case .connection: "无法连接 MTP 设备。请重新连接 USB、解锁设备并选择“文件传输 / MTP”，关闭其他占用设备的传输软件后重试。"
        case .read: "无法读取 MTP 内容。设备可能已断开、锁定或拒绝访问，请解锁并刷新设备。"
        case .changed: "设备上的存储空间、文件或文件夹已变化。请刷新目录后重试。"
        case .invalidResponse: "MTP 组件返回了无效目录，未显示不完整的内容。请刷新后重试。"
        case .invalidName: "此设备文件的名称无法安全保存到 Mac。"
        case .timeout: "MTP 设备响应超时。请检查连接、解锁设备，并关闭其他传输软件后重试。"
        case .localWrite: "无法保存 MTP 文件的本地副本，请检查磁盘空间和临时目录权限。"
        }
    }
}

public protocol MTPBrowsing: Sendable {
    func devices() async throws -> [MTPDevice]
    func contents(of directory: MTPDirectory) async throws -> [MTPEntry]
    func download(_ entry: MTPEntry, from device: MTPDevice) async throws -> URL
}

public actor MTPService: MTPBrowsing {
    private let executable: URL
    private let temporaryDirectory: URL

    public init(executable: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.executable = executable
        self.temporaryDirectory = temporaryDirectory
    }

    public func devices() async throws -> [MTPDevice] {
        struct Response: Decodable { let devices: [MTPDevice] }
        let response: Response = try decode(await request(["devices"]))
        guard Set(response.devices.map(\.id)).count == response.devices.count,
            response.devices.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty })
        else {
            throw MTPError.invalidResponse
        }
        return response.devices
    }

    public func contents(of directory: MTPDirectory) async throws -> [MTPEntry] {
        struct Response: Decodable { let entries: [MTPEntry] }
        let response: Response = try decode(
            await request([
                "list", directory.device.id, String(directory.storageID), String(directory.parentID),
            ]))
        guard Set(response.entries.map(\.id)).count == response.entries.count,
            response.entries.allSatisfy({ entry in
                entry.storageID != 0 && !entry.name.isEmpty
                    && entry.isStorage == directory.trail.isEmpty
                    && (!entry.isStorage || (entry.isDirectory && entry.objectID == .max))
                    && (directory.trail.isEmpty || entry.storageID == directory.storageID)
            })
        else { throw MTPError.invalidResponse }
        return response.entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func download(_ entry: MTPEntry, from device: MTPDevice) async throws -> URL {
        try Task.checkCancellation()
        guard !entry.isDirectory, !entry.isStorage, entry.size <= UInt64(Int64.max) else { throw MTPError.changed }
        try Self.validateDownloadName(entry.name)
        let folder = temporaryDirectory.appendingPathComponent("SevenZipMTP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: folder) } }
        let partial = folder.appendingPathComponent(".download")
        _ = try await request(
            [
                "download", device.id, String(entry.storageID), String(entry.objectID), entry.name,
                String(entry.size), String(entry.modified), partial.path,
            ], timeout: .seconds(3600))
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: partial.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.size] as? NSNumber)?.uint64Value == entry.size
        else { throw MTPError.read }
        let target = folder.appendingPathComponent(entry.name)
        if target != partial { try FileManager.default.moveItem(at: partial, to: target) }
        complete = true
        return target
    }

    public static func validateDownloadName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            name != ".", name != "..", !name.contains("/"), !name.contains(":"),
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw MTPError.invalidName
        }
    }

    private func decode<T: Decodable>(_ result: ProcessResult) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: Data(result.output.utf8)) } catch {
            throw MTPError.invalidResponse
        }
    }

    private func request(_ arguments: [String], timeout: Duration = .seconds(45)) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw MTPError.helperMissing }
        let runner = ProcessRunner(executable: executable)
        let result = try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask { try await runner.run(arguments: arguments, captureListing: true) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MTPError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
        switch result.status {
        case 0: return result
        case 2: throw MTPError.connection
        case 4: throw MTPError.changed
        case 6: throw MTPError.localWrite
        default: throw MTPError.read
        }
    }
}

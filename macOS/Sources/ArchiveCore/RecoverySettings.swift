import Foundation

public struct RecoveryVolumeCounts: Equatable, Sendable {
    public var data: Int
    public var recovery: Int

    public init(data: Int = 10, recovery: Int = 2) {
        self.data = data
        self.recovery = recovery
    }

    public func validate() throws {
        guard (1...100).contains(data) else {
            throw ArchiveError.invalidInput("数据卷数量必须是 1–100 之间的整数。")
        }
        guard (1...data).contains(recovery) else {
            throw ArchiveError.invalidInput("恢复卷数量必须是 1–\(data) 之间的整数，不能超过数据卷数量。")
        }
    }

    func arguments() throws -> [String] {
        try validate()
        return ["--data-volumes", "\(data)", "--recovery-volumes", "\(recovery)"]
    }
}

public enum RecoverySizeUnit: String, CaseIterable, Identifiable, Sendable {
    case kib = "KiB"
    case mib = "MiB"
    case gib = "GiB"
    public var id: String { rawValue }
    public var multiplier: Int64 {
        switch self {
        case .kib: 1024
        case .mib: 1024 * 1024
        case .gib: 1024 * 1024 * 1024
        }
    }
}

public enum RecoveryPayload: Equatable, Sendable {
    case percentage(basisPoints: Int)
    case bytes(Int64)

    func arguments() throws -> [String] {
        switch self {
        case .percentage(let value):
            guard (100...10_000).contains(value) else {
                throw ArchiveError.invalidInput("恢复比例必须在 1%–100% 之间，最多两位小数。")
            }
            let remainder = value % 100
            return ["--recovery-percent", "\(value / 100).\(remainder < 10 ? "0" : "")\(remainder)"]
        case .bytes(let value):
            guard value > 0, value <= 64 * 1024 * 1024 * 1024 else {
                throw ArchiveError.invalidInput("请输入有效的恢复载荷容量，最多 64 GiB。")
            }
            return ["--recovery-bytes", "\(value)"]
        }
    }
}

public enum RecoveryInput {
    public static func volumeCount(_ text: String) throws -> Int {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }),
            let count = Int(value), (1...100).contains(count)
        else { throw ArchiveError.invalidInput("请输入 1–100 之间的整数。") }
        return count
    }

    public static func volumeBytes(_ text: String, unit: RecoverySizeUnit) throws -> Int64 {
        let bytes = try sizeBytes(text, unit: unit)
        guard (1024 * 1024...16 * 1024 * 1024 * 1024).contains(bytes) else {
            throw ArchiveError.invalidInput("每卷上限必须在 1 MiB–16 GiB 之间。")
        }
        return bytes
    }

    public static func sizeBytes(_ text: String, unit: RecoverySizeUnit) throws -> Int64 {
        try scaled(text, scale: unit.multiplier, precision: 3, maximum: 64 * 1024 * 1024 * 1024)
    }

    public static func percentage(_ text: String) throws -> RecoveryPayload {
        let value = try scaled(text, scale: 100, precision: 2, maximum: 10_000)
        let payload = RecoveryPayload.percentage(basisPoints: Int(value))
        _ = try payload.arguments()
        return payload
    }

    private static func scaled(_ text: String, scale: Int64, precision: Int, maximum: Int64) throws -> Int64 {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
            parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
            let whole = Int64(parts[0]), whole <= maximum / scale
        else { throw ArchiveError.invalidInput("请输入有效的非负数值，不使用千位分隔符。") }
        var fraction: Int64 = 0
        var divisor: Int64 = 1
        if parts.count == 2 {
            guard parts[1].count <= precision, let number = Int64(parts[1]) else {
                throw ArchiveError.invalidInput("最多支持 \(precision) 位小数。")
            }
            fraction = number
            for _ in parts[1] { divisor *= 10 }
        }
        let result = whole * scale + fraction * scale / divisor
        guard result > 0, result <= maximum else { throw ArchiveError.invalidInput("数值必须大于 0 且在支持范围内。") }
        return result
    }
}

public struct RecoveryDetails: Decodable, Sendable {
    public let profile: Int
    public let dataBytes: Int64
    public let payloadBytes: Int64
    public let volumeLimitBytes: Int64
    public let dataVolumes: Int
    public let recoveryVolumes: Int
    public let requestedMode: Int
    public let requestedValue: Int64
    public let volumeSizeBytes: Int64?
    public let toleratedVolumeLosses: Int?
    public var actualRatio: Double { Double(payloadBytes) / Double(dataBytes) }

    var isValid: Bool {
        if profile == 4 {
            guard (1...100).contains(dataVolumes), (1...dataVolumes).contains(recoveryVolumes),
                dataBytes >= 65_536, payloadBytes >= 65_536, payloadBytes <= dataBytes,
                dataBytes <= 70 * 1024 * 1024 * 1024,
                dataBytes % (Int64(dataVolumes) * 65_536) == 0,
                payloadBytes % (Int64(recoveryVolumes) * 65_536) == 0,
                dataBytes / Int64(dataVolumes) == payloadBytes / Int64(recoveryVolumes),
                volumeLimitBytes == 0, requestedMode == 2, requestedValue == 0,
                toleratedVolumeLosses == recoveryVolumes, let volumeSizeBytes
            else { return false }
            let payload = dataBytes / Int64(dataVolumes)
            return volumeSizeBytes > payload + 240 && volumeSizeBytes <= payload + 240 + 2 * 16 * 1024 * 1024
        }
        return (profile == 2 || profile == 3) && dataBytes >= 65_536 && payloadBytes >= 65_536
            && payloadBytes <= dataBytes
            && (1024 * 1024...16 * 1024 * 1024 * 1024).contains(volumeLimitBytes)
            && (1...65_536).contains(dataVolumes) && (1...65_536).contains(recoveryVolumes)
            && (0...1).contains(requestedMode) && requestedValue > 0
    }
}

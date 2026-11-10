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

public enum RecoveryInput {
    public static func volumeCount(_ text: String) throws -> Int {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }),
            let count = Int(value), (1...100).contains(count)
        else { throw ArchiveError.invalidInput("请输入 1–100 之间的整数。") }
        return count
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
    public let volumeSizeBytes: Int64
    public let toleratedVolumeLosses: Int
    public let metadataBytesPerVolume: Int64
    public let contentLimitBytes: Int64

    var isValid: Bool {
        guard profile == 5, (1...100).contains(dataVolumes), (1...dataVolumes).contains(recoveryVolumes),
            dataBytes >= 65_536, payloadBytes >= 65_536, payloadBytes <= dataBytes,
            dataBytes % (Int64(dataVolumes) * 65_536) == 0,
            payloadBytes % (Int64(recoveryVolumes) * 65_536) == 0,
            dataBytes / Int64(dataVolumes) == payloadBytes / Int64(recoveryVolumes),
            volumeLimitBytes == 0, requestedMode == 2, requestedValue == 0,
            toleratedVolumeLosses == recoveryVolumes
        else { return false }
        let payload = dataBytes / Int64(dataVolumes)
        let contentLimit: Int64 = 1024 * 1024 * 1024 * 1024
        let stripeBytes = Int64(dataVolumes) * 65_536
        guard contentLimitBytes == contentLimit,
            dataBytes <= contentLimit + contentLimit / 100 + stripeBytes
        else { return false }
        let stripes = payload / 65_536
        let hashBytes = stripes * Int64(dataVolumes + recoveryVolumes) * 32
        let hashPages = (hashBytes + 65_535) / 65_536
        let rootSize = 44 + hashPages * 32
        let indexRecords = (hashPages * 65_536 + rootSize + stripeBytes - 1) / stripeBytes
        let recordOverhead = 240 + 32 * stripes + 65_568 * indexRecords
        let (bootstrapCopies, overflow) = metadataBytesPerVolume.subtractingReportingOverflow(recordOverhead)
        let minimumBootstrap = 148 + Int64(dataVolumes + recoveryVolumes) * 32
        guard !overflow, (2 * minimumBootstrap...16_384).contains(bootstrapCopies), bootstrapCopies % 2 == 0 else {
            return false
        }
        return volumeSizeBytes == payload + metadataBytesPerVolume
    }
}

import Foundation

public enum ListingParser {
    /// `-slt` has no escaping for newlines. Reject ambiguous records instead of
    /// treating a partial listing as a trustworthy extraction preflight.
    public static func parse(_ output: String, url: URL) throws -> ArchiveListing {
        let lines = output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let separator = lines.firstIndex(of: "----------") else {
            throw ArchiveError.malformedListing
        }
        var metadata: [String: String] = [:]
        for line in lines[..<separator] {
            if let (key, value) = field(line) { metadata[key] = value }
        }
        var records: [[String: String]] = []
        var record: [String: String] = [:]
        for line in lines.dropFirst(separator + 1) {
            if line.isEmpty {
                if !record.isEmpty {
                    records.append(record)
                    record = [:]
                }
                continue
            }
            guard let (key, value) = field(line), record[key] == nil else {
                throw ArchiveError.malformedListing
            }
            record[key] = value
        }
        if !record.isEmpty { records.append(record) }
        var seen: Set<String> = []
        let entries = try records.map { fields -> ArchiveEntry in
            guard var path = fields["Path"] else { throw ArchiveError.malformedListing }
            while path.hasPrefix("./") { path = String(path.dropFirst(2)) }
            guard seen.insert(path).inserted else {
                throw ArchiveError.malformedListing
            }
            let attributes = fields["Attributes", default: ""]
            let mode = fields["Mode", default: ""]
            let isDirectory = fields["Folder"] == "+" || attributes.hasPrefix("D") || mode.hasPrefix("d")
            let isLink =
                !fields["Symbolic Link", default: ""].isEmpty || !fields["Hard Link", default: ""].isEmpty
                || attributes.split(separator: " ").contains(where: { $0.hasPrefix("l") })
                || mode.hasPrefix("l")
            return ArchiveEntry(
                path: path, size: max(0, Int64(fields["Size", default: ""]) ?? 0),
                packedSize: fields["Packed Size"].flatMap(Int64.init),
                modified: fields["Modified", default: ""], isDirectory: isDirectory,
                isEncrypted: fields["Encrypted"] == "+", isLink: isLink)
        }
        return ArchiveListing(
            url: url, format: metadata["Type", default: url.pathExtension],
            physicalSize: Int64(metadata["Physical Size", default: ""]) ?? 0,
            entries: entries)
    }

    private static func field(_ line: String) -> (String, String)? {
        guard let range = line.range(of: " = ") else { return nil }
        return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
    }
}

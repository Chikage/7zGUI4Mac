import Foundation
import Testing

@testable import SevenZipMac

@Test func archiveNamesFollowSources() {
    let parent = URL(fileURLWithPath: "/资料/项目", isDirectory: true)
    let first = parent.appendingPathComponent("报告.txt")
    let second = parent.appendingPathComponent("照片.jpg")
    #expect(ArchiveNameSuggestion.name(for: []) == "归档")
    #expect(ArchiveNameSuggestion.name(for: [first]) == "报告")
    #expect(ArchiveNameSuggestion.name(for: [first, first]) == "报告")
    #expect(ArchiveNameSuggestion.name(for: [first, second]) == "项目")
    #expect(ArchiveNameSuggestion.name(for: [first, URL(fileURLWithPath: "/其他/照片.jpg")]) == "归档")
    #expect(ArchiveNameSuggestion.name(for: [parent.appendingPathComponent("文件夹.v2", isDirectory: true)]) == "文件夹.v2")
    #expect(ArchiveNameSuggestion.name(for: [parent.appendingPathComponent(".hidden")]) == ".hidden")
}

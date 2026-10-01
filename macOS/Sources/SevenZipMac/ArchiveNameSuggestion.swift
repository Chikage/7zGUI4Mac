import Foundation

enum ArchiveNameSuggestion {
    static func name(for sources: [URL]) -> String {
        let sources = Array(Set(sources.map(\.standardizedFileURL)))
        guard let first = sources.first else { return "归档" }
        if sources.count == 1 {
            let isDirectory = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? first.hasDirectoryPath
            let name = isDirectory ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
            return name.isEmpty || name == "/" ? "归档" : name
        }
        let parent = first.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent.path != "/", sources.allSatisfy({
            $0.deletingLastPathComponent().resolvingSymlinksInPath() == parent
        }) else { return "归档" }
        return parent.lastPathComponent
    }
}

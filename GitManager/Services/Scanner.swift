import Foundation

public struct Scanner: Sendable {
    public init() {}

    public func repositories(in path: String) throws -> [String] {
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError.message("Local folder does not exist: \(path)")
        }
        var repositories: [String] = []
        try scan(root, depth: 0, into: &repositories)
        return repositories.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func scan(_ directory: URL, depth: Int, into repositories: inout [String]) throws {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            repositories.append(directory.path)
            return
        }
        guard depth < 2 else { return }
        let children = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        )
        for child in children where child.lastPathComponent != "node_modules" {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true && values.isSymbolicLink != true {
                // Enumeration may spell /var as /private/var on macOS. Keep
                // discovered paths relative to the source's own normalized URL.
                let nested = directory.appendingPathComponent(child.lastPathComponent, isDirectory: true)
                try scan(nested, depth: depth + 1, into: &repositories)
            }
        }
    }
}

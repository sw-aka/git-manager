import Foundation

public struct ScanIssue: Equatable, Sendable {
    public let path: String
    public let message: String
}

public struct ScanResult: Sendable {
    public let repositories: [String]
    public let issues: [ScanIssue]
}

public struct Scanner: Sendable {
    public init() {}

    public func repositories(in path: String) throws -> [String] {
        try scan(in: path).repositories
    }

    public func scan(in path: String) throws -> ScanResult {
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError.message("Local folder does not exist: \(path)")
        }
        var repositories: [String] = []
        var issues: [ScanIssue] = []
        scan(root, depth: 0, into: &repositories, issues: &issues)
        return ScanResult(
            repositories: repositories.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            issues: issues.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        )
    }

    private func scan(_ directory: URL, depth: Int, into repositories: inout [String], issues: inout [ScanIssue]) {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            repositories.append(directory.path)
            return
        }
        guard depth < 2 else { return }
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
            )
        } catch {
            issues.append(ScanIssue(path: directory.path, message: error.localizedDescription))
            return
        }
        for child in children where child.lastPathComponent != "node_modules" {
            do {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true && values.isSymbolicLink != true {
                    // Keep discovered paths relative to the source's normalized URL.
                    let nested = directory.appendingPathComponent(child.lastPathComponent, isDirectory: true)
                    scan(nested, depth: depth + 1, into: &repositories, issues: &issues)
                }
            } catch {
                issues.append(ScanIssue(path: child.path, message: error.localizedDescription))
            }
        }
    }
}

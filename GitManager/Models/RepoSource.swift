import Foundation
import Darwin

public struct LocalFolderSource: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var path: String

    public init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }
}

public struct RemoteRepoSource: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var host: String
    public var port: Int?
    public var path: String

    public init(id: UUID = UUID(), host: String, port: Int? = nil, path: String) {
        self.id = id
        self.host = host
        self.port = port
        self.path = Self.normalizedPath(path)
    }

    public var normalized: Self {
        Self(id: id, host: host, port: port, path: path)
    }

    public static func normalizedPath(_ path: String) -> String {
        let homeRelative = path == "~" || path.hasPrefix("~/")
        guard homeRelative || path.hasPrefix("/") else { return path }
        let suffix = homeRelative ? String(path.dropFirst()) : path
        var segments: [Substring] = []
        for segment in suffix.split(separator: "/") where segment != "." {
            if segment == ".." {
                if let last = segments.last, last != ".." { segments.removeLast() }
                else if homeRelative { segments.append(segment) }
            } else { segments.append(segment) }
        }
        let rest = segments.joined(separator: "/")
        return homeRelative ? (rest.isEmpty ? "~" : "~/" + rest) : "/" + rest
    }

    public func validate() throws {
        let hostParts = host.split(separator: "@", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:[]")
        guard !host.isEmpty, !host.hasPrefix("-"), hostParts.count <= 2,
              hostParts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }),
              host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ValidationError.message("Enter an SSH host alias or user@host without spaces or options.")
        }
        if let port, !(1...65535).contains(port) {
            throw ValidationError.message("Port must be between 1 and 65535.")
        }
        guard (path.hasPrefix("/") || path == "~" || path.hasPrefix("~/")), !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw ValidationError.message("Use an absolute path or a home-relative path (~ or ~/...).")
        }
    }
}

enum ValidationError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

public enum RepoSource: Codable, Hashable, Sendable, Identifiable {
    case local(LocalFolderSource)
    case remote(RemoteRepoSource)

    public var id: UUID {
        switch self {
        case .local(let source): source.id
        case .remote(let source): source.id
        }
    }
    public var title: String {
        switch self {
        case .local(let source): URL(fileURLWithPath: source.path).lastPathComponent
        case .remote(let source): source.host
        }
    }
}

public struct RepoLocation: Hashable, Sendable {
    public let source: RepoSource
    public let path: String

    public init(source: RepoSource, path: String) {
        switch source {
        case .local:
            self.source = source
            self.path = Self.canonicalLocalPath(path)
        case .remote(let remote):
            self.source = .remote(remote.normalized)
            self.path = RemoteRepoSource.normalizedPath(path)
        }
    }

    public static func canonicalLocalPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        // realpath also unifies macOS's /var and /private/var spellings.
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public var id: String {
        switch source {
        case .local: "local:\(path)"
        case .remote(let remote): "remote:\(remote.host.utf8.count):\(remote.host):\(remote.port.map(String.init) ?? "default"):\(path)"
        }
    }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var displayPath: String {
        switch source {
        case .local: path
        case .remote(let remote): "\(remote.host)\(remote.port.map { ":\($0)" } ?? ""):\(path)"
        }
    }
}

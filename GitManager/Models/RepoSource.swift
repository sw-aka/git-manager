import Foundation

struct LocalFolderSource: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var path: String
}

struct RemoteRepoSource: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var host: String
    var port: Int?
    var path: String

    func validate() throws {
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
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw ValidationError.message("The remote repository path must be absolute.")
        }
    }
}

enum ValidationError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

enum RepoSource: Codable, Hashable, Sendable, Identifiable {
    case local(LocalFolderSource)
    case remote(RemoteRepoSource)

    var id: UUID {
        switch self {
        case .local(let source): source.id
        case .remote(let source): source.id
        }
    }
    var title: String {
        switch self {
        case .local(let source): URL(fileURLWithPath: source.path).lastPathComponent
        case .remote(let source): source.host
        }
    }
}

struct RepoLocation: Hashable, Sendable {
    let source: RepoSource
    let path: String
    var id: String { "\(source.id.uuidString):\(path)" }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var displayPath: String {
        switch source {
        case .local: path
        case .remote(let remote): "\(remote.host)\(remote.port.map { ":\($0)" } ?? ""):\(path)"
        }
    }
}

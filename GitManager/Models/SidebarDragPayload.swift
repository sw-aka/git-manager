import Foundation

/// A shared text representation for native sidebar drag sources and destinations.
public enum SidebarDragPayload: Equatable, Sendable {
    case repository(String)
    case group(UUID)

    public var string: String {
        switch self {
        case .repository(let id): "gitmanager-repository:" + id
        case .group(let id): "gitmanager-group:" + id.uuidString
        }
    }

    public init?(string: String) {
        let repositoryPrefix = "gitmanager-repository:"
        let groupPrefix = "gitmanager-group:"
        if string.hasPrefix(repositoryPrefix) {
            let id = String(string.dropFirst(repositoryPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .repository(id)
        } else if string.hasPrefix(groupPrefix), let id = UUID(uuidString: String(string.dropFirst(groupPrefix.count))) {
            self = .group(id)
        } else { return nil }
    }
}

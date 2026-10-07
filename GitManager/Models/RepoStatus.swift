import Foundation

public struct RepoStatus: Equatable, Sendable {
    public var branch = "unknown"
    public var upstream: String?
    public var upstreamGone = false
    public var hasOrigin = false
    public var ahead = 0
    public var behind = 0
    public var dirtyCount = 0
    public var isDetached = false
    public var isUnborn = false
    public var lastFetch: Date?
    public var error: String?

    public init() {}

    public var canSync: Bool {
        !isDetached && branch != "unknown" && !isUnborn && (upstream != nil || hasOrigin)
    }
    public var needsSync: Bool { ahead > 0 || behind > 0 || (upstream == nil && canSync) }
    public var needsAttention: Bool { needsSync || dirtyCount > 0 || error != nil || upstreamGone }
    public var badge: String {
        if isDetached { return "detached" }
        if upstream == nil { return "no upstream" }
        if upstreamGone { return "upstream gone" }
        return "↓\(behind) ↑\(ahead)"
    }
}

public struct RepoRecord: Identifiable, Sendable {
    public let location: RepoLocation
    public var status = RepoStatus()
    public var commits: [Commit] = []

    public init(location: RepoLocation) { self.location = location }

    public var id: String { location.id }
}

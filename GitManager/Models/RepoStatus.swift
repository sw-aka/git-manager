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
    public let locations: [RepoLocation]
    public var location: RepoLocation { locations[0] }
    public var sourceIDs: Set<UUID> { Set(locations.map { $0.source.id }) }
    public var status = RepoStatus()
    public var commits: [Commit] = []

    public init(location: RepoLocation) { locations = [location] }

    func withLocations(_ locations: [RepoLocation]) -> RepoRecord {
        precondition(!locations.isEmpty)
        var record = RepoRecord(locations: locations)
        record.status = status
        record.commits = commits
        return record
    }

    private init(locations: [RepoLocation]) { self.locations = locations }
    public var id: String { location.id }
}

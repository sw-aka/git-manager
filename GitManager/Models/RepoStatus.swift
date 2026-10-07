import Foundation

struct RepoStatus: Equatable, Sendable {
    var branch = "unknown"
    var upstream: String?
    var upstreamGone = false
    var hasOrigin = false
    var ahead = 0
    var behind = 0
    var dirtyCount = 0
    var isDetached = false
    var isUnborn = false
    var lastFetch: Date?
    var error: String?

    var canSync: Bool {
        !isDetached && branch != "unknown" && !isUnborn && (upstream != nil || hasOrigin)
    }
    var needsSync: Bool { ahead > 0 || behind > 0 || (upstream == nil && canSync) }
    var needsAttention: Bool { needsSync || dirtyCount > 0 || error != nil || upstreamGone }
    var badge: String {
        if isDetached { return "detached" }
        if upstream == nil { return "no upstream" }
        if upstreamGone { return "upstream gone" }
        return "↓\(behind) ↑\(ahead)"
    }
}

struct RepoRecord: Identifiable, Sendable {
    let location: RepoLocation
    var status = RepoStatus()
    var commits: [Commit] = []
    var id: String { location.id }
}

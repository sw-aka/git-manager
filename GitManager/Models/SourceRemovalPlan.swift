import Foundation

/// The complete impact of removing sources, independent of the visible list or its filters.
public struct SourceRemovalPlan: Equatable, Sendable {
    public struct Entry: Identifiable, Hashable, Sendable {
        public let source: RepoSource
        public let repositoryCount: Int
        public var id: UUID { source.id }
    }

    public let entries: [Entry]
    /// Unique repositories provided by these sources, including shared repositories.
    public let repositoryCount: Int
    /// Shared repositories that will remain because an unremoved source still provides them.
    public let retainedRepositoryCount: Int
    public var sourceIDs: Set<UUID> { Set(entries.map(\.id)) }

    public enum ConfirmationDecision: Equatable, Sendable {
        case proceed(SourceRemovalPlan)
        case reconfirm(SourceRemovalPlan)
        case noOp
    }

    // Source order has no bearing on removal. Compare every count shown to the user.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        Set(lhs.entries) == Set(rhs.entries)
            && lhs.repositoryCount == rhs.repositoryCount
            && lhs.retainedRepositoryCount == rhs.retainedRepositoryCount
    }

    /// Recompute only the sources the user reviewed, dropping sources already removed.
    public func confirmationDecision(sources: [RepoSource], repos: [RepoRecord]) -> ConfirmationDecision {
        let current = Self(sourceIDs: sourceIDs, sources: sources, repos: repos)
        guard !current.entries.isEmpty else { return .noOp }
        return current == self ? .proceed(current) : .reconfirm(current)
    }

    public init(sourceIDs: Set<UUID>, sources: [RepoSource], repos: [RepoRecord]) {
        let selectedSources = sources.filter { sourceIDs.contains($0.id) }
        let actualIDs = Set(selectedSources.map(\.id))
        entries = selectedSources.map { source in
            Entry(source: source, repositoryCount: repos.filter { $0.sourceIDs.contains(source.id) }.count)
        }
        let affected = repos.filter { !$0.sourceIDs.isDisjoint(with: actualIDs) }
        repositoryCount = affected.count
        retainedRepositoryCount = affected.filter { !$0.sourceIDs.subtracting(actualIDs).isEmpty }.count
    }

    public static func forRepositories(_ repoIDs: Set<String>, sources: [RepoSource],
                                       repos: [RepoRecord]) -> Self {
        let sourceIDs = repos.filter { repoIDs.contains($0.id) }
            .reduce(into: Set<UUID>()) { $0.formUnion($1.sourceIDs) }
        return Self(sourceIDs: sourceIDs, sources: sources, repos: repos)
    }
}

import Foundation

/// The complete impact of removing sources, independent of the visible list or its filters.
public struct SourceRemovalPlan: Sendable {
    public struct Entry: Identifiable, Sendable {
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

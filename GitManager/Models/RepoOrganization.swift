import Foundation

public struct RepoGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Uses canonical repository identities, independently of their source providers.
public struct RepoOrganization: Codable, Equatable, Sendable {
    public var groups: [RepoGroup]
    public var repositoryOrder: [String]
    public var groupByRepository: [String: UUID]

    public init(groups: [RepoGroup] = [], repositoryOrder: [String] = [], groupByRepository: [String: UUID] = [:]) {
        self.groups = groups
        self.repositoryOrder = repositoryOrder
        self.groupByRepository = groupByRepository
    }

    public var normalized: Self {
        var groupIDs: Set<UUID> = []
        var repoIDs: Set<String> = []
        let groups = groups.filter { groupIDs.insert($0.id).inserted }
        return Self(groups: groups,
                    repositoryOrder: repositoryOrder.filter { repoIDs.insert($0).inserted },
                    groupByRepository: groupByRepository.filter { groupIDs.contains($0.value) })
    }

    public func ordered(_ repos: [RepoRecord]) -> [RepoRecord] {
        let ranks = Dictionary(uniqueKeysWithValues: normalized.repositoryOrder.enumerated().map { ($0.element, $0.offset) })
        return repos.enumerated().sorted {
            let left = ranks[$0.element.id] ?? (ranks.count + $0.offset)
            let right = ranks[$1.element.id] ?? (ranks.count + $1.offset)
            return left < right
        }.map(\.element)
    }

    mutating func removeRepositories(_ ids: Set<String>) {
        repositoryOrder.removeAll { ids.contains($0) }
        groupByRepository = groupByRepository.filter { !ids.contains($0.key) }
    }

    mutating func replaceRepository(_ oldID: String, with newID: String) {
        guard oldID != newID else { return }
        let group = groupByRepository[oldID]
        repositoryOrder = repositoryOrder.filter { $0 != newID }.map { $0 == oldID ? newID : $0 }
        groupByRepository[oldID] = nil
        groupByRepository[newID] = group
    }
}

import Foundation

public struct RepoGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var parentID: UUID?
    public var isExpanded: Bool

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.isExpanded = isExpanded
    }

    private enum CodingKeys: String, CodingKey { case id, name, parentID, isExpanded }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        parentID = try values.decodeIfPresent(UUID.self, forKey: .parentID)
        isExpanded = try values.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
    }
}

public struct RepoGroupOutlineEntry: Identifiable, Equatable, Sendable {
    public let group: RepoGroup
    public let depth: Int
    public var id: UUID { group.id }
}

public enum GroupDropPosition: Equatable, Sendable { case before, inside, after }

/// Uses canonical repository identities, independently of their source providers.
public struct RepoOrganization: Codable, Equatable, Sendable {
    public var groups: [RepoGroup]
    public var repositoryOrder: [String]
    public var groupByRepository: [String: UUID]
    public var ungroupedExpanded: Bool

    public init(groups: [RepoGroup] = [], repositoryOrder: [String] = [], groupByRepository: [String: UUID] = [:],
                ungroupedExpanded: Bool = true) {
        self.groups = groups
        self.repositoryOrder = repositoryOrder
        self.groupByRepository = groupByRepository
        self.ungroupedExpanded = ungroupedExpanded
    }

    private enum CodingKeys: String, CodingKey { case groups, repositoryOrder, groupByRepository, ungroupedExpanded }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        groups = try values.decode([RepoGroup].self, forKey: .groups)
        repositoryOrder = try values.decodeIfPresent([String].self, forKey: .repositoryOrder) ?? []
        groupByRepository = try values.decodeIfPresent([String: UUID].self, forKey: .groupByRepository) ?? [:]
        ungroupedExpanded = try values.decodeIfPresent(Bool.self, forKey: .ungroupedExpanded) ?? true
    }

    public var normalized: Self {
        var groupIDs: Set<UUID> = []
        var repoIDs: Set<String> = []
        var groups = groups.filter { groupIDs.insert($0.id).inserted }
        for index in groups.indices {
            if let parent = groups[index].parentID, parent == groups[index].id || !groupIDs.contains(parent) {
                groups[index].parentID = nil
            }
        }
        var parents = Dictionary(uniqueKeysWithValues: groups.compactMap { group in group.parentID.map { (group.id, $0) } })
        for index in groups.indices {
            var visited: Set<UUID> = [groups[index].id]
            var next = groups[index].parentID
            while let id = next {
                guard groupIDs.contains(id), visited.insert(id).inserted else {
                    groups[index].parentID = nil
                    parents[groups[index].id] = nil
                    break
                }
                next = parents[id]
            }
        }
        return Self(groups: groups,
                    repositoryOrder: repositoryOrder.filter { repoIDs.insert($0).inserted },
                    groupByRepository: groupByRepository.filter { groupIDs.contains($0.value) },
                    ungroupedExpanded: ungroupedExpanded)
    }

    public func children(of parentID: UUID?) -> [RepoGroup] {
        groups.filter { $0.parentID == parentID }
    }

    /// Preorder traversal keeps each group and all its descendants together.
    public func outline(visibleOnly: Bool = false) -> [RepoGroupOutlineEntry] {
        var stack = children(of: nil).reversed().map { RepoGroupOutlineEntry(group: $0, depth: 0) }
        var result: [RepoGroupOutlineEntry] = []
        while let entry = stack.popLast() {
            result.append(entry)
            if !visibleOnly || entry.group.isExpanded {
                stack.append(contentsOf: children(of: entry.id).reversed().map {
                    RepoGroupOutlineEntry(group: $0, depth: entry.depth + 1)
                })
            }
        }
        return result
    }

    public func subtreeIDs(of id: UUID) -> Set<UUID> {
        guard groups.contains(where: { $0.id == id }) else { return [] }
        var result: Set<UUID> = []
        var stack = [id]
        while let next = stack.popLast() {
            guard result.insert(next).inserted else { continue }
            stack.append(contentsOf: children(of: next).map(\.id))
        }
        return result
    }

    public func path(of id: UUID) -> String {
        var names: [String] = []
        var next: UUID? = id
        var visited: Set<UUID> = []
        while let id = next, visited.insert(id).inserted, let group = groups.first(where: { $0.id == id }) {
            names.append(group.name)
            next = group.parentID
        }
        return names.reversed().joined(separator: " / ")
    }

    public func canMoveGroup(_ id: UUID, to parentID: UUID?, before targetID: UUID? = nil) -> Bool {
        guard let group = groups.first(where: { $0.id == id }) else { return false }
        if let parentID {
            guard groups.contains(where: { $0.id == parentID }), !subtreeIDs(of: id).contains(parentID) else { return false }
        }
        if let targetID {
            guard targetID != id, groups.contains(where: { $0.id == targetID && $0.parentID == parentID }) else { return false }
        }
        if group.parentID == parentID { return true }
        return !children(of: parentID).contains { $0.id != id && $0.name.caseInsensitiveCompare(group.name) == .orderedSame }
    }

    @discardableResult
    mutating func moveGroup(_ id: UUID, to parentID: UUID?, before targetID: UUID? = nil) -> Bool {
        guard canMoveGroup(id, to: parentID, before: targetID), let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        var group = groups.remove(at: index)
        group.parentID = parentID
        let insertion = targetID.flatMap { target in groups.firstIndex { $0.id == target } }
            ?? groups.lastIndex(where: { $0.parentID == parentID }).map { $0 + 1 } ?? groups.count
        groups.insert(group, at: insertion)
        return true
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

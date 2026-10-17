import Foundation

/// A versioned, human-readable setup document, separate from the internal state file.
public enum ConfigurationTransfer {
    public static func export(_ state: StoredState, repositories: [RepoRecord]) throws -> String {
        var order = state.organization.repositoryOrder
        var known = Set(order)
        for id in repositories.map(\.id) + state.organization.groupByRepository.keys.sorted() {
            if known.insert(id).inserted { order.append(id) }
        }
        let document = Document(
            format: "git-manager", version: 1,
            sources: state.sources.map(Source.init),
            groups: state.organization.groups.map { group in
                Group(id: group.id, name: group.name, parentID: group.parentID, isExpanded: group.isExpanded,
                      repositories: order.filter { state.organization.groupByRepository[$0] == group.id })
            },
            ungrouped: order.filter { state.organization.groupByRepository[$0] == nil },
            ungroupedExpanded: state.organization.ungroupedExpanded,
            fetchIntervalMinutes: state.settings.validatedInterval,
            repositoryEditors: state.settings.repositoryEditors)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(document), as: UTF8.self) + "\n"
    }

    public static func parse(_ text: String) throws -> StoredState {
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: Data(text.utf8)) }
        catch {
            throw ValidationError.message("This is not a complete Git Manager setup. Paste the full exported JSON text or choose an exported file. \(error.localizedDescription)")
        }
        guard document.format == "git-manager", document.version == 1 else {
            throw ValidationError.message("This setup format or version is not supported by this version of Git Manager.")
        }
        let sources = try document.sources.map { try $0.source() }
        guard Set(sources.map(\.id)).count == sources.count else {
            throw ValidationError.message("Each source must have a unique ID.")
        }
        let groups = document.groups.map { RepoGroup(id: $0.id, name: $0.name, parentID: $0.parentID, isExpanded: $0.isExpanded) }
        var order: [String] = []
        var membership: [String: UUID] = [:]
        for group in document.groups {
            order.append(contentsOf: group.repositories)
            for id in group.repositories { membership[id] = group.id }
        }
        order.append(contentsOf: document.ungrouped)
        guard Set(order).count == order.count, order.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else {
            throw ValidationError.message("Each repository must appear exactly once and have a nonempty identity.")
        }
        let organization = RepoOrganization(groups: groups, repositoryOrder: order, groupByRepository: membership,
                                            ungroupedExpanded: document.ungroupedExpanded)
        guard organization.normalized == organization else {
            throw ValidationError.message("Groups must have unique IDs, existing parents, and no cycles.")
        }
        for group in groups {
            guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !groups.contains(where: { $0.id != group.id && $0.parentID == group.parentID && $0.name.caseInsensitiveCompare(group.name) == .orderedSame }) else {
                throw ValidationError.message("Group names must be nonempty and unique within their parent group.")
            }
        }
        guard (1...1440).contains(document.fetchIntervalMinutes) else {
            throw ValidationError.message("The fetch interval must be between 1 and 1440 minutes.")
        }
        return StoredState(sources: sources,
                           settings: AppSettings(fetchIntervalMinutes: document.fetchIntervalMinutes,
                                                 repositoryEditors: document.repositoryEditors),
                           organization: organization)
    }

    private struct Document: Codable {
        let format: String
        let version: Int
        let sources: [Source]
        let groups: [Group]
        let ungrouped: [String]
        let ungroupedExpanded: Bool
        let fetchIntervalMinutes: Int
        let repositoryEditors: [String: RepositoryEditor]
    }

    private struct Group: Codable {
        let id: UUID
        let name: String
        let parentID: UUID?
        let isExpanded: Bool
        let repositories: [String]
    }

    private struct Source: Codable {
        let id: UUID
        let kind: String
        let path: String
        let host: String?
        let port: Int?

        init(_ source: RepoSource) {
            id = source.id
            switch source {
            case .local(let folder):
                kind = "local"; path = folder.path; host = nil; port = nil
            case .remote(let remote):
                kind = "ssh"; path = remote.path; host = remote.host; port = remote.port
            }
        }

        func source() throws -> RepoSource {
            switch kind {
            case "local":
                guard path.hasPrefix("/"), !path.contains("\0"), host == nil, port == nil else {
                    throw ValidationError.message("Local sources need an absolute folder path and no SSH host or port.")
                }
                return .local(LocalFolderSource(id: id, path: path))
            case "ssh":
                let remote = RemoteRepoSource(id: id, host: host ?? "", port: port, path: path)
                try remote.validate()
                return .remote(remote)
            default:
                throw ValidationError.message("Unknown source kind: \(kind). Use local or ssh.")
            }
        }
    }
}

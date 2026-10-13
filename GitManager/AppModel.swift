import Foundation
import Observation

@MainActor @Observable
public final class AppModel {
    public private(set) var sources: [RepoSource] = []
    public private(set) var settings = AppSettings()
    public private(set) var organization = RepoOrganization()
    public private(set) var repos: [RepoRecord] = []
    public private(set) var sourceScanErrors: [UUID: [ScanIssue]] = [:]
    public private(set) var busy: Set<String> = []
    public private(set) var syncing: Set<String> = []
    public private(set) var isRefreshing = false
    public var message: String?
    public var needsAttentionOnly = false
    public var selection: Set<String> = []

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let serviceFactory: @Sendable (RepoLocation) -> RepoService
    @ObservationIgnored private let saveState: (StoredState) throws -> Void
    @ObservationIgnored private var persistenceEnabled = true
    @ObservationIgnored private let limiter = WorkLimiter()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public convenience init(store: Store = Store()) {
        self.init(store: store, serviceFactory: { RepoService(location: $0) })
    }

    init(store: Store, serviceFactory: @escaping @Sendable (RepoLocation) -> RepoService,
         saveState: ((StoredState) throws -> Void)? = nil) {
        self.store = store
        self.serviceFactory = serviceFactory
        self.saveState = saveState ?? { try store.save($0) }
        do {
            let loaded = try store.loadRecovering()
            sources = loaded.state.sources.map { source in
                if case .remote(let remote) = source { return .remote(remote.normalized) }
                return source
            }
            settings = loaded.state.settings
            organization = loaded.state.organization
            message = loaded.notice
            settings.fetchIntervalMinutes = settings.validatedInterval
        } catch {
            persistenceEnabled = false
            message = "Could not load saved sources and settings. The existing file is unchanged and saving is disabled: \(error.localizedDescription)"
        }
    }

    public var orderedRepos: [RepoRecord] {
        let ordered = organization.ordered(repos)
        return organization.outline().flatMap { entry in ordered.filter { organization.groupByRepository[$0.id] == entry.id } }
            + ordered.filter { organization.groupByRepository[$0.id] == nil }
    }
    public var visibleRepos: [RepoRecord] { orderedRepos.filter { !needsAttentionOnly || $0.status.needsAttention } }
    public var syncRepos: [RepoRecord] { orderedRepos.filter { $0.status.needsSync } }
    public var menuBarTitle: String { syncRepos.isEmpty ? "" : String(syncRepos.count) }
    public var selectedRepos: [RepoRecord] { orderedRepos.filter { selection.contains($0.id) } }
    public var selectedRepo: RepoRecord? { selection.count == 1 ? selectedRepos.first : nil }
    public var selectedRemovalPlan: SourceRemovalPlan {
        SourceRemovalPlan.forRepositories(selection, sources: sources, repos: repos)
    }

    public func repositories(in groupID: UUID?, visibleOnly: Bool = true) -> [RepoRecord] {
        (visibleOnly ? visibleRepos : orderedRepos).filter { organization.groupByRepository[$0.id] == groupID }
    }

    public func repositoryCount(in groupID: UUID?) -> Int {
        guard let groupID else { return repositories(in: nil, visibleOnly: false).count }
        let ids = organization.subtreeIDs(of: groupID)
        return repos.filter { organization.groupByRepository[$0.id].map { ids.contains($0) } ?? false }.count
    }

    public func setGroupExpanded(_ id: UUID?, to expanded: Bool) {
        if let id {
            guard let index = organization.groups.firstIndex(where: { $0.id == id }),
                  organization.groups[index].isExpanded != expanded else { return }
            organization.groups[index].isExpanded = expanded
        } else {
            guard organization.ungroupedExpanded != expanded else { return }
            organization.ungroupedExpanded = expanded
        }
        persist()
    }

    @discardableResult
    public func createGroup(named name: String, parentID: UUID? = nil) throws -> UUID {
        if let parentID, !organization.groups.contains(where: { $0.id == parentID }) {
            throw ValidationError.message("The parent group was removed.")
        }
        let group = RepoGroup(name: try validatedGroupName(name, parentID: parentID), parentID: parentID)
        organization.groups.append(group)
        expandGroupAncestors(parentID)
        persist()
        return group.id
    }

    public func renameGroup(_ id: UUID, to name: String) throws {
        guard let index = organization.groups.firstIndex(where: { $0.id == id }) else {
            throw ValidationError.message("This group was removed.")
        }
        let name = try validatedGroupName(name, parentID: organization.groups[index].parentID, excluding: id)
        guard organization.groups[index].name != name else { return }
        organization.groups[index].name = name
        persist()
    }

    private func validatedGroupName(_ name: String, parentID: UUID?, excluding id: UUID? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ValidationError.message("Enter a group name.") }
        guard !organization.children(of: parentID).contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ValidationError.message("A group with this name already exists at this level.")
        }
        return name
    }

    /// Dissolves a group without removing any repository or source.
    public func removeGroup(_ id: UUID) {
        guard let removed = organization.groups.first(where: { $0.id == id }) else { return }
        // Promote children in place, preserving their subtrees and relative order.
        organization.groups = organization.outline().map(\.group)
        organization.groups.removeAll { $0.id == id }
        var siblingNames = organization.children(of: removed.parentID).map(\.name)
        for index in organization.groups.indices where organization.groups[index].parentID == id {
            let original = organization.groups[index].name
            var name = original
            var suffix = 2
            while siblingNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                name = "\(original) (\(suffix))"
                suffix += 1
            }
            organization.groups[index].name = name
            organization.groups[index].parentID = removed.parentID
            siblingNames.append(name)
        }
        for repoID in organization.groupByRepository.keys.filter({ organization.groupByRepository[$0] == id }) {
            organization.groupByRepository[repoID] = removed.parentID
        }
        persist()
    }

    public func moveGroup(_ id: UUID, by offset: Int) {
        guard let group = organization.groups.first(where: { $0.id == id }), offset == -1 || offset == 1 else { return }
        let siblings = organization.children(of: group.parentID)
        guard let index = siblings.firstIndex(where: { $0.id == id }), siblings.indices.contains(index + offset) else { return }
        let destination = index + offset
        let target = offset < 0 ? siblings[destination].id : siblings.indices.contains(destination + 1) ? siblings[destination + 1].id : nil
        moveGroup(id, to: group.parentID, before: target)
    }

    @discardableResult
    public func moveGroup(_ id: UUID, to parentID: UUID?, before targetID: UUID? = nil) -> Bool {
        let previous = organization
        guard organization.moveGroup(id, to: parentID, before: targetID) else { return false }
        expandGroupAncestors(parentID)
        if organization != previous { persist() }
        return true
    }

    public func canDropGroup(_ id: UUID, on targetID: UUID?, position: GroupDropPosition) -> Bool {
        guard let targetID else { return position == .inside && organization.canMoveGroup(id, to: nil) }
        guard id != targetID, let target = organization.groups.first(where: { $0.id == targetID }) else { return false }
        switch position {
        case .inside: return organization.canMoveGroup(id, to: targetID)
        case .before: return organization.canMoveGroup(id, to: target.parentID, before: targetID)
        case .after: return organization.canMoveGroup(id, to: target.parentID)
        }
    }

    @discardableResult
    public func dropSidebarItem(_ string: String, on groupID: UUID?, position: GroupDropPosition = .inside,
                                before repositoryID: String? = nil) -> Bool {
        guard let payload = SidebarDragPayload(string: string) else { return false }
        switch payload {
        case .group(let id):
            guard repositoryID == nil else { return false }
            return dropGroup(id, on: groupID, position: position)
        case .repository(let id):
            return moveRepositories([id], to: groupID, before: repositoryID)
        }
    }

    @discardableResult
    public func dropGroup(_ id: UUID, on targetID: UUID?, position: GroupDropPosition) -> Bool {
        guard canDropGroup(id, on: targetID, position: position) else { return false }
        guard let targetID, let target = organization.groups.first(where: { $0.id == targetID }) else {
            return moveGroup(id, to: nil)
        }
        switch position {
        case .inside: return moveGroup(id, to: targetID)
        case .before: return moveGroup(id, to: target.parentID, before: targetID)
        case .after:
            let siblings = organization.children(of: target.parentID).filter { $0.id != id }
            guard let index = siblings.firstIndex(where: { $0.id == targetID }) else { return false }
            let next = siblings.indices.contains(index + 1) ? siblings[index + 1].id : nil
            return moveGroup(id, to: target.parentID, before: next)
        }
    }

    private func expandGroupAncestors(_ id: UUID?) {
        var next = id
        while let id = next, let index = organization.groups.firstIndex(where: { $0.id == id }) {
            organization.groups[index].isExpanded = true
            next = organization.groups[index].parentID
        }
    }

    /// Moves existing repositories in their current order, before a target or to the end of a group.
    @discardableResult
    public func moveRepositories(_ ids: Set<String>, to groupID: UUID?, before targetID: String? = nil) -> Bool {
        guard groupID == nil || organization.groups.contains(where: { $0.id == groupID }) else { return false }
        let ordered = organization.ordered(repos)
        let moved = ordered.filter { ids.contains($0.id) }.map(\.id)
        guard !moved.isEmpty else { return false }
        let movedIDs = Set(moved)
        if let targetID {
            guard !movedIDs.contains(targetID),
                  ordered.contains(where: { $0.id == targetID }),
                  organization.groupByRepository[targetID] == groupID else { return false }
        }
        let previous = organization
        // Keep temporarily unavailable repositories' positions and membership across scans.
        var order = organization.repositoryOrder
        let known = Set(order)
        order.append(contentsOf: ordered.map(\.id).filter { !known.contains($0) })
        order.removeAll { movedIDs.contains($0) }
        for id in moved { organization.groupByRepository[id] = groupID }
        let insertion: Int
        if let targetID, let index = order.firstIndex(of: targetID) {
            insertion = index
        } else if let last = order.lastIndex(where: { organization.groupByRepository[$0] == groupID }) {
            insertion = last + 1
        } else {
            insertion = order.count
        }
        order.insert(contentsOf: moved, at: insertion)
        organization.repositoryOrder = order
        if let groupID { expandGroupAncestors(groupID) }
        else { organization.ungroupedExpanded = true }
        if organization != previous { persist() }
        return true
    }

    public func canMoveRepository(_ id: String, by offset: Int) -> Bool {
        let records = repositories(in: organization.groupByRepository[id], visibleOnly: false)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        return offset != 0 && records.indices.contains(index + offset)
    }

    public func moveRepository(_ id: String, by offset: Int) {
        guard canMoveRepository(id, by: offset) else { return }
        let group = organization.groupByRepository[id]
        let records = repositories(in: group, visibleOnly: false)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        let target = offset < 0 ? records[destination].id : records.indices.contains(destination + 1) ? records[destination + 1].id : nil
        moveRepositories([id], to: group, before: target)
    }

    public func start() async {
        guard !started else { return }
        started = true
        await refreshAll(fetch: false)
        scheduleTimer()
        await refreshAll(fetch: true)
    }

    public func setInterval(_ minutes: Int) {
        settings.fetchIntervalMinutes = min(1440, max(1, minutes))
        persist()
        if started { scheduleTimer() }
    }

    private func scheduleTimer() {
        timer?.cancel()
        let seconds = settings.validatedInterval * 60
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard let self else { return }
                await self.refreshAll(fetch: true)
            }
        }
    }

    public func addLocal(_ url: URL) {
        let path = RepoLocation.canonicalLocalPath(url.path)
        guard !sources.contains(where: { if case .local(let folder) = $0 { RepoLocation.canonicalLocalPath(folder.path) == path } else { false } }) else { return }
        sources.append(.local(LocalFolderSource(path: path)))
        persist()
        Task { await refreshAll() }
    }

    public func addRemote(_ remote: RemoteRepoSource) throws {
        try remote.validate()
        let remote = remote.normalized
        guard !containsRemote(remote) else { throw ValidationError.message("This remote repository is already added.") }
        sources.append(.remote(remote))
        persist()
        Task { await refreshAll() }
    }

    /// Points an existing local folder source at a different folder, keeping its identity.
    public func updateLocal(_ sourceID: UUID, to url: URL) throws {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }), case .local(var folder) = sources[index] else {
            throw ValidationError.message("This source was removed.")
        }
        let path = RepoLocation.canonicalLocalPath(url.path)
        guard !sources.contains(where: {
            if case .local(let other) = $0 { other.id != sourceID && RepoLocation.canonicalLocalPath(other.path) == path } else { false }
        }) else { throw ValidationError.message("This folder is already added.") }
        folder.path = path
        replaceSource(at: index, with: .local(folder))
    }

    /// Replaces the host, port and path of the remote source with the same ID.
    public func updateRemote(_ remote: RemoteRepoSource) throws {
        try remote.validate()
        let remote = remote.normalized
        guard let index = sources.firstIndex(where: { $0.id == remote.id }), case .remote = sources[index] else {
            throw ValidationError.message("This source was removed.")
        }
        guard !containsRemote(remote) else { throw ValidationError.message("This remote repository is already added.") }
        let wasSelected = selectedRepos.contains { $0.sourceIDs.contains(remote.id) }
        if case .remote(let old) = sources[index] {
            organization.replaceRepository(RepoLocation(source: .remote(old), path: old.path).id,
                                           with: RepoLocation(source: .remote(remote), path: remote.path).id)
        }
        replaceSource(at: index, with: .remote(remote))
        if wasSelected { selection.insert(RepoLocation(source: .remote(remote), path: remote.path).id) }
    }

    private func containsRemote(_ remote: RemoteRepoSource) -> Bool {
        let identity = RepoLocation(source: .remote(remote), path: remote.path).id
        return sources.contains {
            if case .remote(let source) = $0 { source.id != remote.id && RepoLocation(source: $0, path: source.path).id == identity }
            else { false }
        }
    }

    private func replaceSource(at index: Int, with source: RepoSource) {
        guard sources[index] != source else { return }
        sources[index] = source
        sourceScanErrors[source.id] = nil
        dropLocations(of: [source.id])
        persist()
        Task { await refreshAll() }
    }

    public func removeSource(_ sourceID: UUID) {
        removeSources([sourceID])
    }

    public func removeSources(_ ids: Set<UUID>) {
        guard sources.contains(where: { ids.contains($0.id) }) else { return }
        sources.removeAll { ids.contains($0.id) }
        sourceScanErrors = sourceScanErrors.filter { !ids.contains($0.key) }
        dropLocations(of: ids)
        persist()
    }

    /// Detaches repositories from the given sources; repositories still provided by another source stay.
    private func dropLocations(of ids: Set<UUID>) {
        let previousIDs = Set(repos.map(\.id))
        repos = repos.compactMap { repo in
            let remaining = repo.locations.filter { !ids.contains($0.source.id) }
            return remaining.isEmpty ? nil : repo.withLocations(remaining)
        }
        selection.formIntersection(repos.map(\.id))
        organization.removeRepositories(previousIDs.subtracting(repos.map(\.id)))
    }

    private func persist() {
        guard persistenceEnabled else { return }
        do { try saveState(StoredState(sources: sources, settings: settings, organization: organization)) }
        catch { message = "Could not save sources, settings and repository organization: \(error.localizedDescription)" }
    }

    private func rescan() async {
        let sources = sources
        let discovered = await Task.detached(priority: .utility) {
            var records: [RepoRecord] = []
            var errors: [UUID: [ScanIssue]] = [:]
            for source in sources {
                switch source {
                case .remote(let remote):
                    records.append(RepoRecord(location: RepoLocation(source: source, path: remote.path)))
                case .local(let folder):
                    do {
                        let scan = try Scanner().scan(in: folder.path)
                        errors[source.id] = scan.issues
                        for path in scan.repositories {
                            records.append(RepoRecord(location: RepoLocation(source: source, path: path)))
                        }
                    } catch {
                        errors[source.id] = [ScanIssue(path: folder.path, message: error.localizedDescription)]
                    }
                }
            }
            return (records: records, errors: errors)
        }.value
        let existing = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        // Compare whole sources, not IDs: an edited source keeps its ID but its old results are stale.
        let current = Set(self.sources)
        let currentSourceIDs = Set(sources.filter { current.contains($0) }.map(\.id))
        sourceScanErrors = discovered.errors.filter { currentSourceIDs.contains($0.key) && !$0.value.isEmpty }
        var consolidated: [RepoRecord] = []
        var indices: [String: Int] = [:]
        for repo in discovered.records where currentSourceIDs.contains(repo.location.source.id) {
            if let index = indices[repo.id] {
                let previous = consolidated[index]
                consolidated[index] = previous.withLocations(previous.locations + repo.locations)
            } else {
                indices[repo.id] = consolidated.count
                consolidated.append(existing[repo.id]?.withLocations(repo.locations) ?? repo)
            }
        }
        repos = consolidated
        selection.formIntersection(repos.map(\.id))
    }

    public func refreshAll(fetch: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let scannedSources = sources
        await rescan()
        let ids = repos.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            for _ in 0..<min(4, ids.count) {
                let id = ids[next]
                next += 1
                group.addTask { await self.refresh(id, fetch: fetch) }
            }
            while await group.next() != nil {
                if next < ids.count {
                    let id = ids[next]
                    next += 1
                    group.addTask { await self.refresh(id, fetch: fetch) }
                }
            }
        }
        isRefreshing = false
        // Include sources added while the discovery pass was in progress.
        if sources != scannedSources { await refreshAll(fetch: fetch) }
    }

    public func refresh(_ id: String, fetch: Bool = true) async {
        guard !busy.contains(id), let repo = repos.first(where: { $0.id == id }) else { return }
        busy.insert(id)
        await limiter.acquire()
        let service = serviceFactory(repo.location)
        var lastFetch = repo.status.lastFetch
        var error: String?
        if fetch {
            let result = await service.fetch()
            if result.succeeded { lastFetch = Date() } else { error = result.failureMessage }
        }
        let snapshot = await service.snapshot(lastFetch: lastFetch, operationError: error)
        apply(snapshot, to: id)
        await limiter.release()
        busy.remove(id)
    }

    public func sync(_ id: String) async {
        guard !busy.contains(id), let repo = repos.first(where: { $0.id == id }), repo.status.canSync else { return }
        busy.insert(id)
        syncing.insert(id)
        await limiter.acquire()
        let outcome = await serviceFactory(repo.location).sync(lastFetch: repo.status.lastFetch)
        apply(outcome.snapshot, to: id)
        await limiter.release()
        syncing.remove(id)
        busy.remove(id)
    }

    public func openInZed(_ id: String) async {
        guard let repo = repos.first(where: { $0.id == id }) else { return }
        let result = await ZedLauncher().open(repo.location)
        if !result.succeeded, let index = repos.firstIndex(where: { $0.id == id }) {
            repos[index].status.error = result.failureMessage
        }
    }

    private func apply(_ snapshot: RepoSnapshot, to id: String) {
        guard let index = repos.firstIndex(where: { $0.id == id }) else { return }
        repos[index].status = snapshot.status
        repos[index].commits = snapshot.commits
    }
}

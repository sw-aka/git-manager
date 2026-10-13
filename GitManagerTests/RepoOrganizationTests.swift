import XCTest
@testable import GitManagerCore

private struct OrganizationRunner: GitRunner {
    var quiet = false
    func run(args: [String], timeout: TimeInterval) async -> CommandResult {
        let output = args.first == "status"
            ? "# branch.head main\0# branch.upstream origin/main\0# branch.ab +\(quiet ? 0 : 1) -0\0"
            : args.first == "remote" ? "origin\n" : ""
        return CommandResult(stdout: output, stderr: "", exitCode: 0)
    }
}

@MainActor
final class RepoOrganizationTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmanager-organization-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func model(store: Store) -> AppModel {
        AppModel(store: store, serviceFactory: { RepoService(runner: OrganizationRunner(quiet: $0.name == "quiet")) })
    }
    private func remote(_ name: String) -> RepoSource {
        .remote(RemoteRepoSource(host: "host", path: "/\(name)"))
    }

    func testMixedGroupsAndOrderingSurviveRefreshAndRestart() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        for name in ["local-a", "local-b"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("\(name)/.git"), withIntermediateDirectories: true)
        }
        let store = Store(directory: root.appendingPathComponent("state"))
        try store.save(StoredState(sources: [.local(LocalFolderSource(path: folder.path)), remote("remote-a"), remote("remote-b")]))
        let model = model(store: store)
        await model.refreshAll(fetch: false)
        let ids = Dictionary(uniqueKeysWithValues: model.repos.map { ($0.location.name, $0.id) })
        let localA = try XCTUnwrap(ids["local-a"]), localB = try XCTUnwrap(ids["local-b"])
        let remoteA = try XCTUnwrap(ids["remote-a"]), remoteB = try XCTUnwrap(ids["remote-b"])
        let work = try model.createGroup(named: "  Work  ")
        let personal = try model.createGroup(named: "Personal")
        XCTAssertTrue(model.moveRepositories([localA, remoteB], to: work))
        model.moveRepository(remoteB, by: -1)
        model.moveRepositories([remoteA], to: personal)
        model.selection = [remoteB]
        XCTAssertEqual(model.orderedRepos.map(\.id), [remoteB, localA, remoteA, localB])
        XCTAssertEqual(model.repositories(in: work).map(\.id), [remoteB, localA])
        XCTAssertEqual(model.repositories(in: nil).map(\.id), [localB])
        await model.refreshAll(fetch: false)
        XCTAssertEqual(model.orderedRepos.map(\.id), [remoteB, localA, remoteA, localB])
        XCTAssertEqual(model.selectedRepo?.id, remoteB)
        XCTAssertEqual(try store.load().organization, model.organization)
        let restored = self.model(store: store)
        await restored.refreshAll(fetch: false)
        XCTAssertEqual(restored.orderedRepos.map(\.id), model.orderedRepos.map(\.id))
        XCTAssertEqual(restored.organization.groups.map(\.name), ["Work", "Personal"])
        XCTAssertEqual(restored.syncRepos.map(\.id), restored.orderedRepos.map(\.id))
    }

    func testReorderAndBulkMovesUseFullOrderWhileFiltered() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        try store.save(StoredState(sources: [remote("a"), remote("quiet"), remote("b"), remote("c")]))
        let model = model(store: store)
        await model.refreshAll(fetch: false)
        let ids = model.orderedRepos.map(\.id)
        model.needsAttentionOnly = true
        XCTAssertEqual(model.visibleRepos.map(\.id), [ids[0], ids[2], ids[3]])
        model.moveRepository(ids[2], by: -1)
        XCTAssertEqual(model.orderedRepos.map(\.id), [ids[0], ids[2], ids[1], ids[3]])
        XCTAssertTrue(model.moveRepositories([ids[3]], to: nil, before: ids[0]))
        XCTAssertEqual(model.orderedRepos.map(\.id), [ids[3], ids[0], ids[2], ids[1]])
        let group = try model.createGroup(named: "Mixed")
        XCTAssertTrue(model.moveRepositories([ids[2], ids[3]], to: group))
        XCTAssertEqual(model.repositories(in: group).map(\.id), [ids[3], ids[2]], "Bulk moves retain the existing order")
        model.needsAttentionOnly = false
        XCTAssertEqual(model.repositories(in: nil).map(\.id), [ids[0], ids[1]], "Filtering must keep hidden repositories")
        model.moveRepositories([ids[1]], to: group, before: ids[2])
        XCTAssertEqual(model.repositories(in: group).map(\.id), [ids[3], ids[1], ids[2]])
        model.moveRepository(ids[3], by: 1)
        XCTAssertEqual(model.repositories(in: group).map(\.id), [ids[1], ids[3], ids[2]])
        model.moveRepository(ids[3], by: 1)
        XCTAssertEqual(model.repositories(in: group).map(\.id), [ids[1], ids[2], ids[3]])
    }

    func testRenameReorderAndDissolveKeepRepositoriesAndSources() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        let sources = [remote("a"), remote("b")]
        try store.save(StoredState(sources: sources))
        let model = model(store: store)
        await model.refreshAll(fetch: false)
        let ids = model.repos.map(\.id)
        let first = try model.createGroup(named: "First"), second = try model.createGroup(named: "Second")
        model.moveRepositories([ids[0]], to: first)
        model.moveRepositories([ids[1]], to: second)
        try model.renameGroup(first, to: "Renamed")
        model.moveGroup(second, by: -1)
        XCTAssertEqual(model.organization.groups.map(\.name), ["Second", "Renamed"])
        XCTAssertEqual(model.orderedRepos.map(\.id), Array(ids.reversed()))
        model.selection = Set(ids)
        model.removeGroup(first)
        XCTAssertEqual(model.repositories(in: nil).map(\.id), [ids[0]])
        XCTAssertEqual(model.organization.groupByRepository[ids[1]], second)
        XCTAssertEqual(model.sources, sources)
        XCTAssertEqual(model.selection, Set(ids))
        XCTAssertEqual(model.repos.count, 2)
        XCTAssertEqual(try store.load().organization, model.organization)
    }

    func testInvalidMovesAndNamesDoNotChangeOrSaveState() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        try store.save(StoredState(sources: [remote("a"), remote("b")]))
        var saves = 0
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: OrganizationRunner()) }, saveState: { _ in saves += 1 })
        await model.refreshAll(fetch: false)
        let group = try model.createGroup(named: "Work")
        let ids = model.repos.map(\.id)
        model.moveRepositories([ids[0]], to: group)
        let initial = model.organization, initialSaves = saves
        XCTAssertThrowsError(try model.createGroup(named: " \n "))
        XCTAssertThrowsError(try model.createGroup(named: "work"))
        XCTAssertThrowsError(try model.renameGroup(UUID(), to: "Unknown"))
        XCTAssertFalse(model.moveRepositories(["unknown"], to: group))
        XCTAssertFalse(model.moveRepositories([ids[0]], to: UUID()))
        XCTAssertFalse(model.moveRepositories([ids[0]], to: group, before: ids[0]))
        XCTAssertFalse(model.moveRepositories([ids[1]], to: nil, before: "unknown"))
        XCTAssertFalse(model.moveRepositories([ids[1]], to: nil, before: ids[0]))
        model.moveRepository(ids[0], by: -1)
        model.moveGroup(group, by: -1)
        model.removeGroup(UUID())
        try model.renameGroup(group, to: "Work")
        XCTAssertEqual(model.organization, initial)
        XCTAssertEqual(saves, initialSaves)
    }

    func testUnavailableRepositoryReturnsToSavedGroupAndPosition() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder"), git = folder.appendingPathComponent("local/.git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let store = Store(directory: root.appendingPathComponent("state"))
        try store.save(StoredState(sources: [.local(LocalFolderSource(path: folder.path)), remote("a"), remote("b")]))
        let model = model(store: store)
        await model.refreshAll(fetch: false)
        let ids = model.repos.map(\.id)
        let group = try model.createGroup(named: "Work")
        model.moveRepositories(Set(ids), to: group)
        model.moveRepository(ids[1], by: -1)
        try FileManager.default.removeItem(at: git)
        await model.refreshAll(fetch: false)
        XCTAssertEqual(model.repositories(in: group).map(\.id), [ids[1], ids[2]])
        model.moveRepository(ids[2], by: -1)
        let restored = self.model(store: store)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        await restored.refreshAll(fetch: false)
        XCTAssertEqual(restored.repositories(in: group).map(\.id), [ids[2], ids[1], ids[0]])
    }

    func testSharedSourceRemovalKeepsOrganizationAndFinalRemovalClearsIt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let parent = RepoSource.local(LocalFolderSource(path: root.path)), direct = RepoSource.local(LocalFolderSource(path: repo.path))
        let store = Store(directory: root.appendingPathComponent("state"))
        try store.save(StoredState(sources: [parent, direct]))
        let model = model(store: store)
        await model.refreshAll(fetch: false)
        let id = try XCTUnwrap(model.repos.first?.id), group = try model.createGroup(named: "Shared")
        model.moveRepositories([id], to: group)
        model.removeSource(parent.id)
        XCTAssertEqual(model.organization.groupByRepository[id], group)
        XCTAssertEqual(model.repositories(in: group).map(\.id), [id])
        model.removeSource(direct.id)
        XCTAssertNil(model.organization.groupByRepository[id])
        XCTAssertFalse(model.organization.repositoryOrder.contains(id))
        XCTAssertEqual(model.organization.groups.map(\.id), [group])
    }

    func testEditedRemoteKeepsGroupOrderAndSelection() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = RemoteRepoSource(host: "host", path: "/old"), store = Store(directory: root)
        try store.save(StoredState(sources: [.remote(source), remote("other")]))
        let model = model(store: store)
        await model.refreshAll(fetch: false)
        let ids = model.repos.map(\.id), group = try model.createGroup(named: "Work")
        model.moveRepositories(Set(ids), to: group)
        model.selection = [ids[0]]
        let updated = RemoteRepoSource(id: source.id, host: "new-host", path: "/new")
        try model.updateRemote(updated)
        while model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        await model.refreshAll(fetch: false)
        let newID = RepoLocation(source: .remote(updated), path: updated.path).id
        XCTAssertEqual(model.repositories(in: group).map(\.id), [newID, ids[1]])
        XCTAssertEqual(model.selection, [newID])
        XCTAssertNil(model.organization.groupByRepository[ids[0]])
        XCTAssertEqual(try store.load().organization, model.organization)
    }

    func testNestedGroupTraversalCountsAndCollapseSurviveRestart() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        try store.save(StoredState(sources: [remote("a"), remote("b"), remote("quiet"), remote("other")]))
        let model = model(store: store)
        await model.refreshAll(fetch: false)
        let ids = model.repos.map(\.id)
        let work = try model.createGroup(named: "Work")
        let other = try model.createGroup(named: "Other")
        let client = try model.createGroup(named: "Client", parentID: work)
        let backend = try model.createGroup(named: "Backend", parentID: client)
        model.moveRepositories([ids[0]], to: work)
        model.moveRepositories([ids[1]], to: client)
        model.moveRepositories([ids[2]], to: backend)
        model.moveRepositories([ids[3]], to: other)
        XCTAssertEqual(model.organization.outline().map(\.id), [work, client, backend, other])
        XCTAssertEqual(model.organization.outline().map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(model.organization.path(of: backend), "Work / Client / Backend")
        XCTAssertEqual(model.repositoryCount(in: work), 3)
        XCTAssertEqual(model.repositoryCount(in: client), 2)
        XCTAssertEqual(model.repositoryCount(in: backend), 1)
        XCTAssertEqual(model.orderedRepos.map(\.id), ids)
        model.selection = [ids[2]]
        model.setGroupExpanded(client, to: false)
        model.setGroupExpanded(nil, to: false)
        XCTAssertEqual(model.organization.outline(visibleOnly: true).map(\.id), [work, client, other])
        XCTAssertEqual(model.selectedRepo?.id, ids[2], "Collapsing must not lose repository selection or status")
        model.needsAttentionOnly = true
        XCTAssertEqual(model.repositoryCount(in: work), 3, "Counts include clean and collapsed descendants")
        XCTAssertEqual(model.visibleRepos.map(\.id), [ids[0], ids[1], ids[3]])
        let restored = self.model(store: store)
        await restored.refreshAll(fetch: false)
        XCTAssertEqual(restored.organization, model.organization)
        XCTAssertFalse(restored.organization.ungroupedExpanded)
        XCTAssertEqual(restored.organization.outline(visibleOnly: true).map(\.id), [work, client, other])
        XCTAssertEqual(restored.orderedRepos.map(\.id), ids)
        restored.setGroupExpanded(work, to: false)
        XCTAssertEqual(restored.organization.outline(visibleOnly: true).map(\.id), [work, other])
        restored.setGroupExpanded(work, to: true)
        XCTAssertEqual(restored.organization.outline(visibleOnly: true).map(\.id), [work, client, other], "Child collapse state survives a parent toggle")
    }

    func testGroupDropReordersNestsAndUnnestsWholeSubtrees() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        let model = model(store: store)
        let a = try model.createGroup(named: "A"), b = try model.createGroup(named: "B"), c = try model.createGroup(named: "C")
        let child = try model.createGroup(named: "Child", parentID: a)
        let grandchild = try model.createGroup(named: "Grandchild", parentID: child)
        XCTAssertTrue(model.dropGroup(c, on: a, position: .before))
        XCTAssertEqual(model.organization.children(of: nil).map(\.id), [c, a, b])
        XCTAssertTrue(model.dropGroup(c, on: b, position: .after))
        XCTAssertEqual(model.organization.children(of: nil).map(\.id), [a, b, c])
        model.setGroupExpanded(b, to: false)
        XCTAssertTrue(model.dropGroup(a, on: b, position: .inside))
        XCTAssertEqual(model.organization.outline().map(\.id), [b, a, child, grandchild, c])
        XCTAssertEqual(model.organization.outline().map(\.depth), [0, 1, 2, 3, 0])
        XCTAssertTrue(try XCTUnwrap(model.organization.groups.first { $0.id == b }).isExpanded)
        XCTAssertTrue(model.dropGroup(child, on: a, position: .after))
        XCTAssertEqual(model.organization.children(of: b).map(\.id), [a, child], "An edge drop reparents to the target's sibling level")
        XCTAssertEqual(model.organization.children(of: child).map(\.id), [grandchild])
        XCTAssertTrue(model.dropGroup(child, on: nil, position: .inside))
        XCTAssertEqual(model.organization.children(of: nil).map(\.id), [b, c, child])
        XCTAssertEqual(model.organization.path(of: grandchild), "Child / Grandchild")
        model.moveGroup(child, by: -1)
        XCTAssertEqual(model.organization.children(of: nil).map(\.id), [b, child, c])
        XCTAssertEqual(try store.load().organization, model.organization)
    }

    func testInvalidGroupDropsCannotCreateCyclesOrChangeSavedState() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        var saves = 0
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: OrganizationRunner()) }, saveState: { _ in saves += 1 })
        let a = try model.createGroup(named: "A")
        let child = try model.createGroup(named: "Child", parentID: a)
        let grandchild = try model.createGroup(named: "Grandchild", parentID: child)
        let previous = model.organization, previousSaves = saves
        for position: GroupDropPosition in [.before, .inside, .after] {
            XCTAssertFalse(model.canDropGroup(a, on: a, position: position))
            XCTAssertFalse(model.dropGroup(a, on: a, position: position))
            XCTAssertFalse(model.dropGroup(a, on: grandchild, position: position))
            XCTAssertFalse(model.dropGroup(a, on: child, position: position))
            XCTAssertFalse(model.dropGroup(UUID(), on: child, position: position))
            XCTAssertFalse(model.dropGroup(child, on: UUID(), position: position))
        }
        XCTAssertFalse(model.moveGroup(a, to: UUID()))
        XCTAssertFalse(model.moveGroup(child, to: nil, before: grandchild))
        XCTAssertFalse(model.dropGroup(child, on: nil, position: .before))
        XCTAssertThrowsError(try model.createGroup(named: "Unknown", parentID: UUID()))
        XCTAssertEqual(model.organization, previous)
        XCTAssertEqual(saves, previousSaves)
    }

    func testSiblingNamesAndMovesRespectHierarchy() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(store: Store(directory: root))
        let work = try model.createGroup(named: "Work"), personal = try model.createGroup(named: "Personal")
        let first = try model.createGroup(named: "Projects", parentID: work)
        let second = try model.createGroup(named: "Projects", parentID: personal)
        let other = try model.createGroup(named: "Other", parentID: personal)
        XCTAssertThrowsError(try model.createGroup(named: " projects ", parentID: work))
        XCTAssertThrowsError(try model.renameGroup(other, to: "PROJECTS"))
        XCTAssertFalse(model.dropGroup(first, on: personal, position: .inside), "Duplicate sibling names must be refused")
        model.moveGroup(other, by: -1)
        XCTAssertEqual(model.organization.children(of: personal).map(\.id), [other, second])
        XCTAssertEqual(model.organization.children(of: nil).map(\.id), [work, personal])
        try model.renameGroup(second, to: "Private")
        XCTAssertTrue(model.dropGroup(first, on: second, position: .before))
        XCTAssertEqual(model.organization.children(of: personal).map(\.id), [other, first, second])
        XCTAssertTrue(model.organization.children(of: work).isEmpty)
    }

    func testNestedDissolvePromotesChildrenInPlaceWithoutRemovingRepos() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        let sources = [remote("a"), remote("b"), remote("c")]
        try store.save(StoredState(sources: sources))
        let model = model(store: store)
        await model.refreshAll(fetch: false)
        let ids = model.repos.map(\.id), parent = try model.createGroup(named: "Parent")
        let removed = try model.createGroup(named: "Removed", parentID: parent)
        let sibling = try model.createGroup(named: "Sibling", parentID: parent)
        let child = try model.createGroup(named: "Child", parentID: removed)
        let deep = try model.createGroup(named: "Deep", parentID: child)
        model.moveRepositories([ids[0]], to: removed)
        model.moveRepositories([ids[1]], to: child)
        model.moveRepositories([ids[2]], to: deep)
        model.selection = Set(ids)
        model.setGroupExpanded(child, to: false)
        model.removeGroup(removed)
        XCTAssertEqual(model.organization.children(of: parent).map(\.id), [child, sibling])
        XCTAssertEqual(model.organization.children(of: child).map(\.id), [deep])
        XCTAssertEqual(model.repositories(in: parent).map(\.id), [ids[0]])
        XCTAssertEqual(model.organization.groupByRepository[ids[1]], child)
        XCTAssertEqual(model.organization.groupByRepository[ids[2]], deep)
        XCTAssertFalse(try XCTUnwrap(model.organization.groups.first { $0.id == child }).isExpanded)
        XCTAssertEqual(model.repositoryCount(in: parent), 3)
        XCTAssertEqual(model.sources, sources)
        XCTAssertEqual(model.selection, Set(ids))
        XCTAssertEqual(model.repos.count, 3)
        model.removeGroup(parent)
        XCTAssertEqual(model.organization.children(of: nil).map(\.id), [child, sibling])
        XCTAssertEqual(model.repositories(in: nil).map(\.id), [ids[0]])
        XCTAssertEqual(try store.load().organization, model.organization)
    }

    func testAddingAndMovingIntoCollapsedGroupsExpandsAncestors() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        try store.save(StoredState(sources: [remote("repo")]))
        let model = model(store: store)
        await model.refreshAll(fetch: false)
        let id = try XCTUnwrap(model.repos.first?.id), parent = try model.createGroup(named: "Parent")
        let child = try model.createGroup(named: "Child", parentID: parent)
        model.setGroupExpanded(parent, to: false)
        model.setGroupExpanded(child, to: false)
        model.moveRepositories([id], to: child)
        XCTAssertTrue(model.organization.groups.allSatisfy(\.isExpanded))
        model.setGroupExpanded(parent, to: false)
        model.setGroupExpanded(child, to: false)
        let deep = try model.createGroup(named: "Deep", parentID: child)
        XCTAssertEqual(model.organization.outline(visibleOnly: true).map(\.id), [parent, child, deep])
        model.setGroupExpanded(nil, to: false)
        model.moveRepositories([id], to: nil)
        XCTAssertTrue(model.organization.ungroupedExpanded)
        XCTAssertEqual(model.sources.count, 1)
    }

    func testDissolvingKeepsPromotedNamesDistinctFromExistingSiblings() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(store: Store(directory: root))
        let removed = try model.createGroup(named: "Removed")
        let existing = try model.createGroup(named: "Projects")
        _ = try model.createGroup(named: "Projects (2)")
        let promoted = try model.createGroup(named: "projects", parentID: removed)
        let grandchild = try model.createGroup(named: "Deep", parentID: promoted)
        model.removeGroup(removed)
        XCTAssertEqual(model.organization.groups.first { $0.id == existing }?.name, "Projects")
        XCTAssertEqual(model.organization.groups.first { $0.id == promoted }?.name, "projects (3)")
        XCTAssertEqual(model.organization.children(of: promoted).map(\.id), [grandchild])
        XCTAssertTrue(model.dropGroup(promoted, on: existing, position: .after))
    }

    func testTextDragPayloadDistinguishesGroupsAndRepositoryIdentities() {
        let group = SidebarDragPayload.group(UUID())
        let repository = SidebarDragPayload.repository("remote:4:host:default:/folder/名 with spaces")
        XCTAssertEqual(SidebarDragPayload(string: group.string), group)
        XCTAssertEqual(SidebarDragPayload(string: repository.string), repository)
        for invalid in ["", "a file path", "gitmanager-group:", "gitmanager-group:not-a-uuid", "gitmanager-repository:"] {
            XCTAssertNil(SidebarDragPayload(string: invalid))
        }
    }

    func testTextDropsNestAndReorderGroupsWithoutLosingRepositories() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        try store.save(StoredState(sources: [remote("repo")]))
        let model = model(store: store)
        await model.refreshAll(fetch: false)
        let repoID = try XCTUnwrap(model.repos.first?.id)
        let a = try model.createGroup(named: "A"), b = try model.createGroup(named: "B"), c = try model.createGroup(named: "C")
        let child = try model.createGroup(named: "Child", parentID: a)
        let drag = SidebarDragPayload.group(a).string
        XCTAssertTrue(model.dropSidebarItem(drag, on: c, position: .after))
        XCTAssertEqual(model.organization.children(of: nil).map(\.id), [b, c, a])
        XCTAssertTrue(model.dropSidebarItem(drag, on: b, position: .before))
        XCTAssertEqual(model.organization.children(of: nil).map(\.id), [a, b, c])
        model.setGroupExpanded(b, to: false)
        XCTAssertTrue(model.dropSidebarItem(drag, on: b))
        XCTAssertEqual(model.organization.children(of: b).map(\.id), [a])
        XCTAssertEqual(model.organization.children(of: a).map(\.id), [child])
        XCTAssertTrue(try XCTUnwrap(model.organization.groups.first { $0.id == b }).isExpanded)
        XCTAssertTrue(model.dropSidebarItem(SidebarDragPayload.repository(repoID).string, on: child))
        XCTAssertEqual(model.repositories(in: child).map(\.id), [repoID])
        let previous = model.organization
        XCTAssertFalse(model.dropSidebarItem(SidebarDragPayload.group(b).string, on: child), "The decoded payload must still reject cycles")
        XCTAssertFalse(model.dropSidebarItem(drag, on: child, before: repoID), "Repository rows must never consume group drops")
        XCTAssertFalse(model.dropSidebarItem("gitmanager-group:invalid", on: b))
        XCTAssertFalse(model.dropSidebarItem(SidebarDragPayload.group(UUID()).string, on: b))
        XCTAssertFalse(model.dropSidebarItem(drag, on: UUID()))
        XCTAssertEqual(model.organization, previous)
        XCTAssertEqual(try store.load().organization, model.organization)
    }
}

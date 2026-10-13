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
}

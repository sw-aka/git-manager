import XCTest
@testable import GitManagerCore

private actor ControlledRunner: GitRunner {
    private var holdOperations = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var fetchCount = 0
    private(set) var pullCount = 0

    func hold() { holdOperations = true }
    func release() {
        holdOperations = false
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
    func run(args: [String], timeout: TimeInterval) async -> CommandResult {
        if args.first == "pull" { pullCount += 1 }
        if args.first == "fetch" { fetchCount += 1 }
        if holdOperations && (args.first == "fetch" || args.first == "pull") {
            await withCheckedContinuation { continuations.append($0) }
        }
        let output: String
        switch args.first {
        case "status": output = "# branch.head main\0# branch.upstream origin/main\0# branch.ab +1 -0\0"
        case "remote": output = "origin\n"
        default: output = ""
        }
        return CommandResult(stdout: output, stderr: "", exitCode: 0)
    }
}

private actor StatusConcurrencyRunner: GitRunner {
    private var active = 0
    private var maximum = 0
    private var statuses = 0
    private var fetches = 0

    func reset() { maximum = 0; statuses = 0; fetches = 0 }
    func counts() -> (maximum: Int, statuses: Int, fetches: Int) { (maximum, statuses, fetches) }
    func run(args: [String], timeout: TimeInterval) async -> CommandResult {
        active += 1
        maximum = max(maximum, active)
        if args.first == "status" { statuses += 1 }
        if args.first == "fetch" { fetches += 1 }
        try? await Task.sleep(for: .milliseconds(10))
        active -= 1
        let output = args.first == "status" ? "# branch.head main\0# branch.upstream origin/main\0# branch.ab +0 -0\0"
            : args.first == "remote" ? "origin\n" : ""
        return CommandResult(stdout: output, stderr: "", exitCode: 0)
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gitmanager-model-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testRecoveryPreservesBadFileAndShowsNoticeOnce() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        let original = Data("{ sources I cannot decode".utf8)
        try original.write(to: store.fileURL)
        let model = AppModel(store: store)
        XCTAssertTrue(model.sources.isEmpty)
        XCTAssertTrue(model.message?.contains("original file was kept") == true)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("state.corrupt-") && $0.pathExtension == "json" })
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        model.message = nil
        model.setInterval(12)
        XCTAssertEqual(try store.load().settings.fetchIntervalMinutes, 12)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertNil(AppModel(store: store).message)
    }

    func testReadFailureDisablesSavingAndPreservesExistingState() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        let original = store.fileURL.appendingPathComponent("important")
        try Data("keep me".utf8).write(to: original)
        let model = AppModel(store: store)
        XCTAssertTrue(model.message?.contains("saving is disabled") == true)
        model.setInterval(12)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "keep me")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("state.corrupt-") })
    }

    func testOverlappingSourcesDeduplicateAndShareBusyState() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("group/repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("repo alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo)
        let parent = RepoSource.local(LocalFolderSource(path: root.path))
        let direct = RepoSource.local(LocalFolderSource(path: repo.path))
        let linked = RepoSource.local(LocalFolderSource(path: alias.path))
        let store = Store(directory: root.appendingPathComponent("state"))
        try store.save(StoredState(sources: [parent, direct, linked]))
        let runner = ControlledRunner()
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: runner) })
        await model.refreshAll(fetch: false)
        XCTAssertEqual(model.repos.count, 1)
        XCTAssertEqual(model.syncRepos.count, 1)
        XCTAssertEqual(model.menuBarTitle, "1")
        let record = try XCTUnwrap(model.repos.first)
        XCTAssertEqual(record.sourceIDs, [parent.id, direct.id, linked.id])
        let aliasID = RepoLocation(source: linked, path: alias.path).id
        XCTAssertEqual(record.id, aliasID)
        await runner.hold()
        let first = Task { await model.refresh(record.id) }
        for _ in 0..<100 where await runner.fetchCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.busy, [record.id])
        let duplicate = Task { await model.refresh(aliasID) }
        try await Task.sleep(for: .milliseconds(50))
        await model.sync(aliasID)
        let pulls = await runner.pullCount
        XCTAssertEqual(pulls, 0, "Sync started while the same repository was fetching")
        let fetches = await runner.fetchCount
        XCTAssertEqual(fetches, 1, "Two sources started operations on the same repository")
        // Removing the primary source during an operation preserves its identity,
        // selection, status, and lock when another source still provides the repo.
        model.selection = [record.id]
        model.removeSource(parent.id)
        XCTAssertEqual(model.repos.count, 1)
        XCTAssertEqual(model.repos.first?.sourceIDs, [direct.id, linked.id])
        XCTAssertEqual(model.selection, [record.id])
        XCTAssertEqual(model.busy, [record.id])
        await model.refreshAll(fetch: false)
        XCTAssertEqual(model.repos.count, 1)
        XCTAssertEqual(model.repos.first?.sourceIDs, [direct.id, linked.id])
        await runner.release()
        await first.value
        await duplicate.value
        XCTAssertTrue(model.busy.isEmpty)
        model.removeSource(direct.id)
        XCTAssertEqual(model.repos.count, 1)
        model.removeSource(linked.id)
        XCTAssertTrue(model.repos.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testSyncingTracksInFlightSyncButNotRefresh() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let store = Store(directory: root.appendingPathComponent("state"))
        try store.save(StoredState(sources: [.local(LocalFolderSource(path: repo.path))]))
        let runner = ControlledRunner()
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: runner) })
        await model.refreshAll(fetch: false)
        let record = try XCTUnwrap(model.repos.first)
        XCTAssertTrue(model.syncing.isEmpty)

        await runner.hold()
        let sync = Task { await model.sync(record.id) }
        for _ in 0..<100 where await runner.pullCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.busy, [record.id])
        XCTAssertEqual(model.syncing, [record.id])
        await runner.release()
        await sync.value
        XCTAssertTrue(model.busy.isEmpty)
        XCTAssertTrue(model.syncing.isEmpty)

        await runner.hold()
        let refresh = Task { await model.refresh(record.id) }
        for _ in 0..<100 where await runner.fetchCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.busy, [record.id])
        XCTAssertTrue(model.syncing.isEmpty)
        await runner.release()
        await refresh.value
        XCTAssertTrue(model.busy.isEmpty)
        XCTAssertTrue(model.syncing.isEmpty)
    }

    func testRemoteIdentityAndRemovalKeepOtherProvider() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = RepoSource.remote(RemoteRepoSource(host: "user@host", port: 2222, path: "~/repo"))
        var raw = RemoteRepoSource(host: "user@host", port: 2222, path: "~/repo")
        raw.path = "~//group/.././repo/"
        let second = RepoSource.remote(raw)
        let otherPort = RepoSource.remote(RemoteRepoSource(host: "user@host", port: 2223, path: "~/repo"))
        let store = Store(directory: root)
        try store.save(StoredState(sources: [first, second, otherPort]))
        let runner = ControlledRunner()
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: runner) })
        await model.refreshAll(fetch: false)
        XCTAssertEqual(model.repos.count, 2)
        let shared = try XCTUnwrap(model.repos.first { $0.sourceIDs.contains(first.id) })
        XCTAssertEqual(shared.sourceIDs, [first.id, second.id])
        let aliasID = RepoLocation(source: second, path: raw.path).id
        XCTAssertEqual(shared.id, aliasID)
        await runner.hold()
        let firstRefresh = Task { await model.refresh(shared.id) }
        for _ in 0..<100 where await runner.fetchCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let secondRefresh = Task { await model.refresh(aliasID) }
        try await Task.sleep(for: .milliseconds(20))
        let fetches = await runner.fetchCount
        XCTAssertEqual(fetches, 1)
        await runner.release()
        await firstRefresh.value
        await secondRefresh.value
        model.removeSource(first.id)
        XCTAssertEqual(model.repos.count, 2)
        XCTAssertEqual(model.repos.first { $0.id == shared.id }?.sourceIDs, [second.id])
    }

    func testBulkRemovalSavesOnceAndKeepsOtherProvidersAndSelections() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sharedURL = root.appendingPathComponent("shared")
        let exclusiveURL = root.appendingPathComponent("exclusive")
        for url in [sharedURL, exclusiveURL] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        }
        let folder = RepoSource.local(LocalFolderSource(path: root.path))
        let direct = RepoSource.local(LocalFolderSource(path: sharedURL.path))
        let missing = RepoSource.local(LocalFolderSource(path: root.appendingPathComponent("missing").path))
        let remote = RepoSource.remote(RemoteRepoSource(host: "host", path: "/remove"))
        let keptRemote = RepoSource.remote(RemoteRepoSource(host: "host", path: "/keep"))
        let store = Store(directory: root.appendingPathComponent("state"))
        try store.save(StoredState(sources: [folder, direct, missing, remote, keptRemote]))
        var savedStates: [StoredState] = []
        let runner = ControlledRunner()
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: runner) }, saveState: {
            savedStates.append($0)
            try store.save($0)
        })
        model.selection = ["stale selection"]
        await model.refreshAll(fetch: false)
        XCTAssertTrue(model.selection.isEmpty, "Rescanning must clear stale selections")
        let shared = try XCTUnwrap(model.repos.first { $0.sourceIDs.contains(direct.id) })
        let kept = try XCTUnwrap(model.repos.first { $0.sourceIDs.contains(keptRemote.id) })
        model.selection = Set(model.repos.map(\.id))
        XCTAssertNil(model.selectedRepo)
        XCTAssertEqual(model.selectedRepos.count, 4)
        XCTAssertNotNil(model.sourceScanErrors[missing.id])

        model.removeSources([folder.id, missing.id, remote.id])

        XCTAssertEqual(savedStates.count, 1)
        XCTAssertEqual(Set(savedStates[0].sources.map(\.id)), [direct.id, keptRemote.id])
        XCTAssertEqual(Set(try store.load().sources.map(\.id)), [direct.id, keptRemote.id])
        XCTAssertEqual(model.sources.map(\.id), [direct.id, keptRemote.id])
        XCTAssertEqual(Set(model.repos.map(\.id)), [shared.id, kept.id])
        XCTAssertEqual(model.repos.first { $0.id == shared.id }?.sourceIDs, [direct.id])
        XCTAssertEqual(model.repos.first { $0.id == shared.id }?.status, shared.status)
        XCTAssertEqual(model.selection, [shared.id, kept.id])
        XCTAssertTrue(model.sourceScanErrors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exclusiveURL.path), "Removal must leave files on disk")

        model.removeSources([])
        model.removeSources([UUID()])
        XCTAssertEqual(savedStates.count, 1, "Empty and stale plans must not save")
        model.removeSource(keptRemote.id)
        XCTAssertEqual(savedStates.count, 2, "Single removal must use the same persistence path")
        XCTAssertEqual(model.selection, [shared.id])
        XCTAssertEqual(model.selectedRepo?.id, shared.id)
        model.removeSource(direct.id)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.selectedRepo)
    }

    func testAddRemoteRefusesEquivalentIdentityAndPersistsNormalizedSource() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var oldSource = RemoteRepoSource(host: "User@HOST", path: "/srv/repo")
        oldSource.path = "/srv/./repo/"
        let store = Store(directory: root)
        try store.save(StoredState(sources: [.remote(oldSource)]))
        let runner = ControlledRunner()
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: runner) })
        for path in ["/srv/repo/", "/srv/./repo", "/srv//other/../repo/"] {
            XCTAssertThrowsError(try model.addRemote(RemoteRepoSource(host: "User@HOST", path: path))) { error in
                XCTAssertTrue(error.localizedDescription.contains("already added"))
            }
        }
        XCTAssertEqual(model.sources.count, 1)
        try model.addRemote(RemoteRepoSource(host: "User@OTHER-HOST", port: 2222, path: "~//other/../repo/"))
        let stored = try store.load()
        guard case .remote(let added) = stored.sources.last else { return XCTFail("Remote source was not saved") }
        XCTAssertEqual(added.host, "User@OTHER-HOST")
        XCTAssertEqual(added.path, "~/repo")
        XCTAssertEqual(added.port, 2222)
        await model.refreshAll(fetch: false)
        XCTAssertEqual(model.repos.count, 2)
    }

    func testUpdateRemoteKeepsIdentityRefusesDuplicatesAndMovesSelection() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let edited = RemoteRepoSource(host: "host", path: "/srv/typo'")
        let other = RemoteRepoSource(host: "host", path: "/srv/other")
        let store = Store(directory: root)
        try store.save(StoredState(sources: [.remote(edited), .remote(other)]))
        let runner = ControlledRunner()
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: runner) })
        await model.refreshAll(fetch: false)
        let oldID = RepoLocation(source: .remote(edited), path: edited.path).id
        model.selection = [oldID]

        XCTAssertThrowsError(try model.updateRemote(RemoteRepoSource(id: edited.id, host: "host", path: "/srv/./other/"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("already added"))
        }
        XCTAssertThrowsError(try model.updateRemote(RemoteRepoSource(id: edited.id, host: "host", path: "relative")))
        XCTAssertThrowsError(try model.updateRemote(RemoteRepoSource(host: "host", path: "/srv/new"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("removed"))
        }
        XCTAssertEqual(model.sources, [.remote(edited), .remote(other)])
        try model.updateRemote(edited)

        try model.updateRemote(RemoteRepoSource(id: edited.id, host: "user@host", port: 2222, path: "/srv/space dir//./repo/"))
        let expected = RemoteRepoSource(id: edited.id, host: "user@host", port: 2222, path: "/srv/space dir/repo")
        XCTAssertEqual(model.sources, [.remote(expected), .remote(other)])
        XCTAssertEqual(try store.load().sources, [.remote(expected), .remote(other)])
        let newID = RepoLocation(source: .remote(expected), path: expected.path).id
        XCTAssertFalse(model.repos.contains { $0.id == oldID }, "Records for the old location must be dropped at once")
        XCTAssertEqual(model.selection, [newID])
        while model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        await model.refreshAll(fetch: false)
        XCTAssertEqual(Set(model.repos.map(\.id)), [newID, RepoLocation(source: .remote(other), path: other.path).id])
        XCTAssertEqual(model.selectedRepo?.location.displayPath, "user@host:2222:/srv/space dir/repo")
    }

    func testUpdateLocalRescansNewFolderAndRefusesExistingFolder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldFolder = root.appendingPathComponent("old")
        let newFolder = root.appendingPathComponent("new")
        let otherFolder = root.appendingPathComponent("other")
        for url in [oldFolder, newFolder, otherFolder] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        }
        let source = LocalFolderSource(path: oldFolder.path)
        let other = LocalFolderSource(path: otherFolder.path)
        let store = Store(directory: root.appendingPathComponent("state"))
        try store.save(StoredState(sources: [.local(source), .local(other)]))
        let runner = ControlledRunner()
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: runner) })
        await model.refreshAll(fetch: false)
        XCTAssertEqual(model.repos.count, 2)

        XCTAssertThrowsError(try model.updateLocal(source.id, to: otherFolder)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already added"))
        }
        XCTAssertThrowsError(try model.updateLocal(UUID(), to: newFolder))
        try model.updateLocal(source.id, to: newFolder)

        let newPath = RepoLocation.canonicalLocalPath(newFolder.path)
        let expected = RepoSource.local(LocalFolderSource(id: source.id, path: newPath))
        XCTAssertEqual(model.sources, [expected, .local(other)])
        XCTAssertEqual(try store.load().sources, [expected, .local(other)])
        XCTAssertFalse(model.repos.contains { $0.sourceIDs.contains(source.id) })
        while model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        await model.refreshAll(fetch: false)
        let edited = try XCTUnwrap(model.repos.first { $0.sourceIDs.contains(source.id) })
        XCTAssertEqual(edited.location.path, RepoLocation.canonicalLocalPath(newFolder.appendingPathComponent("repo").path))
        XCTAssertEqual(model.repos.count, 2)
    }

    func testCaseDistinctSSHAliasesRemainSeparateAfterAddingAndLoading() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        let runner = ControlledRunner()
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: runner) })
        try model.addRemote(RemoteRepoSource(host: "MIXED-ALIAS", path: "/srv/./repo/"))
        try model.addRemote(RemoteRepoSource(host: "mixed-alias", path: "/srv/repo"))
        XCTAssertEqual(model.sources.count, 2)
        let restored = AppModel(store: store, serviceFactory: { _ in RepoService(runner: runner) })
        await restored.refreshAll(fetch: false)
        XCTAssertEqual(restored.repos.count, 2)
        XCTAssertEqual(Set(restored.sources.map(\.title)), ["MIXED-ALIAS", "mixed-alias"])
        XCTAssertThrowsError(try restored.addRemote(RemoteRepoSource(host: "MIXED-ALIAS", path: "/srv//repo/")))
        await model.refreshAll(fetch: false)
    }

    func testSourceScanErrorsKeepAccessibleReposAndClearAfterRecovery() async throws {
        let root = try temporaryDirectory()
        let blocked = root.appendingPathComponent("blocked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: root)
        }
        let accessible = root.appendingPathComponent("accessible")
        try FileManager.default.createDirectory(at: accessible.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        let source = RepoSource.local(LocalFolderSource(path: root.path))
        let missing = RepoSource.local(LocalFolderSource(path: root.appendingPathComponent("absent").path))
        let store = Store(directory: root.appendingPathComponent("state"))
        try store.save(StoredState(sources: [source, missing]))
        let runner = ControlledRunner()
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: runner) })
        await model.refreshAll(fetch: false)
        XCTAssertEqual(model.repos.map(\.location.path), [RepoLocation.canonicalLocalPath(accessible.path)])
        XCTAssertNil(model.repos.first?.status.error)
        XCTAssertEqual(model.sourceScanErrors[source.id]?.count, 1)
        XCTAssertTrue(model.sourceScanErrors[source.id]?.first?.path.hasSuffix("/blocked") == true)
        XCTAssertEqual(model.sourceScanErrors[missing.id]?.count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
        await model.refreshAll(fetch: false)
        XCTAssertNil(model.sourceScanErrors[source.id])
        // Missing roots report source errors without inventing repositories.
        XCTAssertEqual(model.sourceScanErrors[missing.id]?.count, 1)
        model.removeSource(missing.id)
        try FileManager.default.removeItem(at: accessible)
        try FileManager.default.removeItem(at: blocked)
        await model.refreshAll(fetch: false)
        XCTAssertTrue(model.repos.isEmpty)
        model.removeSource(source.id)
        XCTAssertTrue(model.sourceScanErrors.isEmpty)
    }

    func testLargeStatusAndIndividualRefreshBatchesShareConcurrencyLimit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = (0..<36).map { RepoSource.remote(RemoteRepoSource(host: "host", path: "/repo-\($0)")) }
        let store = Store(directory: root)
        try store.save(StoredState(sources: sources))
        let runner = StatusConcurrencyRunner()
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: runner) })
        await model.refreshAll(fetch: false)
        let initial = await runner.counts()
        XCTAssertEqual(initial.statuses, 36)
        XCTAssertEqual(initial.fetches, 0)
        XCTAssertEqual(initial.maximum, 4)
        await runner.reset()
        await withTaskGroup(of: Void.self) { group in
            for (index, id) in model.repos.map(\.id).enumerated() {
                group.addTask { await model.refresh(id, fetch: index.isMultiple(of: 2)) }
            }
        }
        let individual = await runner.counts()
        XCTAssertEqual(individual.statuses, 36)
        XCTAssertEqual(individual.fetches, 18)
        XCTAssertEqual(individual.maximum, 4)
        XCTAssertTrue(model.busy.isEmpty)
    }
}

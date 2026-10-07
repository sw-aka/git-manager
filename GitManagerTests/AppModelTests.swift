import XCTest
@testable import GitManagerCore

private actor ControlledRunner: GitRunner {
    private var holdFetch = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var fetchCount = 0
    private(set) var pullCount = 0

    func hold() { holdFetch = true }
    func release() {
        holdFetch = false
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
    func run(args: [String], timeout: TimeInterval) async -> CommandResult {
        if args.first == "pull" { pullCount += 1 }
        if args.first == "fetch" {
            fetchCount += 1
            if holdFetch { await withCheckedContinuation { continuations.append($0) } }
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
        model.selection = record.id
        model.removeSource(parent.id)
        XCTAssertEqual(model.repos.count, 1)
        XCTAssertEqual(model.repos.first?.sourceIDs, [direct.id, linked.id])
        XCTAssertEqual(model.selection, record.id)
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
        XCTAssertNil(model.selection)
    }

    func testRemoteIdentityAndRemovalKeepOtherProvider() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = RepoSource.remote(RemoteRepoSource(host: "user@host", port: 2222, path: "~/repo"))
        var raw = RemoteRepoSource(host: "user@host", port: 2222, path: "~/repo")
        raw.host = "user@HOST"
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

    func testAddRemoteRefusesEquivalentIdentityAndPersistsNormalizedSource() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var oldSource = RemoteRepoSource(host: "User@host", path: "/srv/repo")
        oldSource.host = "User@HOST"
        oldSource.path = "/srv/./repo/"
        let store = Store(directory: root)
        try store.save(StoredState(sources: [.remote(oldSource)]))
        let runner = ControlledRunner()
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: runner) })
        for path in ["/srv/repo/", "/srv/./repo", "/srv//other/../repo/"] {
            XCTAssertThrowsError(try model.addRemote(RemoteRepoSource(host: "User@host", path: path))) { error in
                XCTAssertTrue(error.localizedDescription.contains("already added"))
            }
        }
        XCTAssertEqual(model.sources.count, 1)
        try model.addRemote(RemoteRepoSource(host: "User@OTHER-HOST", port: 2222, path: "~//other/../repo/"))
        let stored = try store.load()
        guard case .remote(let added) = stored.sources.last else { return XCTFail("Remote source was not saved") }
        XCTAssertEqual(added.host, "User@other-host")
        XCTAssertEqual(added.path, "~/repo")
        XCTAssertEqual(added.port, 2222)
        await model.refreshAll(fetch: false)
        XCTAssertEqual(model.repos.count, 2)
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


}

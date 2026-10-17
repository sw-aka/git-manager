import XCTest
@testable import GitManagerCore

final class ConfigurationTransferTests: XCTestCase {
    func testRoundTripKeepsNestedEmptyGroupsSourcesAndRepositoryOrder() throws {
        let folder = RepoSource.local(LocalFolderSource(path: "/Users/example/Work's 名"))
        let remote = RepoSource.remote(RemoteRepoSource(host: "me@WorkAlias", port: 2222, path: "~/project"))
        let work = RepoGroup(name: "Work", isExpanded: false)
        let nested = RepoGroup(name: "Nested", parentID: work.id)
        let empty = RepoGroup(name: "Empty")
        let local = RepoLocation(source: folder, path: "/Users/example/Work's 名/repo")
        let ssh = RepoLocation(source: remote, path: "~/project")
        let missing = "local:/temporarily/unavailable"
        let state = StoredState(sources: [remote, folder],
                                settings: AppSettings(fetchIntervalMinutes: 23, repositoryEditors: [ssh.id: .vsCode]),
                                organization: RepoOrganization(groups: [work, nested, empty],
                                    repositoryOrder: [ssh.id, local.id, missing],
                                    groupByRepository: [ssh.id: work.id, local.id: work.id, missing: nested.id],
                                    ungroupedExpanded: false))
        let discovered = RepoRecord(location: RepoLocation(source: folder, path: "/Users/example/Work's 名/new"))
        let text = try ConfigurationTransfer.export(state, repositories: [RepoRecord(location: local), discovered])
        XCTAssertTrue(text.contains("WorkAlias"))
        XCTAssertTrue(text.contains("/Users/example/Work's 名"))
        XCTAssertTrue(text.contains("\"repositories\""))
        let restored = try ConfigurationTransfer.parse(text)
        XCTAssertEqual(restored.sources, state.sources)
        XCTAssertEqual(restored.settings, state.settings)
        XCTAssertEqual(restored.organization.groups, state.organization.groups)
        XCTAssertEqual(restored.organization.groupByRepository, state.organization.groupByRepository)
        XCTAssertEqual(restored.organization.repositoryOrder, [ssh.id, local.id, missing, discovered.id])
        XCTAssertFalse(restored.organization.ungroupedExpanded)
        XCTAssertEqual(try ConfigurationTransfer.export(restored, repositories: []), text)
    }

    func testUnrankedUnavailableMembershipAndEmptySetupSurvive() throws {
        let group = RepoGroup(name: "Offline")
        let state = StoredState(organization: RepoOrganization(groups: [group], groupByRepository: ["local:/offline": group.id]))
        let restored = try ConfigurationTransfer.parse(ConfigurationTransfer.export(state, repositories: []))
        XCTAssertEqual(restored.organization.repositoryOrder, ["local:/offline"])
        XCTAssertEqual(restored.organization.groupByRepository, state.organization.groupByRepository)
        XCTAssertEqual(try ConfigurationTransfer.parse(ConfigurationTransfer.export(StoredState(), repositories: [])), StoredState())
    }

    func testMalformedUnsupportedAndIncompleteDocumentsFail() throws {
        for text in ["", "not JSON", "{}", "{\"sources\": []}"] {
            XCTAssertThrowsError(try ConfigurationTransfer.parse(text))
        }
        try assertInvalid { $0["version"] = 99 }
        try assertInvalid { $0["format"] = "another-app" }
        try assertInvalid { $0["groups"] = NSNull() }
        try assertInvalid { $0["repositoryEditors"] = ["repo": "unknown-editor"] }
        try assertInvalid { $0["fetchIntervalMinutes"] = 0 }
    }

    func testInvalidSourcesAndGroupRelationshipsAreRejected() throws {
        try assertInvalid { object in
            var sources = object["sources"] as! [[String: Any]]
            sources.append(sources[0]); object["sources"] = sources
        }
        for (key, value): (String, Any) in [("host", "-oProxyCommand=bad"), ("port", 65536), ("path", "relative/path"), ("kind", "unknown")] {
            try assertInvalid { object in
                var sources = object["sources"] as! [[String: Any]]
                sources[0][key] = value; object["sources"] = sources
            }
        }
        try assertInvalid { object in
            object["sources"] = [["id": UUID().uuidString, "kind": "local", "path": "relative"]]
        }
        try assertInvalid { object in
            var groups = object["groups"] as! [[String: Any]]
            groups[0]["parentID"] = groups[0]["id"]; object["groups"] = groups
        }
        try assertInvalid { object in
            var groups = object["groups"] as! [[String: Any]]
            groups[0]["parentID"] = UUID().uuidString; object["groups"] = groups
        }
        try assertInvalid { object in
            var groups = object["groups"] as! [[String: Any]]
            groups.append(groups[0]); object["groups"] = groups
        }
        try assertInvalid { object in
            var groups = object["groups"] as! [[String: Any]]
            var duplicate = groups[0]; duplicate["id"] = UUID().uuidString
            duplicate["repositories"] = []; groups.append(duplicate); object["groups"] = groups
        }
        try assertInvalid { $0["ungrouped"] = ["remote-repo", "remote-repo"] }
        try assertInvalid { object in
            let groups = object["groups"] as! [[String: Any]]
            object["ungrouped"] = groups[0]["repositories"]
        }
    }

    private func assertInvalid(_ mutate: (inout [String: Any]) -> Void) throws {
        let source = RepoSource.remote(RemoteRepoSource(host: "Work", path: "~/repo"))
        let group = RepoGroup(name: "Work")
        let id = RepoLocation(source: source, path: "~/repo").id
        let state = StoredState(sources: [source], organization: RepoOrganization(groups: [group],
            repositoryOrder: [id], groupByRepository: [id: group.id]))
        let text = try ConfigurationTransfer.export(state, repositories: [])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        mutate(&object)
        let invalid = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        XCTAssertThrowsError(try ConfigurationTransfer.parse(invalid))
    }
}

@MainActor
final class ConfigurationImportTests: XCTestCase {
    func testImportRestoresConfigurationAndPersistsBeforeRefreshing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let source = RepoSource.local(LocalFolderSource(path: root.path))
        let id = RepoLocation(source: source, path: repo.path).id
        let group = RepoGroup(name: "Restored", isExpanded: false)
        let imported = StoredState(sources: [source], settings: AppSettings(fetchIntervalMinutes: 19, repositoryEditors: [id: .vsCode]),
                                  organization: RepoOrganization(groups: [group], repositoryOrder: [id], groupByRepository: [id: group.id]))
        let store = Store(directory: root.appendingPathComponent("state"))
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: TransferRunner()) })
        model.selection = ["old"]
        model.needsAttentionOnly = true
        let text = try ConfigurationTransfer.export(imported, repositories: [])
        XCTAssertTrue(try model.importConfiguration(text, replacing: model.configurationState, removalPlan: model.configurationRemovalPlan))
        XCTAssertEqual(try store.load(), imported)
        XCTAssertEqual(model.configurationState, imported)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertFalse(model.needsAttentionOnly)
        // Allow the automatically scheduled discovery pass to finish.
        for _ in 0..<100 where model.repos.isEmpty || model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.orderedRepos.map(\.id), [id])
        XCTAssertEqual(model.organization.groupByRepository[id], group.id)
        XCTAssertEqual(AppModel(store: store).configurationState, imported)
    }

    func testChangedConfigurationOrRemovalCountsRequireAnotherReview() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = RepoSource.local(LocalFolderSource(path: root.path))
        let store = Store(directory: root.appendingPathComponent("state"))
        try store.save(StoredState(sources: [source]))
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: TransferRunner()) })
        let empty = try ConfigurationTransfer.export(StoredState(), repositories: [])
        let old = model.configurationState
        let plan = model.configurationRemovalPlan
        model.setInterval(12)
        XCTAssertFalse(try model.importConfiguration(empty, replacing: old, removalPlan: plan))
        let current = model.configurationState
        try FileManager.default.createDirectory(at: root.appendingPathComponent("new/.git"), withIntermediateDirectories: true)
        await model.refreshAll(fetch: false)
        XCTAssertFalse(try model.importConfiguration(empty, replacing: current, removalPlan: plan))
        XCTAssertEqual(model.sources, [source])
        XCTAssertEqual(try store.load(), current)
    }

    func testSaveFailureAndInvalidImportLeaveLiveAndSavedSetupUntouched() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        let original = StoredState(sources: [.local(LocalFolderSource(path: "/original"))])
        try store.save(original)
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: TransferRunner()) }, saveState: { _ in
            throw CocoaError(.fileWriteUnknown)
        })
        let text = try ConfigurationTransfer.export(StoredState(), repositories: [])
        for input in [text, "invalid"] {
            XCTAssertThrowsError(try model.importConfiguration(input, replacing: model.configurationState, removalPlan: model.configurationRemovalPlan))
            XCTAssertEqual(model.configurationState, original)
            XCTAssertEqual(try store.load(), original)
        }
    }

    func testImportWaitsForRepositoryOperationsToFinish() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        let source = RepoSource.remote(RemoteRepoSource(host: "example", path: "~/repo"))
        let original = StoredState(sources: [source])
        try store.save(original)
        let runner = ImportBlockingRunner()
        let model = AppModel(store: store, serviceFactory: { _ in RepoService(runner: runner) })
        let operation = Task { await model.refreshAll(fetch: false) }
        for _ in 0..<100 where !(await runner.called) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.isRefreshing)
        XCTAssertFalse(model.busy.isEmpty)
        let text = try ConfigurationTransfer.export(StoredState(), repositories: [])
        XCTAssertThrowsError(try model.importConfiguration(text, replacing: model.configurationState, removalPlan: model.configurationRemovalPlan))
        XCTAssertEqual(model.configurationState, original)
        XCTAssertEqual(try store.load(), original)
        await runner.release()
        await operation.value
    }

    func testImportCannotOverwriteStateWhenSavingIsDisabled() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        let model = AppModel(store: store)
        let text = try ConfigurationTransfer.export(StoredState(), repositories: [])
        XCTAssertThrowsError(try model.importConfiguration(text, replacing: model.configurationState, removalPlan: model.configurationRemovalPlan))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmanager-transfer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct TransferRunner: GitRunner {
    func run(args: [String], timeout: TimeInterval) async -> CommandResult {
        let output = args.first == "status" ? "# branch.head main\0" : ""
        return CommandResult(stdout: output, stderr: "", exitCode: 0)
    }
}

private actor ImportBlockingRunner: GitRunner {
    private(set) var called = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func run(args: [String], timeout: TimeInterval) async -> CommandResult {
        if !released {
            called = true
            await withCheckedContinuation { continuation = $0 }
        }
        return CommandResult(stdout: args.first == "status" ? "# branch.head main\0" : "", stderr: "", exitCode: 0)
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

import XCTest
@testable import GitManagerCore

final class StoreTests: XCTestCase {
    func testEditorPreferencesRoundTripAndTolerantMigration() throws {
        let state = StoredState(settings: AppSettings(fetchIntervalMinutes: 17,
                                                      repositoryEditors: ["local:/repo": .vsCode, "remote:repo": .zed]))
        let encoded = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(StoredState.self, from: encoded), state)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for editors: Any? in [nil, NSNull(), "invalid", ["local:/repo": "vsCode", "other": "futureEditor"]] {
            var object = original
            var settings = try XCTUnwrap(object["settings"] as? [String: Any])
            settings["repositoryEditors"] = editors
            object["settings"] = settings
            let decoded = try JSONDecoder().decode(StoredState.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.settings.fetchIntervalMinutes, 17)
            XCTAssertEqual(decoded.settings.repositoryEditors, editors is [String: String] ? ["local:/repo": .vsCode] : [:])
        }
    }

    func testRoundTripAndDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmanager-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        XCTAssertEqual(try store.load(), StoredState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let state = StoredState(sources: [
            .local(LocalFolderSource(path: "/tmp/local's folder")),
            .remote(RemoteRepoSource(host: "user@host", port: 2222, path: "/srv/名"))
        ], settings: AppSettings(fetchIntervalMinutes: 17))
        try store.save(state)
        XCTAssertEqual(try store.load(), state)
        try store.save(StoredState())
        XCTAssertEqual(try store.load(), StoredState())
    }
    func testMalformedDataIsReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmanager-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(directory: root)
        try Data("broken".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
    }
    func testSaveRefusesToOverwriteCorruptExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmanager-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(directory: root)
        let original = Data("broken but important".utf8)
        try original.write(to: store.fileURL)
        XCTAssertThrowsError(try store.save(StoredState()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testMissingUnknownAndInvalidSettingsPreserveSources() throws {
        let source = RepoSource.local(LocalFolderSource(path: "/some/project"))
        let encoded = try JSONEncoder().encode(StoredState(sources: [source]))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for settings: Any? in [nil, ["futureOption": true], ["fetchIntervalMinutes": "invalid"], NSNull()] {
            var object = original
            object["settings"] = settings
            let decoded = try JSONDecoder().decode(StoredState.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.sources, [source])
            XCTAssertEqual(decoded.settings.fetchIntervalMinutes, 5)
        }
    }

    func testSettingsClampInterval() {
        XCTAssertEqual(AppSettings(fetchIntervalMinutes: 0).validatedInterval, 1)
        XCTAssertEqual(AppSettings(fetchIntervalMinutes: 9999).validatedInterval, 1440)
    }

    func testOrganizationRoundTripAndOlderStateMigration() throws {
        let group = RepoGroup(name: "Work")
        let state = StoredState(sources: [.local(LocalFolderSource(path: "/project"))],
                                organization: RepoOrganization(groups: [group], repositoryOrder: ["local:/project"],
                                                               groupByRepository: ["local:/project": group.id]))
        let encoded = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(StoredState.self, from: encoded), state)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for organization: Any? in [nil, NSNull(), ["futureOption": true], "invalid"] {
            var object = original
            object["organization"] = organization
            let decoded = try JSONDecoder().decode(StoredState.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.sources, state.sources)
            XCTAssertEqual(decoded.organization, RepoOrganization())
        }
    }

    func testOrganizationNormalizesDuplicatesAndMissingGroups() throws {
        let group = RepoGroup(name: "Work")
        let state = StoredState(organization: RepoOrganization(groups: [group, group], repositoryOrder: ["a", "a", "b"],
                                                               groupByRepository: ["a": group.id, "b": UUID()]))
        let decoded = try JSONDecoder().decode(StoredState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.organization.groups, [group])
        XCTAssertEqual(decoded.organization.repositoryOrder, ["a", "b"])
        XCTAssertEqual(decoded.organization.groupByRepository, ["a": group.id])
    }

    func testFlatGroupStateMigratesWithoutLosingMembershipOrOrder() throws {
        let group = RepoGroup(name: "Work")
        let state = StoredState(organization: RepoOrganization(groups: [group], repositoryOrder: ["b", "a"],
                                                               groupByRepository: ["a": group.id, "b": group.id]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var organization = try XCTUnwrap(object["organization"] as? [String: Any])
        organization["ungroupedExpanded"] = nil
        organization["groups"] = [["id": group.id.uuidString, "name": group.name]]
        object["organization"] = organization
        let decoded = try JSONDecoder().decode(StoredState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, state)
        XCTAssertNil(decoded.organization.groups[0].parentID)
        XCTAssertTrue(decoded.organization.groups[0].isExpanded)
        XCTAssertTrue(decoded.organization.ungroupedExpanded)
    }

    func testInvalidGroupParentsAreRepairedWithoutLosingRepositories() throws {
        let a = UUID(), b = UUID(), c = UUID(), orphan = UUID(), child = UUID(), selfParent = UUID()
        let groups = [RepoGroup(id: child, name: "Child", parentID: orphan),
                      RepoGroup(id: orphan, name: "Orphan", parentID: UUID()),
                      RepoGroup(id: a, name: "A", parentID: b),
                      RepoGroup(id: b, name: "B", parentID: c),
                      RepoGroup(id: c, name: "C", parentID: a),
                      RepoGroup(id: selfParent, name: "Self", parentID: selfParent)]
        let source = RepoSource.local(LocalFolderSource(path: "/project"))
        let state = StoredState(sources: [source], organization: RepoOrganization(groups: groups, repositoryOrder: ["repo"],
                                                                                groupByRepository: ["repo": c], ungroupedExpanded: false))
        let decoded = try JSONDecoder().decode(StoredState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.sources, [source])
        XCTAssertEqual(Set(decoded.organization.outline().map(\.id)), Set(groups.map(\.id)))
        XCTAssertEqual(decoded.organization.groups.first { $0.id == child }?.parentID, orphan, "Repair orphan roots without detaching valid children")
        XCTAssertNil(decoded.organization.groups.first { $0.id == orphan }?.parentID)
        XCTAssertNil(decoded.organization.groups.first { $0.id == selfParent }?.parentID)
        XCTAssertEqual(decoded.organization.groupByRepository, ["repo": c])
        XCTAssertEqual(decoded.organization.repositoryOrder, ["repo"])
        XCTAssertFalse(decoded.organization.ungroupedExpanded)
        XCTAssertEqual(decoded.organization.normalized, decoded.organization, "Normalization must be stable")
    }
}

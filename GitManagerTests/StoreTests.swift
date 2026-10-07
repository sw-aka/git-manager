import XCTest
@testable import GitManagerCore

final class StoreTests: XCTestCase {
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
}

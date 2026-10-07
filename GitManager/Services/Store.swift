import Foundation

struct Store: Sendable {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("state.json") }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let override = ProcessInfo.processInfo.environment["GIT_MANAGER_DATA_DIR"] {
            self.directory = URL(fileURLWithPath: override)
        } else {
            self.directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GitManager", isDirectory: true)
        }
    }

    func load() throws -> StoredState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return StoredState() }
        return try JSONDecoder().decode(StoredState.self, from: Data(contentsOf: fileURL))
    }
    func save(_ state: StoredState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}

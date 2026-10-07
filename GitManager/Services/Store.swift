import Foundation

public struct Store: Sendable {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("state.json") }

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let override = ProcessInfo.processInfo.environment["GIT_MANAGER_DATA_DIR"] {
            self.directory = URL(fileURLWithPath: override)
        } else {
            self.directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GitManager", isDirectory: true)
        }
    }

    public func load() throws -> StoredState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return StoredState() }
        return try JSONDecoder().decode(StoredState.self, from: Data(contentsOf: fileURL))
    }
    // Only a decode failure is recoverable here. Read or rename failures leave
    // the existing file untouched, and AppModel disables persistence for them.
    func loadRecovering() throws -> (state: StoredState, notice: String?) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return (StoredState(), nil) }
        let data = try Data(contentsOf: fileURL)
        do {
            return (try JSONDecoder().decode(StoredState.self, from: data), nil)
        } catch is DecodingError {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            var backup = directory.appendingPathComponent("state.corrupt-\(timestamp).json")
            var suffix = 0
            while FileManager.default.fileExists(atPath: backup.path) {
                suffix += 1
                backup = directory.appendingPathComponent("state.corrupt-\(timestamp)-\(suffix).json")
            }
            try FileManager.default.moveItem(at: fileURL, to: backup)
            return (StoredState(), "Saved state could not be decoded. The original file was kept at \(backup.path). Git Manager is starting with an empty list.")
        }
    }

    public func save(_ state: StoredState) throws {
        // Protect a file that became unreadable or corrupt after initial loading too.
        if FileManager.default.fileExists(atPath: fileURL.path) { _ = try load() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}

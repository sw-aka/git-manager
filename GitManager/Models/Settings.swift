import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var fetchIntervalMinutes: Int
    public init(fetchIntervalMinutes: Int = 5) {
        self.fetchIntervalMinutes = fetchIntervalMinutes
    }

    public var validatedInterval: Int { min(1440, max(1, fetchIntervalMinutes)) }
}

public struct StoredState: Codable, Equatable, Sendable {
    public var sources: [RepoSource]
    public var settings: AppSettings

    public init(sources: [RepoSource] = [], settings: AppSettings = AppSettings()) {
        self.sources = sources
        self.settings = settings
    }
}

import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var fetchIntervalMinutes = 5
    var validatedInterval: Int { min(1440, max(1, fetchIntervalMinutes)) }
}

struct StoredState: Codable, Equatable, Sendable {
    var sources: [RepoSource] = []
    var settings = AppSettings()
}

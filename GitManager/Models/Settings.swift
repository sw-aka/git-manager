import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var fetchIntervalMinutes: Int
    public init(fetchIntervalMinutes: Int = 5) {
        self.fetchIntervalMinutes = fetchIntervalMinutes
    }

    private enum CodingKeys: String, CodingKey { case fetchIntervalMinutes }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fetchIntervalMinutes = (try? values.decodeIfPresent(Int.self, forKey: .fetchIntervalMinutes)) ?? 5
    }

    public var validatedInterval: Int { min(1440, max(1, fetchIntervalMinutes)) }
}

public struct StoredState: Codable, Equatable, Sendable {
    public var sources: [RepoSource]
    public var settings: AppSettings
    public var organization: RepoOrganization

    public init(sources: [RepoSource] = [], settings: AppSettings = AppSettings(), organization: RepoOrganization = RepoOrganization()) {
        self.sources = sources
        self.settings = settings
        self.organization = organization
    }

    private enum CodingKeys: String, CodingKey { case sources, settings, organization }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sources = try values.decode([RepoSource].self, forKey: .sources)
        settings = (try? values.decodeIfPresent(AppSettings.self, forKey: .settings)) ?? AppSettings()
        organization = ((try? values.decodeIfPresent(RepoOrganization.self, forKey: .organization)) ?? RepoOrganization()).normalized
    }
}

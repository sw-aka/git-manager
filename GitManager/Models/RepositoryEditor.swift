import Foundation

public enum RepositoryEditor: String, Codable, CaseIterable, Sendable {
    case zed
    case vsCode

    public var name: String {
        switch self {
        case .zed: "Zed"
        case .vsCode: "VS Code"
        }
    }
}

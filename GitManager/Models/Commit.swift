import Foundation

public struct Commit: Identifiable, Equatable, Sendable {
    public let hash: String
    public let subject: String
    public let author: String
    public let date: Date
    public var isUnpushed: Bool
    public var id: String { hash }
    public var shortHash: String { String(hash.prefix(8)) }
}

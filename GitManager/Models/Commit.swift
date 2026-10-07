import Foundation

struct Commit: Identifiable, Equatable, Sendable {
    let hash: String
    let subject: String
    let author: String
    let date: Date
    var isUnpushed: Bool
    var id: String { hash }
    var shortHash: String { String(hash.prefix(8)) }
}

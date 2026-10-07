import Foundation

enum GitParser {
    static func status(_ output: String, truncated: Bool = false) -> RepoStatus {
        var status = RepoStatus()
        status.dirtyCountIsLowerBound = truncated
        let nulDelimited = output.contains("\0")
        var records = output.split(separator: nulDelimited ? "\0" : "\n", omittingEmptySubsequences: false)
        // Status uses -z. The final fragment can include a cut entry and the
        // capture marker; count only records with their original terminator.
        if truncated && !records.isEmpty { records.removeLast() }
        var skipRenamePath = false
        var hasAheadBehind = false
        for record in records {
            if skipRenamePath { skipRenamePath = false; continue }
            if record.hasPrefix("# branch.head ") {
                let branch = String(record.dropFirst("# branch.head ".count))
                status.isDetached = branch == "(detached)"
                status.branch = status.isDetached ? "detached" : branch
            } else if record.hasPrefix("# branch.oid ") {
                status.isUnborn = record.hasSuffix("(initial)")
            } else if record.hasPrefix("# branch.upstream ") {
                status.upstream = String(record.dropFirst("# branch.upstream ".count))
            } else if record.hasPrefix("# branch.ab ") {
                hasAheadBehind = true
                let counts = record.dropFirst("# branch.ab ".count).split(separator: " ")
                for count in counts {
                    if count.first == "+" { status.ahead = Int(count.dropFirst()) ?? 0 }
                    if count.first == "-" { status.behind = Int(count.dropFirst()) ?? 0 }
                }
            } else if record.hasPrefix("u ") {
                status.dirtyCount += 1
                status.unmergedCount += 1
            } else if record.hasPrefix("1 ") || record.hasPrefix("? ") {
                status.dirtyCount += 1
            } else if record.hasPrefix("2 ") {
                status.dirtyCount += 1
                skipRenamePath = nulDelimited
            }
        }
        status.upstreamGone = status.upstream != nil && !hasAheadBehind && !status.isUnborn
        return status
    }

    static func commits(_ output: String, unpushed: Set<String>) -> [Commit] {
        let formatter = ISO8601DateFormatter()
        return output.split(separator: "\u{1e}").compactMap { record in
            // git inserts a newline between records; subjects themselves are NUL-delimited.
            let cleaned = record.drop(while: { $0 == "\n" || $0 == "\r" })
            let fields = cleaned.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count >= 4, !fields[0].isEmpty,
                  let date = formatter.date(from: String(fields[3])) else { return nil }
            let hash = String(fields[0])
            return Commit(hash: hash, subject: String(fields[1]), author: String(fields[2]),
                          date: date, isUnpushed: unpushed.contains(hash))
        }
    }
}

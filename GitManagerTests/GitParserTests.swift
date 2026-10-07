import XCTest
@testable import GitManagerCore

final class GitParserTests: XCTestCase {
    func testAheadBehind() {
        let status = GitParser.status("# branch.oid abc\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +3 -12\n")
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 3)
        XCTAssertEqual(status.behind, 12)
        XCTAssertFalse(status.upstreamGone)
        XCTAssertTrue(status.canSync)
    }
    func testDetachedHeadDisablesSync() {
        let status = GitParser.status("# branch.oid abc\0# branch.head (detached)\0")
        XCTAssertEqual(status.branch, "detached")
        XCTAssertTrue(status.isDetached)
        XCTAssertFalse(status.canSync)
    }
    func testNoUpstreamRequiresOrigin() {
        var status = GitParser.status("# branch.head feature\n")
        XCTAssertNil(status.upstream)
        XCTAssertEqual(status.badge, "no upstream")
        XCTAssertFalse(status.canSync)
        status.hasOrigin = true
        XCTAssertTrue(status.canSync)
        XCTAssertTrue(status.needsSync)
    }
    func testGoneUpstream() {
        let status = GitParser.status("# branch.oid abc\n# branch.head main\n# branch.upstream origin/main\n")
        XCTAssertTrue(status.upstreamGone)
        XCTAssertEqual(status.badge, "upstream gone")
        XCTAssertTrue(status.needsAttention)
    }
    func testUnbornBranchIsNotGoneOrSyncable() {
        let status = GitParser.status("# branch.oid (initial)\n# branch.head main\n# branch.upstream origin/main\n")
        XCTAssertTrue(status.isUnborn)
        XCTAssertFalse(status.upstreamGone)
        XCTAssertFalse(status.canSync)
    }
    func testDirtyRenamedUntrackedAndUnmerged() {
        let output = "# branch.head main\0"
            + "1 .M N... 100644 100644 100644 abc abc normal file\0"
            + "2 R. N... 100644 100644 100644 abc abc R100 new name\0? old name\0"
            + "? new\nfile\0u UU N... 100644 100644 100644 100644 abc abc abc conflict\0"
            + "! ignored\0"
        let status = GitParser.status(output)
        XCTAssertEqual(status.dirtyCount, 4)
        XCTAssertEqual(status.unmergedCount, 1)
    }
    func testNewlineRenameCountsOnce() {
        let output = "2 R. N... 100644 100644 100644 abc abc R100 new\told\n? other\n"
        XCTAssertEqual(GitParser.status(output).dirtyCount, 2)
    }
    func testLogPreservesTabsPipesUnicodeAndEmptySubject() {
        let output = "abc\0fix\tpart | café 🦊\0Author | 名\02026-10-07T10:00:00+01:00\0\u{1e}\n"
            + "def\0\0Other\02026-10-06T09:00:00Z\0\u{1e}\n"
        let commits = GitParser.commits(output, unpushed: ["abc"])
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits.first?.subject, "fix\tpart | café 🦊")
        XCTAssertEqual(commits.first?.author, "Author | 名")
        XCTAssertTrue(commits.first?.isUnpushed == true)
        XCTAssertEqual(commits.last?.subject, "")
        XCTAssertFalse(commits.last?.isUnpushed ?? true)
        XCTAssertEqual(commits.first?.date, ISO8601DateFormatter().date(from: "2026-10-07T09:00:00Z"))
    }
    func testMalformedLogRecordsAreIgnored() {
        XCTAssertTrue(GitParser.commits("broken\u{1e}abc\0subject\0author\0bad date\u{1e}", unpushed: []).isEmpty)
    }
}

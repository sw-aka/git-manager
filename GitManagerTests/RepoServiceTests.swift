import XCTest
@testable import GitManagerCore

private actor PostPullRunner: GitRunner {
    enum Scenario: Sendable { case unmergedAfterPull, statusFailsAfterPull, initiallyUnmerged }
    let scenario: Scenario
    private var pulled = false
    private(set) var commands: [[String]] = []

    init(_ scenario: Scenario) { self.scenario = scenario }

    func run(args: [String], timeout: TimeInterval) async -> CommandResult {
        commands.append(args)
        var output = ""
        switch args.first {
        case "pull": pulled = true
        case "remote": output = "origin\n"
        case "status":
            if pulled && scenario == .statusFailsAfterPull {
                return CommandResult(stdout: "", stderr: "cannot inspect working tree", exitCode: 1)
            }
            output = "# branch.head main\0# branch.upstream origin/main\0# branch.ab +1 -0\0"
            if scenario == .initiallyUnmerged || (pulled && scenario == .unmergedAfterPull) {
                output += "u UU N... 100644 100644 100644 100644 abc abc abc conflicted.txt\0"
            }
        default: break
        }
        return CommandResult(stdout: output, stderr: "", exitCode: 0)
    }
}

private actor TruncatedStatusRunner: GitRunner {
    enum Scenario: Sendable { case initiallyTruncated, noUpstream, afterPull, stderrOnly }
    let scenario: Scenario
    private var pulled = false
    private(set) var commands: [[String]] = []

    init(_ scenario: Scenario) { self.scenario = scenario }

    func run(args: [String], timeout: TimeInterval) async -> CommandResult {
        commands.append(args)
        switch args.first {
        case "pull": pulled = true
        case "remote": return CommandResult(stdout: "origin\n", stderr: "", exitCode: 0)
        case "status":
            var output = "# branch.oid abc\0# branch.head main\0"
            if scenario != .noUpstream { output += "# branch.upstream origin/main\0# branch.ab +3 -2\0" }
            let truncated = scenario != .afterPull || pulled
            if truncated && scenario != .stderrOnly {
                output += "? one\0? two\0u UU N... unfinished conflict" + ProcessExecutor.truncationMarker
            }
            return CommandResult(stdout: output, stderr: scenario == .stderrOnly ? ProcessExecutor.truncationMarker : "",
                                 exitCode: 0, truncated: truncated)
        default: break
        }
        return CommandResult(stdout: "", stderr: "", exitCode: 0)
    }
}

@MainActor
final class RepoServiceTests: XCTestCase {
    func testTruncatedStatusPreservesBranchMetadataAndDisplaysLowerBound() async {
        let runner = TruncatedStatusRunner(.initiallyTruncated)
        let date = Date(timeIntervalSince1970: 1)
        let snapshot = await RepoService(runner: runner).snapshot(lastFetch: date)
        XCTAssertEqual(snapshot.status.branch, "main")
        XCTAssertEqual(snapshot.status.upstream, "origin/main")
        XCTAssertEqual(snapshot.status.ahead, 3)
        XCTAssertEqual(snapshot.status.behind, 2)
        XCTAssertEqual(snapshot.status.lastFetch, date)
        XCTAssertEqual(snapshot.status.dirtyCount, 2)
        XCTAssertEqual(snapshot.status.dirtyCountText, "2+")
        XCTAssertTrue(snapshot.status.dirtyCountIsLowerBound)
        XCTAssertEqual(snapshot.status.unmergedCount, 0, "The unfinished record must not be counted")
        XCTAssertTrue(snapshot.status.error?.contains("truncated") == true)
        XCTAssertFalse(snapshot.status.canSync)
    }

    func testTruncatedPreSyncStatusPreventsPullAndPublishingWithoutUpstream() async {
        for scenario in [TruncatedStatusRunner.Scenario.initiallyTruncated, .noUpstream] {
            let runner = TruncatedStatusRunner(scenario)
            let outcome = await RepoService(runner: runner).sync()
            XCTAssertFalse(outcome.result.succeeded)
            XCTAssertTrue(outcome.result.failureMessage.contains("truncated"))
            XCTAssertTrue(outcome.result.failureMessage.contains("Nothing was pulled or pushed"))
            XCTAssertTrue(outcome.snapshot.status.dirtyCountIsLowerBound)
            let commands = await runner.commands
            XCTAssertFalse(commands.contains { $0.first == "pull" || $0.first == "push" })
        }
    }

    func testTruncatedPostPullStatusPreventsPush() async {
        let runner = TruncatedStatusRunner(.afterPull)
        let outcome = await RepoService(runner: runner).sync()
        XCTAssertFalse(outcome.result.succeeded)
        XCTAssertTrue(outcome.result.failureMessage.contains("truncated after pull"))
        XCTAssertTrue(outcome.result.failureMessage.contains("unmerged"))
        let commands = await runner.commands
        XCTAssertEqual(commands.filter { $0.first == "pull" }.count, 1)
        XCTAssertFalse(commands.contains { $0.first == "push" })
    }

    func testTruncatedStderrAlsoMarksStatusIncomplete() async {
        let snapshot = await RepoService(runner: TruncatedStatusRunner(.stderrOnly)).snapshot()
        XCTAssertEqual(snapshot.status.branch, "main")
        XCTAssertEqual(snapshot.status.ahead, 3)
        XCTAssertEqual(snapshot.status.behind, 2)
        XCTAssertTrue(snapshot.status.dirtyCountIsLowerBound)
        XCTAssertEqual(snapshot.status.dirtyCountText, "0+")
        XCTAssertTrue(snapshot.status.needsAttention)
        XCTAssertFalse(snapshot.status.canSync)
    }

    func testUnmergedEntriesAfterSuccessfulPullPreventPush() async {
        let runner = PostPullRunner(.unmergedAfterPull)
        let outcome = await RepoService(runner: runner).sync()
        XCTAssertFalse(outcome.result.succeeded)
        XCTAssertTrue(outcome.result.failureMessage.contains("unmerged"))
        XCTAssertEqual(outcome.snapshot.status.unmergedCount, 1)
        XCTAssertNotNil(outcome.snapshot.status.error)
        let commands = await runner.commands
        XCTAssertEqual(commands.first { $0.first == "pull" }, ["pull", "--ff-only", "--no-rebase", "--no-autostash"])
        XCTAssertFalse(commands.contains { $0.first == "push" })
    }

    func testFailedPostPullStatusPreventsPush() async {
        let runner = PostPullRunner(.statusFailsAfterPull)
        let outcome = await RepoService(runner: runner).sync()
        XCTAssertFalse(outcome.result.succeeded)
        XCTAssertTrue(outcome.result.failureMessage.contains("cannot inspect"))
        let commands = await runner.commands
        XCTAssertFalse(commands.contains { $0.first == "push" })
    }

    func testExistingUnmergedEntriesPreventPullAndPush() async {
        let runner = PostPullRunner(.initiallyUnmerged)
        let outcome = await RepoService(runner: runner).sync()
        XCTAssertFalse(outcome.result.succeeded)
        XCTAssertTrue(outcome.snapshot.status.error?.contains("unmerged") == true)
        let commands = await runner.commands
        XCTAssertFalse(commands.contains { $0.first == "pull" || $0.first == "push" })
    }
}

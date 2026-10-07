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

@MainActor
final class RepoServiceTests: XCTestCase {
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

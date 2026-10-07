import XCTest
import Darwin
@testable import GitManagerCore

@MainActor
final class ProcessExecutorTests: XCTestCase {
    func testDrainsBothPipesBeyondBufferCapacity() async {
        let script = "BEGIN { for(i=0; i<8000; i++) { print \"stdout abcdefghijklmnopqrstuvwxyz\"; print \"stderr abcdefghijklmnopqrstuvwxyz\" > \"/dev/stderr\" } }"
        let result = await ProcessExecutor().run(CommandInvocation(executable: "/usr/bin/awk", arguments: [script]), timeout: 15)
        XCTAssertTrue(result.succeeded, result.failureMessage)
        XCTAssertEqual(result.stdout.split(separator: "\n").count, 8000)
        XCTAssertEqual(result.stderr.split(separator: "\n").count, 8000)
    }
    func testTimeoutKillsProcessIgnoringTermination() async {
        let start = Date()
        let result = await ProcessExecutor().run(
            CommandInvocation(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"]), timeout: 0.2
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.failureMessage.contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
    func testDescendantHoldingPipesDoesNotBlockCompletion() async {
        let start = Date()
        let result = await ProcessExecutor().run(
            CommandInvocation(executable: "/bin/sh", arguments: ["-c", "sleep 10 & echo $!"]), timeout: 1
        )
        if let pid = Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGKILL)
        }
        XCTAssertTrue(result.succeeded, result.failureMessage)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    func testQuotedArgumentsRoundTripThroughPOSIXShell() async {
        let values = ["", "space value", "it's complicated", "literal $(false); | &", "line\nbreak"]
        let command = "printf '%s\\0' " + values.map(SSHGitRunner.quote).joined(separator: " ")
        let result = await ProcessExecutor().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", command]), timeout: 2)
        XCTAssertTrue(result.succeeded, result.failureMessage)
        XCTAssertEqual(result.stdout, values.joined(separator: "\0") + "\0")
    }

    func testMissingExecutableIsAnError() async {
        let result = await ProcessExecutor().run(CommandInvocation(executable: "/nonexistent/gitmanager-test", arguments: []), timeout: 1)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.stderr.isEmpty)
    }
}

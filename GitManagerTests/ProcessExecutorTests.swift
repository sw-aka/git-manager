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

    func testTimeoutKillsDescendantEvenAfterLeaderExitsOnTERM() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmanager-process-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("must-not-appear")
        // The leader exits on TERM. Its child ignores TERM and writes only after
        // the two-second grace period, reproducing an escaped hook/transport.
        let childScript = "trap '' TERM; sleep 4; printf escaped > " + SSHGitRunner.quote(sentinel.path)
        let leaderScript = "/bin/sh -c " + SSHGitRunner.quote(childScript) + " & echo $!; wait"
        let start = Date()
        let result = await ProcessExecutor().run(
            CommandInvocation(executable: "/bin/sh", arguments: ["-c", leaderScript]), timeout: 0.3
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        try await Task.sleep(for: .seconds(max(0, 5 - Date().timeIntervalSince(start))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path), "A descendant kept working after timeout")
    }

    func testHomeDirectoryExpansionPreservesQuotedRest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmanager-home-\(UUID())")
        let directory = root.appendingPathComponent("repo's $(false)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = ProcessExecutor.userEnvironment
        environment["HOME"] = root.path
        for (path, expected) in [("~", root), ("~/repo's $(false)", directory)] {
            let script = "cd \(SSHGitRunner.directoryArgument(path)) && printf '%s' \"$PWD\""
            let result = await ProcessExecutor(environment: environment).run(
                CommandInvocation(executable: "/bin/sh", arguments: ["-c", script]), timeout: 2
            )
            XCTAssertTrue(result.succeeded, result.failureMessage)
            XCTAssertEqual(RepoLocation.canonicalLocalPath(result.stdout), RepoLocation.canonicalLocalPath(expected.path))
        }
    }

    func testMissingExecutableIsAnError() async {
        let result = await ProcessExecutor().run(CommandInvocation(executable: "/nonexistent/gitmanager-test", arguments: []), timeout: 1)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.stderr.isEmpty)
    }
}

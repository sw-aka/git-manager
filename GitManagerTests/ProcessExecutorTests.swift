import XCTest
import Darwin
@testable import GitManagerCore

@MainActor
final class ProcessExecutorTests: XCTestCase {
    nonisolated private static func killRecordedGroup(at file: URL) {
        guard let value = try? String(contentsOf: file, encoding: .utf8),
              let groupID = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), groupID > 0 else { return }
        kill(-groupID, SIGKILL)
    }

    func testContinuousBackgroundWritersCannotExtendDrainGrace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmanager-writers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let groupFile = root.appendingPathComponent("group")
        // The watchdog also cleans up if a future regression makes run hang.
        let watchdog = Task.detached {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            Self.killRecordedGroup(at: groupFile)
        }
        defer {
            watchdog.cancel()
            Self.killRecordedGroup(at: groupFile)
            try? FileManager.default.removeItem(at: root)
        }
        let script = "printf '%s\\n' \"$$\" > " + SSHGitRunner.quote(groupFile.path)
            + "; /usr/bin/yes stdout-writer & /usr/bin/yes stderr-writer >&2 & sleep 0.2; exit 0"
        var environment = ProcessExecutor.userEnvironment
        environment["SSH_AUTH_SOCK"] = "/unused/gitmanager-test-agent"
        let start = Date()
        let result = await ProcessExecutor(environment: environment).run(
            CommandInvocation(executable: "/bin/sh", arguments: ["-c", script]), timeout: 2
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: groupFile.path))
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, ProcessExecutor.maximumCapturedBytes)
        XCTAssertLessThanOrEqual(result.stderr.utf8.count, ProcessExecutor.maximumCapturedBytes)
        XCTAssertTrue(result.stdout.hasPrefix("stdout-writer"))
        XCTAssertTrue(result.stderr.hasPrefix("stderr-writer"))
        XCTAssertTrue(result.stdout.hasSuffix(ProcessExecutor.truncationMarker))
        XCTAssertTrue(result.stderr.hasSuffix(ProcessExecutor.truncationMarker))
    }

    func testHugeOutputPreservesHeadAndTruncatesBothStreamsWithoutBlocking() async {
        let script = "printf 'stdout-head\\n'; /usr/bin/yes o 2>/dev/null | /usr/bin/head -c 50000000; "
            + "printf 'stdout-tail'; printf 'stderr-head\\n' >&2; "
            + "/usr/bin/yes e 2>/dev/null | /usr/bin/head -c 50000000 >&2; printf 'stderr-tail' >&2"
        let result = await ProcessExecutor().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", script]), timeout: 15)
        XCTAssertTrue(result.succeeded, result.failureMessage)
        XCTAssertEqual(result.stdout.utf8.count, ProcessExecutor.maximumCapturedBytes)
        XCTAssertEqual(result.stderr.utf8.count, ProcessExecutor.maximumCapturedBytes)
        XCTAssertTrue(result.stdout.hasPrefix("stdout-head\n"))
        XCTAssertTrue(result.stderr.hasPrefix("stderr-head\n"))
        XCTAssertTrue(result.stdout.hasSuffix(ProcessExecutor.truncationMarker))
        XCTAssertTrue(result.stderr.hasSuffix(ProcessExecutor.truncationMarker))
        XCTAssertFalse(result.stdout.contains("stdout-tail"))
        XCTAssertFalse(result.stderr.contains("stderr-tail"))
    }

    func testRepeatedCommandsDoNotLeakPipeDescriptors() async {
        let command = CommandInvocation(executable: "/bin/sh", arguments: ["-c", "printf output; printf error >&2"])
        let executor = ProcessExecutor()
        _ = await executor.run(command, timeout: 2)
        let before = (0..<512).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
        for _ in 0..<40 {
            let result = await executor.run(command, timeout: 2)
            XCTAssertTrue(result.succeeded, result.failureMessage)
            XCTAssertEqual(result.stdout, "output")
            XCTAssertEqual(result.stderr, "error")
        }
        let after = (0..<512).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
        XCTAssertEqual(after, before, "Pipe descriptors leaked across completed commands")
    }

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

    func testManyBlockingCommandsAreBoundedAndAllowAsyncProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmanager-batch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = root.appendingPathComponent("events")
        let log = SSHGitRunner.quote(events.path)
        let command = CommandInvocation(executable: "/bin/sh", arguments: ["-c",
            "printf 'start\\n' >> " + log + "; sleep 0.15; printf 'end\\n' >> " + log
        ])
        var environment = ProcessExecutor.userEnvironment
        environment["SSH_AUTH_SOCK"] = "/unused/gitmanager-test-agent"
        let executor = ProcessExecutor(environment: environment)
        let progress = Task.detached {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let records = (try? String(contentsOf: events, encoding: .utf8))?.split(separator: "\n") ?? []
                if records.filter({ $0 == "start" }).count > records.filter({ $0 == "end" }).count { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        let results = await withTaskGroup(of: CommandResult.self, returning: [CommandResult].self) { group in
            for _ in 0..<36 { group.addTask { await executor.run(command, timeout: 5) } }
            var results: [CommandResult] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.count, 36)
        XCTAssertTrue(results.allSatisfy(\.succeeded))
        let madeProgress = await progress.value
        XCTAssertTrue(madeProgress, "Swift tasks did not make progress while child processes were running")
        var active = 0
        var maximum = 0
        for event in try String(contentsOf: events, encoding: .utf8).split(separator: "\n") {
            active += event == "start" ? 1 : -1
            maximum = max(maximum, active)
        }
        XCTAssertEqual(active, 0)
        XCTAssertGreaterThan(maximum, 1)
        XCTAssertLessThanOrEqual(maximum, 6)
    }
}

import XCTest
@testable import GitManagerCore

private actor TrackingGitRunner: GitRunner {
    let runner: LocalGitRunner
    private(set) var pushCount = 0
    init(_ runner: LocalGitRunner) { self.runner = runner }
    func run(args: [String], timeout: TimeInterval) async -> CommandResult {
        if args.first == "push" { pushCount += 1 }
        return await runner.run(args: args, timeout: timeout)
    }
}

@MainActor
final class IntegrationTests: XCTestCase {
    private var root: URL!
    private var executor: ProcessExecutor!
    private var a: String { root.appendingPathComponent("clone a's").path }
    private var b: String { root.appendingPathComponent("clone b").path }
    private var remote: String { root.appendingPathComponent("remote.git").path }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmanager-integration-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["LC_ALL"] = "C"
        executor = ProcessExecutor(environment: environment)
        try await git(root.path, ["init", "--bare", "--initial-branch=main", remote])
        try await git(root.path, ["clone", remote, a])
        try await configure(a)
        try await commit(a, file: "base.txt", text: "base", subject: "initial | café\t🦊")
        try await git(a, ["push", "-u", "origin", "main"])
        try await git(root.path, ["clone", remote, b])
        try await configure(b)
    }

    override func tearDown() async throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func git(_ path: String, _ args: [String]) async throws -> String {
        let result = await LocalGitRunner(path: path, executor: executor).run(args: args, timeout: 15)
        guard result.succeeded else { throw ValidationError.message("git \(args): \(result.failureMessage)") }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func configure(_ path: String) async throws {
        try await git(path, ["config", "user.name", "Git Manager Test"])
        try await git(path, ["config", "user.email", "gitmanager@example.invalid"])
    }
    private func commit(_ path: String, file: String, text: String, subject: String) async throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent(file))
        try await git(path, ["add", "--", file])
        try await git(path, ["commit", "-m", subject])
    }
    private func service(_ path: String) -> RepoService {
        RepoService(runner: LocalGitRunner(path: path, executor: executor))
    }

    func testBehindThenFastForwardAndAheadThenPush() async throws {
        let service = service(a)
        try await commit(b, file: "remote.txt", text: "from other clone", subject: "remote change")
        try await git(b, ["push"])
        let fetch = await service.fetch()
        XCTAssertTrue(fetch.succeeded, fetch.failureMessage)
        let behind = await service.snapshot()
        XCTAssertEqual(behind.status.behind, 1)
        XCTAssertEqual(behind.status.ahead, 0)
        XCTAssertEqual(behind.commits.first?.subject, "initial | café\t🦊")
        let fastForward = await service.sync()
        XCTAssertTrue(fastForward.result.succeeded, fastForward.result.failureMessage)
        XCTAssertEqual(fastForward.snapshot.status.ahead, 0)
        XCTAssertEqual(fastForward.snapshot.status.behind, 0)
        XCTAssertNotNil(fastForward.snapshot.status.lastFetch)
        XCTAssertEqual(fastForward.snapshot.commits.first?.subject, "remote change")

        try await commit(a, file: "local.txt", text: "local", subject: "local change")
        let ahead = await service.snapshot()
        XCTAssertEqual(ahead.status.ahead, 1)
        XCTAssertEqual(ahead.status.behind, 0)
        XCTAssertTrue(ahead.commits.first?.isUnpushed == true)
        let push = await service.sync()
        XCTAssertTrue(push.result.succeeded, push.result.failureMessage)
        XCTAssertEqual(push.snapshot.status.ahead, 0)
        XCTAssertEqual(push.snapshot.status.behind, 0)
        XCTAssertNil(push.snapshot.status.error)
        XCTAssertFalse(push.snapshot.commits.contains { $0.isUnpushed })
        let head = try await git(a, ["rev-parse", "HEAD"])
        let remoteHead = try await git(root.path, ["--git-dir", remote, "rev-parse", "main"])
        XCTAssertEqual(head, remoteHead)
    }

    func testDirtyRenamedAndUntrackedFiles() async throws {
        try await git(a, ["mv", "base.txt", "new name.txt"])
        try Data("untracked".utf8).write(to: URL(fileURLWithPath: a).appendingPathComponent("? file\nname.txt"))
        let snapshot = await service(a).snapshot()
        XCTAssertEqual(snapshot.status.dirtyCount, 2)
        XCTAssertTrue(snapshot.status.canSync)
        let outcome = await service(a).sync()
        XCTAssertTrue(outcome.result.succeeded, outcome.result.failureMessage)
        XCTAssertEqual(outcome.snapshot.status.dirtyCount, 2)
    }

    private func addUntrackedDirectory() throws {
        let directory = URL(fileURLWithPath: a).appendingPathComponent("new directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["one", "two", "three"] { try Data(name.utf8).write(to: directory.appendingPathComponent(name)) }
    }

    func testCountsEveryUntrackedFileInsideNewDirectory() async throws {
        try addUntrackedDirectory()
        let snapshot = await service(a).snapshot()
        XCTAssertNil(snapshot.status.error)
        XCTAssertEqual(snapshot.status.dirtyCount, 3)
    }

    func testCountsUntrackedFilesDespiteUserConfiguration() async throws {
        try addUntrackedDirectory()
        try await git(a, ["config", "status.showUntrackedFiles", "no"])
        let snapshot = await service(a).snapshot()
        XCTAssertNil(snapshot.status.error)
        XCTAssertEqual(snapshot.status.dirtyCount, 3)
    }

    func testDivergenceFailsWithoutChangingHEADOrRebasing() async throws {
        try await commit(a, file: "local.txt", text: "local", subject: "local divergence")
        try await commit(b, file: "remote.txt", text: "remote", subject: "remote divergence")
        try await git(b, ["push"])
        // A user preference for rebase must never override Sync's ff-only policy.
        try await git(a, ["config", "pull.rebase", "true"])
        let before = try await git(a, ["rev-parse", "HEAD"])
        let outcome = await service(a).sync()
        XCTAssertFalse(outcome.result.succeeded)
        XCTAssertFalse(outcome.result.stderr.isEmpty)
        XCTAssertEqual(outcome.snapshot.status.ahead, 1)
        XCTAssertEqual(outcome.snapshot.status.behind, 1)
        XCTAssertNotNil(outcome.snapshot.status.error)
        let after = try await git(a, ["rev-parse", "HEAD"])
        XCTAssertEqual(before, after)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a + "/.git/rebase-merge"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a + "/.git/MERGE_HEAD"))
    }

    func testNoUpstreamPublishesToOrigin() async throws {
        try await git(a, ["checkout", "-b", "feature"])
        try await commit(a, file: "feature.txt", text: "feature", subject: "feature change")
        let before = await service(a).snapshot()
        XCTAssertNil(before.status.upstream)
        XCTAssertTrue(before.status.hasOrigin)
        XCTAssertTrue(before.status.canSync)
        let outcome = await service(a).sync()
        XCTAssertTrue(outcome.result.succeeded, outcome.result.failureMessage)
        XCTAssertEqual(outcome.snapshot.status.upstream, "origin/feature")
        XCTAssertEqual(outcome.snapshot.status.ahead, 0)
        XCTAssertEqual(outcome.snapshot.status.behind, 0)
    }

    func testNoOriginAndDetachedDisableSync() async throws {
        try await git(a, ["checkout", "-b", "feature"])
        try await git(a, ["remote", "remove", "origin"])
        let noOrigin = await service(a).snapshot()
        XCTAssertFalse(noOrigin.status.canSync)
        let noOriginSync = await service(a).sync()
        XCTAssertFalse(noOriginSync.result.succeeded)
        try await git(a, ["checkout", "--detach"])
        let detached = await service(a).snapshot()
        XCTAssertTrue(detached.status.isDetached)
        XCTAssertFalse(detached.status.canSync)
        let detachedSync = await service(a).sync()
        XCTAssertFalse(detachedSync.result.succeeded)
    }

    func testGoneUpstreamSurfacesError() async throws {
        try await git(b, ["checkout", "-b", "replacement"])
        try await git(b, ["push", "-u", "origin", "replacement"])
        try await git(root.path, ["--git-dir", remote, "symbolic-ref", "HEAD", "refs/heads/replacement"])
        try await git(b, ["push", "origin", "--delete", "main"])
        let fetch = await service(a).fetch()
        XCTAssertTrue(fetch.succeeded, fetch.failureMessage)
        let snapshot = await service(a).snapshot()
        XCTAssertTrue(snapshot.status.upstreamGone)
        XCTAssertNotNil(snapshot.status.error)
    }

    func testDirtyConflictingFastForwardReportsErrorAndKeepsChanges() async throws {
        try Data("working changes".utf8).write(to: URL(fileURLWithPath: a).appendingPathComponent("base.txt"))
        try await commit(b, file: "base.txt", text: "remote edits", subject: "edit same file")
        try await git(b, ["push"])
        let before = try await git(a, ["rev-parse", "HEAD"])
        let outcome = await service(a).sync()
        XCTAssertFalse(outcome.result.succeeded)
        XCTAssertNotNil(outcome.snapshot.status.error)
        XCTAssertEqual(outcome.snapshot.status.dirtyCount, 1)
        let after = try await git(a, ["rev-parse", "HEAD"])
        XCTAssertEqual(before, after)
        XCTAssertEqual(try String(contentsOfFile: a + "/base.txt", encoding: .utf8), "working changes")
    }

    func testPushRejectionSurfacesStderrAndRefreshesStatus() async throws {
        let hook = URL(fileURLWithPath: remote).appendingPathComponent("hooks/pre-receive")
        try Data("#!/bin/sh\necho 'push deliberately rejected' >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try await commit(a, file: "local.txt", text: "local", subject: "rejected change")
        let outcome = await service(a).sync()
        XCTAssertFalse(outcome.result.succeeded)
        XCTAssertTrue(outcome.snapshot.status.error?.contains("push deliberately rejected") == true)
        XCTAssertEqual(outcome.snapshot.status.ahead, 1)
        XCTAssertEqual(outcome.snapshot.status.behind, 0)
    }

    func testAutostashConfigurationCannotChangeDirtyFileOrPushAfterConflict() async throws {
        let dirtyContents = "my uncommitted edits\n"
        try Data(dirtyContents.utf8).write(to: URL(fileURLWithPath: a).appendingPathComponent("base.txt"))
        try await commit(b, file: "base.txt", text: "upstream edits\n", subject: "conflicting upstream change")
        try await git(b, ["push"])
        let localHead = try await git(a, ["rev-parse", "HEAD"])
        let remoteHead = try await git(root.path, ["--git-dir", remote, "rev-parse", "main"])
        let runner = TrackingGitRunner(LocalGitRunner(path: a, executor: executor))
        for (pullAutostash, rebaseAutostash) in [("true", "false"), ("false", "true"), ("true", "true")] {
            try await git(a, ["config", "pull.autostash", pullAutostash])
            try await git(a, ["config", "rebase.autoStash", rebaseAutostash])
            let outcome = await RepoService(runner: runner).sync()
            XCTAssertFalse(outcome.result.succeeded)
            XCTAssertNotNil(outcome.snapshot.status.error)
            XCTAssertEqual(outcome.snapshot.status.unmergedCount, 0)
            XCTAssertEqual(try String(contentsOfFile: a + "/base.txt", encoding: .utf8), dirtyContents)
            let after = try await git(a, ["rev-parse", "HEAD"])
            let remoteAfter = try await git(root.path, ["--git-dir", remote, "rev-parse", "main"])
            XCTAssertEqual(after, localHead)
            XCTAssertEqual(remoteAfter, remoteHead)
            let stashes = try await git(a, ["stash", "list"])
            XCTAssertEqual(stashes, "")
        }
        let pushCount = await runner.pushCount
        XCTAssertEqual(pushCount, 0)
    }

    func testScannerKeepsAccessibleRepositoriesBesideUnreadableChild() async throws {
        let scanRoot = root.appendingPathComponent("partial scan")
        let accessible = scanRoot.appendingPathComponent("accessible")
        let blocked = scanRoot.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: accessible, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try await git(accessible.path, ["init", "--initial-branch=main"])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }
        let result = try Scanner().scan(in: scanRoot.path)
        XCTAssertEqual(result.repositories, [accessible.path])
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.issues.first?.path, blocked.path)
        XCTAssertFalse(result.issues.first?.message.isEmpty ?? true)
    }

    func testScannerDepthHiddenNodeModulesAndGitFile() async throws {
        let scanRoot = root.appendingPathComponent("scan")
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        let paths = ["one", "group/two", "group/deeper/three", "node_modules/skip", ".hidden/skip", "worktree"]
        for path in paths {
            let directory = scanRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if path == "worktree" {
                try Data("gitdir: somewhere\n".utf8).write(to: directory.appendingPathComponent(".git"))
            } else {
                try await git(directory.path, ["init", "--initial-branch=main"])
            }
        }
        let link = scanRoot.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: a))
        let discovered = try Scanner().repositories(in: scanRoot.path)
        XCTAssertEqual(Set(discovered), Set(["one", "group/two", "worktree"].map { scanRoot.appendingPathComponent($0).path }))
        XCTAssertEqual(try Scanner().repositories(in: a), [a])
        XCTAssertThrowsError(try Scanner().repositories(in: root.appendingPathComponent("absent").path))
    }
}

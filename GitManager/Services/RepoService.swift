import Foundation

public struct RepoSnapshot: Sendable {
    public var status: RepoStatus
    public var commits: [Commit]
}

public struct SyncOutcome: Sendable {
    public let result: CommandResult
    public let snapshot: RepoSnapshot
}

public struct RepoService: Sendable {
    let runner: any GitRunner

    init(runner: any GitRunner) { self.runner = runner }
    public init(location: RepoLocation) {
        switch location.source {
        case .local: runner = LocalGitRunner(path: location.path)
        case .remote(var source):
            source.path = location.path
            runner = SSHGitRunner(source: source)
        }
    }

    public func snapshot(lastFetch: Date? = nil, operationError: String? = nil) async -> RepoSnapshot {
        let result = await runner.run(args: ["status", "--porcelain=v2", "--branch", "-z"], timeout: 15)
        guard result.succeeded else {
            var status = RepoStatus()
            status.lastFetch = lastFetch
            status.error = [operationError, result.failureMessage].compactMap { $0 }.joined(separator: "\n")
            return RepoSnapshot(status: status, commits: [])
        }
        var status = GitParser.status(result.stdout)
        status.lastFetch = lastFetch
        var errors = [operationError].compactMap { $0 }
        let remotes = await runner.run(args: ["remote"], timeout: 15)
        if remotes.succeeded {
            status.hasOrigin = remotes.stdout.split(separator: "\n").contains("origin")
        } else { errors.append(remotes.failureMessage) }

        var unpushed = Set<String>()
        if !status.isUnborn {
            let revision = status.upstream == nil ? "HEAD" : "@{u}..HEAD"
            let pending = await runner.run(args: ["rev-list", revision], timeout: 15)
            if pending.succeeded {
                unpushed = Set(pending.stdout.split(separator: "\n").map(String.init))
            } else {
                errors.append(pending.failureMessage)
            }
        }
        var commits: [Commit] = []
        if !status.isUnborn {
            let log = await runner.run(args: [
                "log", "--no-color", "--no-show-signature", "-n", "20",
                "--format=%H%x00%s%x00%an%x00%aI%x00%x1e"
            ], timeout: 15)
            if log.succeeded { commits = GitParser.commits(log.stdout, unpushed: unpushed) }
            else { errors.append(log.failureMessage) }
        }
        status.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        return RepoSnapshot(status: status, commits: commits)
    }

    public func fetch() async -> CommandResult {
        await runner.run(args: ["fetch", "--prune"], timeout: 60)
    }

    public func sync(lastFetch: Date? = nil) async -> SyncOutcome {
        let before = await snapshot(lastFetch: lastFetch)
        var updatedFetch = lastFetch
        let result: CommandResult
        if !before.status.canSync {
            let reason = before.status.isDetached ? "Cannot sync a detached HEAD."
                : before.status.isUnborn ? "Create a commit before syncing this branch."
                : "Sync needs an upstream or a remote named origin."
            result = CommandResult(stdout: "", stderr: before.status.error ?? reason, exitCode: -1)
        } else if before.status.upstream == nil {
            result = await runner.run(
                args: ["push", "--set-upstream", "origin", before.status.branch], timeout: 60
            )
        } else {
            // Explicit --no-rebase overrides user configuration; --ff-only forbids merge commits.
            let pull = await runner.run(args: ["pull", "--ff-only", "--no-rebase"], timeout: 60)
            if pull.succeeded {
                updatedFetch = Date()
                result = await runner.run(args: ["push"], timeout: 60)
            }
            else { result = pull }
        }
        let after = await snapshot(lastFetch: updatedFetch, operationError: result.succeeded ? nil : result.failureMessage)
        return SyncOutcome(result: result, snapshot: after)
    }
}

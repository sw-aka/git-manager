import Foundation

protocol GitRunner: Sendable {
    func run(args: [String], timeout: TimeInterval) async -> CommandResult
}

private enum NoninteractiveGitEnvironment {
    static let assignments = [
        "GIT_TERMINAL_PROMPT=0", "GIT_SSH_COMMAND=ssh -o BatchMode=yes",
        "GIT_ASKPASS=/usr/bin/false", "SSH_ASKPASS=/usr/bin/false", "SSH_ASKPASS_REQUIRE=never"
    ]

    static func applying(to inherited: [String: String]) -> [String: String] {
        var environment = inherited
        for assignment in assignments {
            let parts = assignment.split(separator: "=", maxSplits: 1)
            environment[String(parts[0])] = String(parts[1])
        }
        return environment
    }
}

struct LocalGitRunner: GitRunner {
    let path: String
    let executor: ProcessExecutor

    init(path: String, executor: ProcessExecutor = ProcessExecutor()) {
        self.path = path
        self.executor = ProcessExecutor(environment: NoninteractiveGitEnvironment.applying(to: executor.environment))
    }
    func command(args: [String]) -> CommandInvocation {
        CommandInvocation(executable: "/usr/bin/git", arguments: ["-C", path] + args)
    }
    func run(args: [String], timeout: TimeInterval = 15) async -> CommandResult {
        await executor.run(command(args: args), timeout: timeout)
    }
}

struct SSHGitRunner: GitRunner {
    let source: RemoteRepoSource
    let executor: ProcessExecutor

    init(source: RemoteRepoSource, executor: ProcessExecutor = ProcessExecutor()) {
        self.source = source.normalized
        self.executor = ProcessExecutor(environment: NoninteractiveGitEnvironment.applying(to: executor.environment))
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func directoryArgument(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") { return "~/" + quote(String(path.dropFirst(2))) }
        return quote(path)
    }
    func command(args: [String]) -> CommandInvocation {
        // -- ends SSH options BEFORE the host; putting it after the host runs it remotely.
        var arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/gitmanager-ssh-%C",
            "-o", "ControlPersist=300"
        ]
        if let port = source.port { arguments += ["-p", String(port)] }
        let remoteCommand = "cd " + Self.directoryArgument(source.path)
            + " && " + (["env"] + NoninteractiveGitEnvironment.assignments + ["git"]
                + args).map(Self.quote).joined(separator: " ")
        arguments += ["--", source.host, remoteCommand]
        return CommandInvocation(executable: "/usr/bin/ssh", arguments: arguments)
    }
    func run(args: [String], timeout: TimeInterval = 15) async -> CommandResult {
        do { try source.validate() } catch {
            return CommandResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }
        return await executor.run(command(args: args), timeout: timeout)
    }
}

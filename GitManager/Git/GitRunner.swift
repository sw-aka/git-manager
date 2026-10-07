import Foundation

protocol GitRunner: Sendable {
    func run(args: [String], timeout: TimeInterval) async -> CommandResult
}

struct LocalGitRunner: GitRunner {
    let path: String
    let executor: ProcessExecutor

    init(path: String, executor: ProcessExecutor = ProcessExecutor()) {
        self.path = path
        var environment = executor.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        self.executor = ProcessExecutor(environment: environment)
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
    var executor = ProcessExecutor()

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
            + " && " + (["env", "GIT_TERMINAL_PROMPT=0", "GIT_SSH_COMMAND=ssh -o BatchMode=yes", "git"]
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

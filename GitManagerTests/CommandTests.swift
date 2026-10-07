import XCTest
@testable import GitManagerCore

final class CommandTests: XCTestCase {
    func testLocalCommandAndNoninteractiveEnvironment() {
        let runner = LocalGitRunner(path: "/tmp/my repo's", executor: ProcessExecutor(environment: ["PATH": "/custom", "HOME": "/test", "SSH_AUTH_SOCK": "/agent"]))
        XCTAssertEqual(runner.command(args: ["status"]).arguments, ["-C", "/tmp/my repo's", "status"])
        XCTAssertEqual(runner.command(args: []).executable, "/usr/bin/git")
        XCTAssertEqual(runner.executor.environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(runner.executor.environment["GIT_SSH_COMMAND"], "ssh -o BatchMode=yes")
        XCTAssertEqual(runner.executor.environment["SSH_AUTH_SOCK"], "/agent")
        XCTAssertEqual(runner.executor.environment["PATH"], "/custom")
        XCTAssertEqual(runner.executor.environment["HOME"], "/test")
    }
    func testSSHConstructionAndQuoting() {
        let runner = SSHGitRunner(source: RemoteRepoSource(host: "sam@host", port: 2222, path: "/srv/my repo's $(touch bad)"))
        let command = runner.command(args: ["log", "--format=it's | %s", "", "semi;colon"])
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertEqual(Array(command.arguments.dropLast()), [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/gitmanager-ssh-%C",
            "-o", "ControlPersist=300", "-p", "2222", "--", "sam@host"
        ])
        XCTAssertEqual(command.arguments.last,
            "cd '/srv/my repo'\\''s $(touch bad)' && 'env' 'GIT_TERMINAL_PROMPT=0' 'GIT_SSH_COMMAND=ssh -o BatchMode=yes' 'git' 'log' '--format=it'\\''s | %s' '' 'semi;colon'")
    }
    func testSSHNoPortAndAlias() {
        let args = SSHGitRunner(source: RemoteRepoSource(host: "work-host", path: "/repo")).command(args: ["status"]).arguments
        XCTAssertFalse(args.contains("-p"))
        XCTAssertEqual(args[args.count - 2], "work-host")
        XCTAssertEqual(SSHGitRunner.quote("a'b'c"), "'a'\\''b'\\''c'")
        XCTAssertEqual(SSHGitRunner.quote(""), "''")
    }
    func testRemoteValidation() throws {
        try RemoteRepoSource(host: "user@alias", port: 22, path: "/with spaces/it's safe").validate()
        XCTAssertThrowsError(try RemoteRepoSource(host: "-oProxyCommand=bad", path: "/repo").validate())
        XCTAssertThrowsError(try RemoteRepoSource(host: "host command", path: "/repo").validate())
        XCTAssertThrowsError(try RemoteRepoSource(host: "host", port: 65536, path: "/repo").validate())
        XCTAssertThrowsError(try RemoteRepoSource(host: "host", path: "relative").validate())
    }
    func testZedLocalCLIAndFallback() throws {
        let source = RepoSource.local(LocalFolderSource(path: "/tmp/repo's folder"))
        let location = RepoLocation(source: source, path: "/tmp/repo's folder")
        XCTAssertEqual(try ZedLauncher.command(for: location, cliExists: true, appExists: true),
                       CommandInvocation(executable: ZedLauncher.cliPath, arguments: [location.path]))
        XCTAssertEqual(try ZedLauncher.command(for: location, cliExists: false, appExists: true),
                       CommandInvocation(executable: "/usr/bin/open", arguments: ["-a", "Zed", location.path]))
        XCTAssertThrowsError(try ZedLauncher.command(for: location, cliExists: false, appExists: false))
    }
    func testZedRemoteUserHostPortAndEncodedPath() throws {
        let remote = RemoteRepoSource(host: "user@host", port: 2222, path: "/srv/my repo/名")
        let location = RepoLocation(source: .remote(remote), path: remote.path)
        let command = try ZedLauncher.command(for: location, cliExists: true, appExists: true)
        XCTAssertEqual(command.executable, ZedLauncher.cliPath)
        XCTAssertEqual(command.arguments, ["ssh://user@host:2222/srv/my%20repo/%E5%90%8D"])
        XCTAssertThrowsError(try ZedLauncher.command(for: location, cliExists: false, appExists: true))
    }
    func testZedRemoteAliasAndIPv6() throws {
        XCTAssertEqual(try ZedLauncher.remoteURI(RemoteRepoSource(host: "work", path: "/repo")), "ssh://work/repo")
        XCTAssertEqual(try ZedLauncher.remoteURI(RemoteRepoSource(host: "sam@[::1]", port: 22, path: "/repo")), "ssh://sam@[::1]:22/repo")
    }
}

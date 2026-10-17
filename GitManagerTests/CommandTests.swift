import XCTest
@testable import GitManagerCore

final class CommandTests: XCTestCase {
    func testVSCodeLocalCLIAndFallback() throws {
        let location = RepoLocation(source: .local(LocalFolderSource(path: "/tmp/repo")), path: "/tmp/repo's $(false) 名")
        XCTAssertEqual(try VSCodeLauncher.command(for: location, cliExists: true, appExists: true),
                       CommandInvocation(executable: VSCodeLauncher.cliPath, arguments: [location.path]))
        XCTAssertEqual(try VSCodeLauncher.command(for: location, cliExists: false, appExists: true),
                       CommandInvocation(executable: "/usr/bin/open", arguments: ["-a", "Visual Studio Code", location.path]))
        XCTAssertThrowsError(try VSCodeLauncher.command(for: location, cliExists: true, appExists: false))
    }

    func testVSCodeRemoteAuthorityAndEncodedFolderPath() throws {
        for host in ["WorkAlias", "sam@WorkAlias", "sam@[::1]", "::1", "deadbeef"] {
            let remote = RemoteRepoSource(host: host, port: 2222, path: "/source")
            let location = RepoLocation(source: .remote(remote), path: "/repo's folder/名?#%$(false)")
            let command = try VSCodeLauncher.command(for: location, cliExists: true, appExists: true)
            XCTAssertEqual(command.executable, VSCodeLauncher.cliPath)
            XCTAssertEqual(command.arguments.first, "--folder-uri")
            let uri = try XCTUnwrap(URLComponents(string: command.arguments[1]))
            XCTAssertEqual(uri.scheme, "vscode-remote")
            XCTAssertEqual(uri.path, location.path)
            XCTAssertNil(uri.query)
            XCTAssertNil(uri.fragment)
            let authority = try XCTUnwrap(uri.host)
            XCTAssertTrue(authority.hasPrefix("ssh-remote+"))
            let hex = Array(authority.dropFirst("ssh-remote+".count))
            let bytes = stride(from: 0, to: hex.count, by: 2).compactMap { UInt8(String(hex[$0...$0 + 1]), radix: 16) }
            let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
            let expectedHost = host.split(separator: "@").last.map(String.init)!.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            XCTAssertEqual(data["hostName"] as? String, expectedHost)
            XCTAssertEqual(data["user"] as? String, host.contains("@") ? "sam" : nil)
            XCTAssertEqual(data["port"] as? Int, 2222)
            XCTAssertThrowsError(try VSCodeLauncher.command(for: location, cliExists: false, appExists: true))
        }
        let remote = RemoteRepoSource(host: "WorkAlias", path: "/repo")
        XCTAssertFalse(try VSCodeLauncher.remoteURI(remote).isEmpty)
        for remote in [RemoteRepoSource(host: "-bad", path: "/repo"),
                       RemoteRepoSource(host: "host", port: 0, path: "/repo"),
                       RemoteRepoSource(host: "host", path: "~/repo")] {
            XCTAssertThrowsError(try VSCodeLauncher.remoteURI(remote))
        }
    }

    func testVSCodeResolvesHomePathsOnRemoteAndRejectsIncompleteOutput() async throws {
        let remote = RemoteRepoSource(host: "WorkAlias", port: 2222, path: "~/repo's $(false)")
        let location = RepoLocation(source: .remote(remote), path: remote.path)
        let runner = EditorPathRunner(result: CommandResult(stdout: "/Users/remote/repo's $(false)\n", stderr: "", exitCode: 0))
        let launcher = VSCodeLauncher(runnerFactory: { _ in runner })
        let resolved = try await launcher.resolvedLocation(location)
        XCTAssertEqual(resolved.path, "/Users/remote/repo's $(false)")
        XCTAssertEqual(resolved.source, location.source)
        let calls = await runner.calls
        XCTAssertEqual(calls, [["rev-parse", "--show-toplevel"]])
        for result in [CommandResult(stdout: "", stderr: "Permission denied", exitCode: 1),
                       CommandResult(stdout: "/partial", stderr: "", exitCode: 0, truncated: true),
                       CommandResult(stdout: "relative\n", stderr: "", exitCode: 0),
                       CommandResult(stdout: "/repo\nextra\n", stderr: "", exitCode: 0)] {
            let failing = VSCodeLauncher(runnerFactory: { _ in EditorPathRunner(result: result) })
            do {
                _ = try await failing.resolvedLocation(location)
                XCTFail("Invalid or incomplete remote paths must not launch VS Code")
            } catch {}
        }
        let absolute = RepoLocation(source: .remote(remote), path: "/absolute/repo")
        let unchanged = try await launcher.resolvedLocation(absolute)
        XCTAssertEqual(unchanged, absolute)
        let finalCalls = await runner.calls
        XCTAssertEqual(finalCalls.count, 1, "Absolute paths must not require an extra SSH command")
    }

    func testLocalCommandAndNoninteractiveEnvironment() {
        let runner = LocalGitRunner(path: "/tmp/my repo's", executor: ProcessExecutor(environment: [
            "PATH": "/custom", "HOME": "/test", "SSH_AUTH_SOCK": "/agent",
            "GIT_ASKPASS": "/inherited/dialog", "SSH_ASKPASS": "/inherited/dialog", "SSH_ASKPASS_REQUIRE": "force"
        ]))
        XCTAssertEqual(runner.command(args: ["status"]).arguments, ["-C", "/tmp/my repo's", "status"])
        XCTAssertEqual(runner.command(args: []).executable, "/usr/bin/git")
        XCTAssertEqual(runner.executor.environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(runner.executor.environment["GIT_SSH_COMMAND"], "ssh -o BatchMode=yes")
        XCTAssertEqual(runner.executor.environment["GIT_ASKPASS"], "/usr/bin/false")
        XCTAssertEqual(runner.executor.environment["SSH_ASKPASS"], "/usr/bin/false")
        XCTAssertEqual(runner.executor.environment["SSH_ASKPASS_REQUIRE"], "never")
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
            "cd '/srv/my repo'\\''s $(touch bad)' && 'env' 'GIT_TERMINAL_PROMPT=0' 'GIT_SSH_COMMAND=ssh -o BatchMode=yes' 'GIT_ASKPASS=/usr/bin/false' 'SSH_ASKPASS=/usr/bin/false' 'SSH_ASKPASS_REQUIRE=never' 'git' 'log' '--format=it'\\''s | %s' '' 'semi;colon'")
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
    func testHomeRelativeSSHPathsAreValidatedAndSafelyQuoted() throws {
        for path in ["~", "~/", "~/repo's space"] {
            try RemoteRepoSource(host: "host", path: path).validate()
        }
        for path in ["~other/repo", "repo", "", "~/repo\nnext"] {
            XCTAssertThrowsError(try RemoteRepoSource(host: "host", path: path).validate())
        }
        XCTAssertEqual(SSHGitRunner.directoryArgument("~"), "~")
        XCTAssertEqual(SSHGitRunner.directoryArgument("~/"), "~/''")
        let remote = RemoteRepoSource(host: "host", path: "~/repo's space $(false)")
        let command = SSHGitRunner(source: remote).command(args: ["status"])
        XCTAssertTrue(command.arguments.last?.hasPrefix("cd ~/'repo'\\''s space $(false)' && ") == true)
    }

    func testZedHomeRelativeURI() throws {
        let remote = RemoteRepoSource(host: "user@host", port: 2222, path: "~/my repo/名")
        let command = try ZedLauncher.command(for: RepoLocation(source: .remote(remote), path: remote.path), cliExists: true, appExists: true)
        XCTAssertEqual(command.arguments, ["ssh://user@host:2222/~/my%20repo/%E5%90%8D"])
        XCTAssertEqual(try ZedLauncher.remoteURI(RemoteRepoSource(host: "host", path: "~")), "ssh://host/~")
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

    func testSSHEnvironmentOverridesAskpassButPreservesCredentialHelpers() {
        let inherited = [
            "GIT_ASKPASS": "/dialog", "SSH_ASKPASS": "/dialog", "SSH_ASKPASS_REQUIRE": "force",
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": "osxkeychain"
        ]
        let executor = ProcessExecutor(environment: inherited)
        let remote = SSHGitRunner(source: RemoteRepoSource(host: "host", path: "/repo"), executor: executor)
        for environment in [remote.executor.environment, LocalGitRunner(path: "/repo", executor: executor).executor.environment] {
            XCTAssertEqual(environment["GIT_ASKPASS"], "/usr/bin/false")
            XCTAssertEqual(environment["SSH_ASKPASS"], "/usr/bin/false")
            XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "never")
            XCTAssertEqual(environment["GIT_CONFIG_VALUE_0"], "osxkeychain")
            XCTAssertEqual(environment["GIT_CONFIG_KEY_0"], "credential.helper")
            XCTAssertEqual(environment["GIT_CONFIG_COUNT"], "1")
        }
        let command = remote.command(args: ["fetch"]).arguments.last ?? ""
        for assignment in ["GIT_ASKPASS=/usr/bin/false", "SSH_ASKPASS=/usr/bin/false", "SSH_ASKPASS_REQUIRE=never"] {
            XCTAssertTrue(command.contains(SSHGitRunner.quote(assignment)))
        }
        XCTAssertFalse(command.contains("credential.helper"))
    }

    func testRemotePathNormalization() {
        for (path, expected) in [
            ("/srv/repo/", "/srv/repo"), ("//srv///./repo", "/srv/repo"),
            ("/srv/other/../repo", "/srv/repo"), ("/.././", "/"),
            ("~/", "~"), ("~//group/../repo/./", "~/repo"), ("~/..", "~/.."),
            ("~/../other/./repo/", "~/../other/repo"), ("/srv/repo's space/../名", "/srv/名")
        ] {
            XCTAssertEqual(RemoteRepoSource.normalizedPath(path), expected, path)
            XCTAssertEqual(RemoteRepoSource.normalizedPath(expected), expected, "Normalization must be idempotent")
        }
    }

    func testRemoteIdentityNormalizesPersistedAndMutatedSources() {
        let canonical = RemoteRepoSource(host: "User@host", path: "/srv/repo")
        let expected = RepoLocation(source: .remote(canonical), path: canonical.path).id
        for spelling in ["/srv/repo/", "/srv/./repo", "/srv//group/../repo/"] {
            var raw = canonical
            raw.path = spelling
            XCTAssertEqual(RepoLocation(source: .remote(raw), path: spelling).id, expected)
        }
        let differentUser = RemoteRepoSource(host: "user@host", path: "/srv/repo")
        XCTAssertNotEqual(RepoLocation(source: .remote(differentUser), path: differentUser.path).id, expected)
        let explicitPort = RemoteRepoSource(host: canonical.host, port: 22, path: canonical.path)
        XCTAssertNotEqual(RepoLocation(source: .remote(explicitPort), path: explicitPort.path).id, expected,
                          "An omitted port must continue to respect SSH config")
    }

    func testSSHHostSpellingIsPreservedInCommandsURIsAndIdentity() throws {
        for (host, destination) in [("MIXED-ALIAS", "MIXED-ALIAS"),
                                    ("CaseSensitiveUser@MiXeD-Host", "CaseSensitiveUser@MiXeD-Host"),
                                    ("user@[FE80::1]", "user@FE80::1")] {
            let remote = RemoteRepoSource(host: host, path: "/srv/./repo/")
            XCTAssertEqual(remote.host, host)
            XCTAssertEqual(remote.normalized.host, host)
            let command = SSHGitRunner(source: remote).command(args: ["fetch"])
            XCTAssertEqual(command.arguments[command.arguments.count - 2], destination)
            let location = RepoLocation(source: .remote(remote), path: remote.path)
            guard case .remote(let source) = location.source else { return XCTFail("Not a remote source") }
            XCTAssertEqual(source.host, host)
            let uri = try ZedLauncher.remoteURI(source)
            XCTAssertEqual(uri, "ssh://" + host + "/srv/repo")
            let changedSpelling = RemoteRepoSource(host: host.lowercased(), path: "/srv/repo")
            XCTAssertNotEqual(location.id, RepoLocation(source: .remote(changedSpelling), path: changedSpelling.path).id)
        }
    }

    func testIPv6SSHUsesBareLiteralsAndZedKeepsURLBrackets() throws {
        for (host, destination, uriHost) in [("user@[::1]", "user@::1", "user@[::1]"),
                                            ("[::1]", "::1", "[::1]"),
                                            ("user@::1", "user@::1", "user@[::1]"),
                                            ("::1", "::1", "[::1]")] {
            let remote = RemoteRepoSource(host: host, port: 2222, path: "/repo")
            try remote.validate()
            let command = SSHGitRunner(source: remote).command(args: ["status"])
            XCTAssertEqual(Array(command.arguments.dropLast().suffix(4)), ["-p", "2222", "--", destination])
            let location = RepoLocation(source: .remote(remote), path: remote.path)
            let zed = try ZedLauncher.command(for: location, cliExists: true, appExists: true)
            XCTAssertEqual(zed.arguments, ["ssh://" + uriHost + ":2222/repo"])
            guard case .remote(let source) = location.source else { return XCTFail("Not a remote source") }
            XCTAssertEqual(source.host, host, "SSH argument formatting must not change stored host spelling")
        }
    }
}

private actor EditorPathRunner: GitRunner {
    let result: CommandResult
    private(set) var calls: [[String]] = []
    init(result: CommandResult) { self.result = result }
    func run(args: [String], timeout: TimeInterval) async -> CommandResult {
        calls.append(args)
        return result
    }
}

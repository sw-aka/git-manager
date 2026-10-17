import Foundation

public struct EditorLauncher: Sendable {
    public init() {}

    public func open(_ location: RepoLocation, in editor: RepositoryEditor) async -> CommandResult {
        switch editor {
        case .zed: await ZedLauncher().open(location)
        case .vsCode: await VSCodeLauncher().open(location)
        }
    }
}

struct VSCodeLauncher: Sendable {
    static let applicationPath = "/Applications/Visual Studio Code.app"
    static let cliPath = applicationPath + "/Contents/Resources/app/bin/code"
    var executor = ProcessExecutor()
    var runnerFactory: @Sendable (RemoteRepoSource) -> any GitRunner = { SSHGitRunner(source: $0) }

    static func remoteURI(_ source: RemoteRepoSource) throws -> String {
        try source.validate()
        guard source.path.hasPrefix("/") else {
            throw ValidationError.message("Resolve the remote home directory before opening VS Code.")
        }
        let parts = source.host.split(separator: "@", maxSplits: 1)
        var hostname = String(parts.last!)
        if hostname.hasPrefix("["), hostname.hasSuffix("]") { hostname = String(hostname.dropFirst().dropLast()) }
        // Remote - SSH decodes a hex JSON authority, preserving alias case, user and port.
        var connection: [String: Any] = ["hostName": hostname]
        if parts.count == 2 { connection["user"] = String(parts[0]) }
        if let port = source.port { connection["port"] = port }
        let data = try JSONSerialization.data(withJSONObject: connection, options: [.sortedKeys])
        let authority = data.map { String(format: "%02x", $0) }.joined()
        var components = URLComponents()
        components.scheme = "vscode-remote"
        components.host = "ssh-remote+" + authority
        components.path = source.path
        guard let uri = components.string else { throw ValidationError.message("Cannot build the VS Code SSH URL.") }
        return uri
    }

    static func command(
        for location: RepoLocation,
        cliExists: Bool = FileManager.default.isExecutableFile(atPath: cliPath),
        appExists: Bool = FileManager.default.fileExists(atPath: applicationPath)
    ) throws -> CommandInvocation {
        guard appExists else {
            throw ValidationError.message("VS Code is not installed at /Applications/Visual Studio Code.app.")
        }
        switch location.source {
        case .local:
            if cliExists { return CommandInvocation(executable: cliPath, arguments: [location.path]) }
            return CommandInvocation(executable: "/usr/bin/open", arguments: ["-a", "Visual Studio Code", location.path])
        case .remote(var remote):
            guard cliExists else {
                throw ValidationError.message("VS Code's CLI is missing; reinstall VS Code to open SSH repositories.")
            }
            remote.path = location.path
            return CommandInvocation(executable: cliPath, arguments: ["--folder-uri", try remoteURI(remote)])
        }
    }

    func resolvedLocation(_ location: RepoLocation) async throws -> RepoLocation {
        guard case .remote(var remote) = location.source else { return location }
        remote.path = location.path
        try remote.validate()
        guard !location.path.hasPrefix("/") else { return location }
        // Resolve ~ on the remote host, never against the local user's home directory.
        let result = await runnerFactory(remote).run(args: ["rev-parse", "--show-toplevel"], timeout: 15)
        guard !result.truncated else {
            throw ValidationError.message("Could not resolve the remote repository path: command output was truncated.")
        }
        guard result.succeeded else {
            throw ValidationError.message("Could not resolve the remote repository path: \(result.failureMessage)")
        }
        let path = result.stdout.hasSuffix("\n") ? String(result.stdout.dropLast()) : result.stdout
        remote.path = path
        try remote.validate()
        guard path.hasPrefix("/") else { throw ValidationError.message("The remote repository path must be absolute.") }
        return RepoLocation(source: location.source, path: path)
    }

    func open(_ location: RepoLocation) async -> CommandResult {
        do {
            // Check installation before making an SSH connection to resolve a home-relative path.
            guard FileManager.default.isExecutableFile(atPath: Self.cliPath),
                  FileManager.default.fileExists(atPath: Self.applicationPath) else {
                return await executor.run(try Self.command(for: location), timeout: 15)
            }
            let resolved = try await resolvedLocation(location)
            return await executor.run(try Self.command(for: resolved), timeout: 15)
        } catch {
            return CommandResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }
    }
}

import Foundation

public struct ZedLauncher: Sendable {
    static let applicationPath = "/Applications/Zed.app"
    static let cliPath = applicationPath + "/Contents/MacOS/cli"
    var executor = ProcessExecutor()

    public init() {}

    static func remoteURI(_ source: RemoteRepoSource) throws -> String {
        try source.validate()
        let hostParts = source.host.split(separator: "@", maxSplits: 1)
        let username = hostParts.count == 2 ? String(hostParts[0]) : nil
        var hostname = String(hostParts.last!)
        // URLComponents requires brackets around an IPv6 host.
        if hostname.contains(":") && !hostname.hasPrefix("[") { hostname = "[" + hostname + "]" }
        var components = URLComponents()
        components.scheme = "ssh"
        components.user = username
        components.host = hostname
        components.port = source.port
        components.path = source.path.hasPrefix("/") ? source.path : "/" + source.path
        guard let uri = components.string else { throw ValidationError.message("Cannot build the Zed SSH URL.") }
        return uri
    }

    static func command(
        for location: RepoLocation,
        cliExists: Bool = FileManager.default.isExecutableFile(atPath: cliPath),
        appExists: Bool = FileManager.default.fileExists(atPath: applicationPath)
    ) throws -> CommandInvocation {
        guard appExists else { throw ValidationError.message("Zed is not installed at /Applications/Zed.app.") }
        switch location.source {
        case .local:
            if cliExists { return CommandInvocation(executable: cliPath, arguments: [location.path]) }
            return CommandInvocation(executable: "/usr/bin/open", arguments: ["-a", "Zed", location.path])
        case .remote(var remote):
            guard cliExists else { throw ValidationError.message("Zed's CLI is missing; reinstall Zed to open SSH repositories.") }
            remote.path = location.path
            return CommandInvocation(executable: cliPath, arguments: [try remoteURI(remote)])
        }
    }
    public func open(_ location: RepoLocation) async -> CommandResult {
        do { return await executor.run(try Self.command(for: location), timeout: 15) }
        catch { return CommandResult(stdout: "", stderr: error.localizedDescription, exitCode: -1) }
    }
}

import Foundation

/// Folder suggestions for a remote repository path while it is typed.
public enum RemotePathCompletion {
    public struct Query: Hashable, Sendable {
        /// Typed text up to and including the last slash, for example `~/code/`.
        public let directory: String
        /// Typed text after the last slash, matched against folder names.
        public let prefix: String
    }

    /// Splits a typed absolute or home-relative path; nil when it cannot be listed.
    public static func query(for path: String) -> Query? {
        guard path.hasPrefix("/") || path.hasPrefix("~/"),
              !path.contains("\0"), !path.contains("\n"), !path.contains("\r"),
              let slash = path.lastIndex(of: "/") else { return nil }
        return Query(directory: String(path[...slash]), prefix: String(path[path.index(after: slash)...]))
    }

    /// Parses `find -print0` output of `./name` entries into sorted folder names.
    public static func parse(_ output: String) -> [String] {
        output.split(separator: "\0").compactMap { entry -> String? in
            guard entry.hasPrefix("./") else { return nil }
            let name = String(entry.dropFirst(2))
            guard !name.isEmpty, !name.contains("/"), !name.contains("\n"), !name.contains("\r") else { return nil }
            return name
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Names starting with the prefix, ignoring case; hidden folders only once the prefix starts with a dot.
    public static func matches(_ names: [String], prefix: String) -> [String] {
        names.filter { name in
            if name.hasPrefix(".") && !prefix.hasPrefix(".") { return false }
            return name.lowercased().hasPrefix(prefix.lowercased())
        }
    }

    /// The typed path after accepting a suggested folder.
    public static func completing(_ query: Query, with name: String) -> String {
        query.directory + name + "/"
    }
}

/// Lists the folders in a directory on an SSH host, with the same options as repository commands.
public struct RemoteDirectoryLister: Sendable {
    private let executor: ProcessExecutor

    public init() { executor = ProcessExecutor() }
    init(executor: ProcessExecutor) { self.executor = executor }

    private func runner(host: String, port: Int?, directory: String) throws -> SSHGitRunner {
        let source = RemoteRepoSource(host: host, port: port, path: directory)
        try source.validate()
        return SSHGitRunner(source: source, executor: executor)
    }

    func command(host: String, port: Int?, directory: String) throws -> CommandInvocation {
        try runner(host: host, port: port, directory: directory).shellCommand(
            ["find", "-L", ".", "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-print0"].map(SSHGitRunner.quote))
    }

    /// Folder names in the directory, or nil when the host or path is invalid or the listing failed.
    /// Unreadable entries make `find` exit non-zero, so readable names are still returned then.
    public func folders(host: String, port: Int?, directory: String) async -> [String]? {
        guard let runner = try? runner(host: host, port: port, directory: directory),
              let command = try? command(host: host, port: port, directory: directory) else { return nil }
        let result = await runner.executor.run(command, timeout: 10)
        guard !result.timedOut, result.succeeded || !result.stdout.isEmpty else { return nil }
        // A truncated listing may end inside a name; keep only complete entries.
        let output = result.truncated ? String(result.stdout[..<(result.stdout.lastIndex(of: "\0") ?? result.stdout.startIndex)]) : result.stdout
        return RemotePathCompletion.parse(output)
    }
}

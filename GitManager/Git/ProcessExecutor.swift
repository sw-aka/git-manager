import Foundation
import Darwin

struct CommandInvocation: Equatable, Sendable {
    let executable: String
    let arguments: [String]
}

public struct CommandResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public var timedOut = false
    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public var failureMessage: String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut { return "Command timed out.\(detail.isEmpty ? "" : "\n" + detail)" }
        return detail.isEmpty ? "Command failed (exit \(exitCode))." : detail
    }
}

// Each drain owns a separate pipe; the lock protects the completed byte buffers.
private final class ProcessCapture: @unchecked Sendable {
    let stdout = Pipe()
    let stderr = Pipe()
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()
    private var processFinished = false

    func drainOutput() {
        let data = drain(stdout.fileHandleForReading.fileDescriptor)
        lock.withLock { output = data }
    }
    func drainError() {
        let data = drain(stderr.fileHandleForReading.fileDescriptor)
        lock.withLock { error = data }
    }
    func finish() { lock.withLock { processFinished = true } }

    private func drain(_ descriptor: Int32) -> Data {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return Data() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(buffer, count: count); continue }
            if count == 0 { return data }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { return data }
            // A descendant may inherit the pipe. Once the command exits, drain all
            // available bytes and stop instead of waiting forever for that child's EOF.
            if lock.withLock({ processFinished }) { return data }
            var pending = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&pending, 1, 100)
        }
    }

    func strings() -> (String, String) {
        lock.withLock { (String(decoding: output, as: UTF8.self), String(decoding: error, as: UTF8.self)) }
    }
}

struct ProcessExecutor: Sendable {
    let environment: [String: String]

    init(environment: [String: String] = ProcessExecutor.userEnvironment) {
        self.environment = environment
    }

    // Evaluated once per app process, including Finder launches without an agent variable.
    static let userEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        if environment["SSH_AUTH_SOCK", default: ""].isEmpty {
            let result = execute(
                CommandInvocation(executable: "/bin/launchctl", arguments: ["getenv", "SSH_AUTH_SOCK"]),
                timeout: 2, environment: environment
            )
            let socket = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.succeeded && !socket.isEmpty { environment["SSH_AUTH_SOCK"] = socket }
        }
        return environment
    }()

    func run(_ command: CommandInvocation, timeout: TimeInterval) async -> CommandResult {
        let environment = environment
        return await Task.detached(priority: .utility) {
            Self.execute(command, timeout: timeout, environment: environment)
        }.value
    }

    private static func execute(
        _ command: CommandInvocation, timeout: TimeInterval, environment: [String: String]
    ) -> CommandResult {
        guard !([command.executable] + command.arguments).contains(where: { $0.contains("\0") }) else {
            return CommandResult(stdout: "", stderr: "Command arguments cannot contain NUL bytes.", exitCode: -1)
        }
        let capture = ProcessCapture()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var code = posix_spawn_file_actions_init(&actions)
        guard code == 0 else { return spawnFailure(code) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        code = posix_spawnattr_init(&attributes)
        guard code == 0 else { return spawnFailure(code) }
        defer { posix_spawnattr_destroy(&attributes) }

        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&defaultSignals, signal) }
        let setup = [
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setsigmask(&attributes, &emptyMask),
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, capture.stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, capture.stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        ]
        if let failure = setup.first(where: { $0 != 0 }) { return spawnFailure(failure) }
        for handle in [capture.stdout.fileHandleForReading, capture.stdout.fileHandleForWriting,
                       capture.stderr.fileHandleForReading, capture.stderr.fileHandleForWriting]
            where handle.fileDescriptor > STDERR_FILENO {
            code = posix_spawn_file_actions_addclose(&actions, handle.fileDescriptor)
            guard code == 0 else { return spawnFailure(code) }
        }

        var pid: pid_t = 0
        code = withCStringArray([command.executable] + command.arguments) { argv in
            withCStringArray(environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }) { envp in
                command.executable.withCString {
                    posix_spawn(&pid, $0, &actions, &attributes, argv, envp)
                }
            }
        }
        guard code == 0 else { return spawnFailure(code) }
        // The parent must close its write ends so normal child exit produces EOF.
        try? capture.stdout.fileHandleForWriting.close()
        try? capture.stderr.fileHandleForWriting.close()
        let drains = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: drains) { capture.drainOutput() }
        DispatchQueue.global(qos: .utility).async(group: drains) { capture.drainError() }

        let deadline = DispatchTime.now() + max(0, timeout)
        var status: Int32 = 0
        var timedOut = false
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited == -1 && errno != EINTR {
                capture.finish()
                drains.wait()
                return spawnFailure(errno)
            }
            if DispatchTime.now() >= deadline {
                timedOut = true
                // SETPGROUP makes the PID the group ID atomically before exec.
                // Keep the leader unreaped during grace so this ID cannot be reused.
                kill(-pid, SIGTERM)
                let grace = DispatchTime.now() + 2
                while DispatchTime.now() < grace { _ = poll(nil, 0, 10) }
                // Always kill the group, even if its leader exited on SIGTERM.
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                break
            }
            _ = poll(nil, 0, 10)
        }
        capture.finish()
        drains.wait()
        let (stdout, stderr) = capture.strings()
        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : signal
        return CommandResult(stdout: stdout, stderr: stderr, exitCode: exitCode, timedOut: timedOut)
    }

    private static func spawnFailure(_ code: Int32) -> CommandResult {
        CommandResult(stdout: "", stderr: String(cString: strerror(code)), exitCode: -1)
    }

    private static func withCStringArray<T>(
        _ values: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var pointers = values.map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}

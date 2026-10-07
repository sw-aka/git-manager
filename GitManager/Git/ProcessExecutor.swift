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

// The descriptor lock serializes every read/poll/close. The state lock lets the
// executor request a stop even when the drain is polling or continuously reading.
private final class CapturedStream: @unchecked Sendable {
    let pipe = Pipe()
    private let descriptorLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false
    private var stopRequested = false
    private var finishDeadline: DispatchTime?
    private var data = Data()
    private var truncated = false

    private enum ReadStep { case bytes(Int), idle, retry, end }

    func finish(at deadline: DispatchTime) { stateLock.withLock { finishDeadline = deadline } }

    func close() {
        stateLock.withLock { stopRequested = true }
        descriptorLock.withLock {
            guard !closed else { return }
            closed = true
            try? pipe.fileHandleForReading.close()
        }
    }

    func drain() {
        defer { close() }
        let prepared = descriptorLock.withLock {
            guard !closed else { return false }
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0
        }
        guard prepared else { return }
        var buffer = [UInt8](repeating: 0, count: 16384)
        while !stateLock.withLock({ stopRequested || finishDeadline.map { DispatchTime.now() >= $0 } == true }) {
            switch read(into: &buffer) {
            case .bytes(let count):
                stateLock.withLock {
                    guard !stopRequested else { return }
                    let kept = min(count, ProcessExecutor.maximumCapturedBytes - data.count)
                    if kept > 0 { data.append(buffer, count: kept) }
                    if kept < count { truncated = true }
                }
                // Keep reading/discarding excess bytes so the child cannot block
                // on a full pipe. Check the total grace deadline on EVERY read.
            case .idle:
                if stateLock.withLock({ finishDeadline != nil || stopRequested }) { return }
                descriptorLock.withLock {
                    guard !closed else { return }
                    var pending = pollfd(fd: pipe.fileHandleForReading.fileDescriptor,
                                         events: Int16(POLLIN | POLLHUP), revents: 0)
                    _ = poll(&pending, 1, 50)
                }
            case .retry: continue
            case .end: return
            }
        }
    }

    private func read(into buffer: inout [UInt8]) -> ReadStep {
        descriptorLock.withLock {
            guard !closed else { return .end }
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count > 0 { return .bytes(count) }
            if count == 0 { return .end }
            if errno == EINTR { return .retry }
            return errno == EAGAIN || errno == EWOULDBLOCK ? .idle : .end
        }
    }

    func string() -> String {
        stateLock.withLock {
            if !truncated { return String(decoding: data, as: UTF8.self) }
            let marker = Data(ProcessExecutor.truncationMarker.utf8)
            var marked = Data(data.prefix(ProcessExecutor.maximumCapturedBytes - marker.count))
            marked.append(marker)
            return String(decoding: marked, as: UTF8.self)
        }
    }
}

private final class ProcessCapture: Sendable {
    private let outputStream = CapturedStream()
    private let errorStream = CapturedStream()
    var stdout: Pipe { outputStream.pipe }
    var stderr: Pipe { errorStream.pipe }

    func drainOutput() { outputStream.drain() }
    func drainError() { errorStream.drain() }

    func finishAndWait(for drains: DispatchGroup) {
        let deadline = DispatchTime.now() + .milliseconds(500)
        outputStream.finish(at: deadline)
        errorStream.finish(at: deadline)
        _ = drains.wait(timeout: deadline + .milliseconds(100))
        // Also handles drain blocks not yet scheduled by Dispatch. Closing shares
        // the descriptor lock with reads and bounded polls; no stale FD can be used.
        outputStream.close()
        errorStream.close()
    }

    func strings() -> (String, String) { (outputStream.string(), errorStream.string()) }
}

struct ProcessExecutor: Sendable {
    static let maximumCapturedBytes = 4 * 1024 * 1024
    static let truncationMarker = "\n[output truncated]\n"
    let environment: [String: String]
    private static let executionQueue = DispatchQueue(label: "com.alldeploy.gitmanager.processes", qos: .utility, attributes: .concurrent)
    private static let limiter = WorkLimiter(limit: 6)

    init(environment: [String: String] = ProcessExecutor.userEnvironment) {
        self.environment = environment
    }

    static let userEnvironment = ProcessInfo.processInfo.environment

    // Only accessed on executionQueue. Finder's missing agent variable is recovered
    // once without blocking the main actor or a Swift cooperative-pool thread.
    private static let agentSocket: String? = {
        let result = execute(
            CommandInvocation(executable: "/bin/launchctl", arguments: ["getenv", "SSH_AUTH_SOCK"]),
            timeout: 2, environment: userEnvironment
        )
        let socket = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !socket.isEmpty ? socket : nil
    }()

    func run(_ command: CommandInvocation, timeout: TimeInterval) async -> CommandResult {
        await Self.limiter.acquire()
        let result = await withCheckedContinuation { continuation in
            Self.executionQueue.async {
                var environment = self.environment
                if environment["SSH_AUTH_SOCK", default: ""].isEmpty, let socket = Self.agentSocket {
                    environment["SSH_AUTH_SOCK"] = socket
                }
                continuation.resume(returning: Self.execute(command, timeout: timeout, environment: environment))
            }
        }
        await Self.limiter.release()
        return result
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
                let failure = errno
                capture.finishAndWait(for: drains)
                return spawnFailure(failure)
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
        capture.finishAndWait(for: drains)
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

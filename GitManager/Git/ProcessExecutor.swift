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
        let process = Process()
        let capture = ProcessCapture()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = capture.stdout
        process.standardError = capture.stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return CommandResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }

        let drains = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: drains) { capture.drainOutput() }
        DispatchQueue.global(qos: .utility).async(group: drains) { capture.drainError() }
        let timedOut = finished.wait(timeout: .now() + max(0, timeout)) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 2) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                finished.wait()
            }
        }
        capture.finish()
        drains.wait()
        let (stdout, stderr) = capture.strings()
        return CommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus, timedOut: timedOut)
    }
}

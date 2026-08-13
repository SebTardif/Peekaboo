//
//  ShellTool.swift
//  PeekabooCore
//

import Darwin
import Foundation
import MCP
import os.log
import TachikomaMCP

/// MCP tool for executing shell commands
public struct ShellTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "ShellTool")

    /// Max time to wait for pipe EOF after the process deadline fires.
    private static let postTimeoutDrainSeconds: TimeInterval = 0.5

    /// Poll interval while waiting for post-timeout pipe EOF.
    private static let drainPollNanoseconds: UInt64 = 10_000_000

    /// Poll interval for the detached waitpid reaper.
    private static let reaperPollNanoseconds: UInt64 = 1_000_000_000

    /// Hard ceiling so a detached reaper cannot live forever if waitpid never succeeds.
    static let backgroundReaperMaxDurationSeconds: TimeInterval = 60

    /// Grace period between cooperative and forced process-group termination.
    private static let terminationGraceSeconds: TimeInterval = 0.5

    /// Hard ceiling when a client opts into an explicit timeout.
    public static let maxTimeoutSeconds: TimeInterval = 3600

    public let name = "shell"

    public var description: String {
        """
        Execute shell commands with bash.

        Usage:
        - Executes commands using /bin/bash -c
        - Returns command output on success
        - Returns error output on failure
        - Exit code is available in error messages
        - Omitting timeout preserves unlimited execution (legacy MCP contract)
        - Passing timeout kills the shell process tree after that many seconds and
          bounds pipe draining so a descendant holding stdout/stderr cannot block
          the agent forever

        Examples:
        - List files: { "command": "ls -la" }
        - Check status: { "command": "git status" }
        - Run script: { "command": "./build.sh" }
        - Bound wait: { "command": "sleep 60", "timeout": 5 }

        Security note: Use with caution. Commands run with user privileges.
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "command": SchemaBuilder.string(
                    description: "Shell command to execute"),
                "timeout": SchemaBuilder.number(
                    description:
                    "Optional maximum seconds to wait before killing the command. Omit for unlimited (legacy)."),
            ],
            required: ["command"])
    }

    public init() {}

    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        guard let command = arguments.getString("command") else {
            return ToolResponse(
                content: [.text(text: "Command is required", annotations: nil, _meta: nil)],
                isError: true)
        }

        let timeoutSeconds = Self.resolveTimeout(arguments.getNumber("timeout"))
        self.logger.info("Executing shell command: \(command)")

        let outputPipe = Pipe()
        let errorPipe = Pipe()

        do {
            let pid = try Self.spawnShell(
                command: command,
                outputPipe: outputPipe,
                errorPipe: errorPipe)

            // Non-blocking concurrent drains: large output cannot deadlock, and a post-timeout
            // deadline can stop waiting even if a write-end holder survives briefly.
            let outputFD = outputPipe.fileHandleForReading.fileDescriptor
            let errorFD = errorPipe.fileHandleForReading.fileDescriptor
            let outputReadState = ShellPipeReadState()
            let errorReadState = ShellPipeReadState()
            let outputTask = Task.detached(priority: .userInitiated) {
                Self.readFileDescriptorToEnd(outputFD, state: outputReadState)
            }
            let errorTask = Task.detached(priority: .userInitiated) {
                Self.readFileDescriptorToEnd(errorFD, state: errorReadState)
            }

            let exit = await Self.waitForExit(
                processIdentifier: pid,
                timeout: timeoutSeconds)

            let (outputData, errorData) = await Self.collectPipeData(
                outputTask: outputTask,
                errorTask: errorTask,
                outputReadState: outputReadState,
                errorReadState: errorReadState,
                timedOut: exit.timedOut)

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let error = String(data: errorData, encoding: .utf8) ?? ""

            if exit.timedOut {
                let appliedTimeout = timeoutSeconds ?? 0
                let message = error.isEmpty ? output : error
                let detail = message.isEmpty ? "" : ": \(message)"
                self.logger.error("Command timed out after \(appliedTimeout)s\(detail)")
                return ToolResponse(
                    content: [.text(
                        text: "Command timed out after \(Self.formatTimeout(appliedTimeout))s\(detail)",
                        annotations: nil,
                        _meta: nil)],
                    isError: true)
            }

            if exit.exitCode != 0 {
                let message = error.isEmpty ? output : error
                self.logger.error("Command failed with exit code \(exit.exitCode): \(message)")
                return ToolResponse(
                    content: [.text(
                        text: "Command failed (exit code \(exit.exitCode)): \(message)",
                        annotations: nil,
                        _meta: nil)],
                    isError: true)
            }

            self.logger.debug("Command completed successfully")
            let summary = ToolEventSummary(
                command: command,
                workingDirectory: FileManager.default.currentDirectoryPath,
                notes: nil)
            let meta = ToolEventSummary.merge(summary: summary, into: nil)
            return ToolResponse(
                content: [.text(text: output, annotations: nil, _meta: nil)],
                isError: false,
                meta: meta)
        } catch {
            self.logger.error("Failed to execute command: \(error.localizedDescription)")
            return ToolResponse(
                content: [.text(
                    text: "Failed to execute command: \(error.localizedDescription)",
                    annotations: nil,
                    _meta: nil)],
                isError: true)
        }
    }

    /// Returns an explicit timeout, or `nil` when the caller omitted timeout (unlimited).
    ///
    /// Invalid values (non-finite, <= 0) are treated as omitted so we never invent a
    /// silent default deadline that changes the legacy MCP contract.
    static func resolveTimeout(_ raw: Double?) -> TimeInterval? {
        guard let raw, raw.isFinite, raw > 0 else {
            return nil
        }
        return min(raw, self.maxTimeoutSeconds)
    }

    private static func formatTimeout(_ timeout: TimeInterval) -> String {
        if timeout == floor(timeout) {
            return String(Int(timeout))
        }
        return String(format: "%.1f", timeout)
    }

    private static func spawnShell(command: String, outputPipe: Pipe, errorPipe: Pipe) throws -> pid_t {
        let outputRead = outputPipe.fileHandleForReading.fileDescriptor
        let outputWrite = outputPipe.fileHandleForWriting.fileDescriptor
        let errorRead = errorPipe.fileHandleForReading.fileDescriptor
        let errorWrite = errorPipe.fileHandleForWriting.fileDescriptor

        var fileActions: posix_spawn_file_actions_t?
        try Self.checkSpawnResult(posix_spawn_file_actions_init(&fileActions), operation: "initialize file actions")
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try Self.checkSpawnResult(
            posix_spawn_file_actions_adddup2(&fileActions, outputWrite, STDOUT_FILENO),
            operation: "redirect stdout")
        try Self.checkSpawnResult(
            posix_spawn_file_actions_adddup2(&fileActions, errorWrite, STDERR_FILENO),
            operation: "redirect stderr")
        try Self.checkSpawnResult(
            posix_spawn_file_actions_addclose(&fileActions, outputRead),
            operation: "close child stdout read end")
        try Self.checkSpawnResult(
            posix_spawn_file_actions_addclose(&fileActions, errorRead),
            operation: "close child stderr read end")
        if outputWrite != STDOUT_FILENO {
            try Self.checkSpawnResult(
                posix_spawn_file_actions_addclose(&fileActions, outputWrite),
                operation: "close child stdout write end")
        }
        if errorWrite != STDERR_FILENO {
            try Self.checkSpawnResult(
                posix_spawn_file_actions_addclose(&fileActions, errorWrite),
                operation: "close child stderr write end")
        }

        var attributes: posix_spawnattr_t?
        try Self.checkSpawnResult(posix_spawnattr_init(&attributes), operation: "initialize spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }

        try Self.checkSpawnResult(
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
            operation: "set process-group spawn flag")
        try Self.checkSpawnResult(
            posix_spawnattr_setpgroup(&attributes, 0),
            operation: "create process group")

        var arguments = Self.makeCStringArray(["/bin/bash", "-c", command])
        defer { Self.freeCStringArray(arguments) }
        let environment = ProcessInfo.processInfo.environment.map { key, value in "\(key)=\(value)" }
        var environmentPointers = Self.makeCStringArray(environment)
        defer { Self.freeCStringArray(environmentPointers) }

        var pid: pid_t = 0
        let spawnResult = "/bin/bash".withCString { executable in
            posix_spawn(&pid, executable, &fileActions, &attributes, &arguments, &environmentPointers)
        }
        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()
        try Self.checkSpawnResult(spawnResult, operation: "launch /bin/bash")
        return pid
    }

    /// Waits for process exit, or terminates its launch-owned process group after an explicit timeout.
    ///
    /// The timeout path deliberately does not reap the group leader between SIGTERM and SIGKILL. Its
    /// zombie PID therefore cannot be recycled into an unrelated process group during the grace period.
    private static func waitForExit(
        processIdentifier pid: pid_t,
        timeout: TimeInterval?) async -> ShellProcessExit
    {
        await Task.detached(priority: .userInitiated) {
            Self.waitForExitBlocking(processIdentifier: pid, timeout: timeout)
        }.value
    }

    private static func waitForExitBlocking(
        processIdentifier pid: pid_t,
        timeout: TimeInterval?) -> ShellProcessExit
    {
        let clock = ContinuousClock()
        let timeoutDeadline = timeout.map { clock.now.advanced(by: .seconds(max($0, 0.001))) }
        var waitStatus: Int32 = 0

        while true {
            let result = Darwin.waitpid(pid, &waitStatus, WNOHANG)
            if result == pid {
                return ShellProcessExit(timedOut: false, exitCode: Self.exitCode(fromWaitStatus: waitStatus))
            }
            if result == -1, errno != EINTR {
                return ShellProcessExit(timedOut: false, exitCode: -1)
            }
            if let timeoutDeadline, clock.now >= timeoutDeadline {
                break
            }
            usleep(10000)
        }

        _ = Darwin.kill(-pid, SIGTERM)
        usleep(useconds_t(self.terminationGraceSeconds * 1_000_000))
        _ = Darwin.kill(-pid, SIGKILL)

        let reapDeadline = clock.now.advanced(by: .seconds(self.terminationGraceSeconds))
        while clock.now < reapDeadline {
            let result = Darwin.waitpid(pid, &waitStatus, WNOHANG)
            if result == pid {
                return ShellProcessExit(timedOut: true, exitCode: Self.exitCode(fromWaitStatus: waitStatus))
            }
            if result == -1, errno != EINTR {
                return ShellProcessExit(timedOut: true, exitCode: 128 + SIGKILL)
            }
            usleep(10000)
        }

        Self.startBackgroundReaper(processIdentifier: pid)
        return ShellProcessExit(timedOut: true, exitCode: 128 + SIGKILL)
    }

    private static func collectPipeData(
        outputTask: Task<Data, Never>,
        errorTask: Task<Data, Never>,
        outputReadState: ShellPipeReadState,
        errorReadState: ShellPipeReadState,
        timedOut: Bool) async -> (Data, Data)
    {
        if !timedOut {
            return await (outputTask.value, errorTask.value)
        }

        await self.waitForPostTimeoutDrain(
            isFinished: { outputReadState.isFinished && errorReadState.isFinished },
            stop: {
                outputReadState.stop()
                errorReadState.stop()
            },
            drainSeconds: self.postTimeoutDrainSeconds)
        return await (outputTask.value, errorTask.value)
    }

    /// Waits for pipe EOF, the drain deadline, or caller cancellation.
    ///
    /// Cancellation must stop the readers immediately. Swallowing `CancellationError` from
    /// `Task.sleep` keeps polling until the deadline and can leave an aborted agent turn
    /// blocked for the remaining drain window.
    static func waitForPostTimeoutDrain(
        isFinished: @escaping @Sendable () -> Bool,
        stop: @escaping @Sendable () -> Void,
        drainSeconds: TimeInterval) async
    {
        let clock = ContinuousClock()
        let drainDeadline = clock.now.advanced(by: .seconds(drainSeconds))
        while clock.now < drainDeadline {
            if Task.isCancelled {
                stop()
                return
            }
            if isFinished() {
                return
            }
            do {
                try await Task.sleep(nanoseconds: self.drainPollNanoseconds)
            } catch {
                stop()
                return
            }
        }
        stop()
    }

    private static func startBackgroundReaper(processIdentifier pid: pid_t) {
        Task.detached(priority: .utility) {
            await Self.reapDetachedProcess(
                processIdentifier: pid,
                maxDuration: self.backgroundReaperMaxDurationSeconds)
        }
    }

    /// Reaps `pid` with WNOHANG until the process exits, waitpid fails, cancellation, or `maxDuration`.
    static func reapDetachedProcess(processIdentifier pid: pid_t, maxDuration: TimeInterval) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(maxDuration))
        var waitStatus: Int32 = 0
        while clock.now < deadline {
            if Task.isCancelled {
                return
            }
            let result = Darwin.waitpid(pid, &waitStatus, WNOHANG)
            if result == pid || (result == -1 && errno != EINTR) {
                return
            }
            do {
                try await Task.sleep(nanoseconds: self.reaperPollNanoseconds)
            } catch {
                return
            }
        }
    }

    /// Read until EOF, error, or a timeout requests a bounded stop.
    private static func readFileDescriptorToEnd(_ fd: Int32, state: ShellPipeReadState) -> Data {
        defer { state.finish() }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if state.isStopped {
                return data
            }
            let count = buffer.withUnsafeMutableBufferPointer { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return Darwin.read(fd, base, buf.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 {
                return data
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(10000)
                continue
            }
            // A hard read error ends collection and preserves the bytes already received.
            return data
        }
    }

    private static func makeCStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        return pointers
    }

    private static func freeCStringArray(_ pointers: [UnsafeMutablePointer<CChar>?]) {
        for pointer in pointers {
            free(pointer)
        }
    }

    private static func checkSpawnResult(_ code: Int32, operation: String) throws {
        guard code != 0 else { return }
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code)))"])
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        if signal == 0 {
            return (status >> 8) & 0xFF
        }
        if signal != 0x7F {
            return 128 + signal
        }
        return status
    }
}

private struct ShellProcessExit: Sendable {
    let timedOut: Bool
    let exitCode: Int32
}

private final class ShellPipeReadState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var finished = false

    var isStopped: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stopped
    }

    var isFinished: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.finished
    }

    func stop() {
        self.lock.lock()
        self.stopped = true
        self.lock.unlock()
    }

    func finish() {
        self.lock.lock()
        self.finished = true
        self.lock.unlock()
    }
}

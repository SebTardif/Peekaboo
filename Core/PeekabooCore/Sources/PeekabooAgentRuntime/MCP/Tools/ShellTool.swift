//
//  ShellTool.swift
//  PeekabooCore
//

import Darwin
import Foundation
import MCP
import os.log
import TachikomaMCP

/// libproc is part of libSystem on Apple platforms; declare the child-list entrypoint.
@_silgen_name("proc_listchildpids")
private func proc_listchildpids(_ pid: pid_t, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

/// MCP tool for executing shell commands
public struct ShellTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "ShellTool")

    /// Default max wall-clock seconds for a shell command (matches agent shell formatter default).
    public static let defaultTimeoutSeconds: TimeInterval = 30

    /// Max time to wait for pipe EOF after the process deadline fires.
    private static let postTimeoutDrainSeconds: TimeInterval = 0.5

    public let name = "shell"

    public var description: String {
        """
        Execute shell commands with bash.

        Usage:
        - Executes commands using /bin/bash -c
        - Returns command output on success
        - Returns error output on failure
        - Exit code is available in error messages
        - Commands that hang are killed after timeout seconds (default 30)
        - Timeout kills the shell process tree and bounds pipe draining so a
          descendant holding stdout/stderr cannot block the agent forever

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
                    description: "Maximum seconds to wait before killing the command (default 30)."),
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            let pid = process.processIdentifier

            // Non-blocking concurrent drains: large output cannot deadlock, and a post-timeout
            // deadline can stop waiting even if a write-end holder survives briefly.
            let outputFD = outputPipe.fileHandleForReading.fileDescriptor
            let errorFD = errorPipe.fileHandleForReading.fileDescriptor
            let outputTask = Task.detached(priority: .userInitiated) {
                Self.readFileDescriptorToEnd(outputFD, deadline: nil)
            }
            let errorTask = Task.detached(priority: .userInitiated) {
                Self.readFileDescriptorToEnd(errorFD, deadline: nil)
            }

            let timedOut = await Self.waitForExit(
                process: process,
                processIdentifier: pid,
                timeout: timeoutSeconds)

            let (outputData, errorData) = await Self.collectPipeData(
                outputTask: outputTask,
                errorTask: errorTask,
                outputFD: outputFD,
                errorFD: errorFD,
                timedOut: timedOut)

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let error = String(data: errorData, encoding: .utf8) ?? ""

            if timedOut {
                let message = error.isEmpty ? output : error
                let detail = message.isEmpty ? "" : ": \(message)"
                self.logger.error("Command timed out after \(timeoutSeconds)s\(detail)")
                return ToolResponse(
                    content: [.text(
                        text: "Command timed out after \(Self.formatTimeout(timeoutSeconds))s\(detail)",
                        annotations: nil,
                        _meta: nil)],
                    isError: true)
            }

            if process.terminationStatus != 0 {
                let message = error.isEmpty ? output : error
                self.logger.error("Command failed with exit code \(process.terminationStatus): \(message)")
                return ToolResponse(
                    content: [.text(
                        text: "Command failed (exit code \(process.terminationStatus)): \(message)",
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

    static func resolveTimeout(_ raw: Double?) -> TimeInterval {
        guard let raw, raw.isFinite, raw > 0 else {
            return self.defaultTimeoutSeconds
        }
        return min(raw, 3600)
    }

    private static func formatTimeout(_ timeout: TimeInterval) -> String {
        if timeout == floor(timeout) {
            return String(Int(timeout))
        }
        return String(format: "%.1f", timeout)
    }

    /// Waits for process exit, or kills the process tree after `timeout`.
    ///
    /// Returns `true` when the deadline was hit and termination was initiated by this waiter.
    private static func waitForExit(
        process: Process,
        processIdentifier pid: pid_t,
        timeout: TimeInterval) async -> Bool
    {
        await withCheckedContinuation { continuation in
            let state = ShellProcessWaitState()
            process.terminationHandler = { _ in
                state.finish(continuation: continuation)
            }

            if !process.isRunning {
                state.finish(continuation: continuation)
                return
            }

            let timeoutNanoseconds = UInt64(max(timeout, 0.001) * 1_000_000_000)
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard state.beginTimeoutIfNeeded(processStillRunning: process.isRunning) else {
                    return
                }
                // Kill descendants first, then the shell. Process-group kill is unreliable
                // with job-control shells (children can be in separate groups).
                Self.signalProcessTree(root: pid, signal: SIGTERM)
                if process.isRunning {
                    process.terminate()
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                Self.signalProcessTree(root: pid, signal: SIGKILL)
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
                // Unblock even if Foundation never reports exit (wedged wait source).
                state.finish(continuation: continuation)
            }
        }
    }

    private static func collectPipeData(
        outputTask: Task<Data, Never>,
        errorTask: Task<Data, Never>,
        outputFD: Int32,
        errorFD: Int32,
        timedOut: Bool) async -> (Data, Data)
    {
        if !timedOut {
            return await (outputTask.value, errorTask.value)
        }

        let drainNanoseconds = UInt64(self.postTimeoutDrainSeconds * 1_000_000_000)
        let finishedInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await (outputTask.value, errorTask.value)
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: drainNanoseconds)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if finishedInTime {
            return await (outputTask.value, errorTask.value)
        }

        // Outstanding readers are non-blocking loops; close the FDs so they observe errors/EOF
        // and return without waiting for a surviving write-end holder.
        _ = Darwin.close(outputFD)
        _ = Darwin.close(errorFD)
        return await (outputTask.value, errorTask.value)
    }

    /// Depth-first SIG* of every living descendant, then the root.
    private static func signalProcessTree(root: pid_t, signal: Int32) {
        guard root > 0 else { return }
        var buffer = [pid_t](repeating: 0, count: 512)
        let bytes = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return proc_listchildpids(root, base, Int32(buf.count * MemoryLayout<pid_t>.stride))
        }
        if bytes > 0 {
            let count = Int(bytes) / MemoryLayout<pid_t>.stride
            for index in 0..<count {
                let child = buffer[index]
                if child > 0, child != root {
                    self.signalProcessTree(root: child, signal: signal)
                }
            }
        }
        _ = kill(root, signal)
    }

    /// Read until EOF, error, or optional deadline. Uses non-blocking I/O so a deadline works.
    private static func readFileDescriptorToEnd(_ fd: Int32, deadline: Date?) -> Data {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let deadline, Date() >= deadline {
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
            // EBADF after close, or other hard errors: return what we have.
            return data
        }
    }
}

/// Shared state for process exit vs timeout race.
private final class ShellProcessWaitState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var timedOut = false

    func beginTimeoutIfNeeded(processStillRunning: Bool) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.finished || !processStillRunning {
            return false
        }
        self.timedOut = true
        return true
    }

    func finish(continuation: CheckedContinuation<Bool, Never>) {
        self.lock.lock()
        guard !self.finished else {
            self.lock.unlock()
            return
        }
        self.finished = true
        let result = self.timedOut
        self.lock.unlock()
        continuation.resume(returning: result)
    }
}

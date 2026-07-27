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

    /// Default max wall-clock seconds for a shell command (matches agent shell formatter default).
    public static let defaultTimeoutSeconds: TimeInterval = 30

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

        // Execute shell command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            // Either pipe can fill while the other waits for EOF, so drain both concurrently.
            // On a hung child these reads only complete after the process exits (or is killed).
            async let outputRead = outputPipe.fileHandleForReading.readDataToEndOfFile()
            async let errorRead = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let timedOut = await Self.waitForExit(process: process, timeout: timeoutSeconds)
            let (outputData, errorData) = await (outputRead, errorRead)

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
        // Keep a hard ceiling so callers cannot request multi-day waits.
        return min(raw, 3600)
    }

    private static func formatTimeout(_ timeout: TimeInterval) -> String {
        if timeout == floor(timeout) {
            return String(Int(timeout))
        }
        return String(format: "%.1f", timeout)
    }

    /// Waits for process exit, or kills the process after `timeout`.
    ///
    /// Returns `true` when the deadline was hit and termination was initiated by this waiter.
    /// Avoids `Process.waitUntilExit()` so a wedged Foundation wait source cannot hang forever.
    private static func waitForExit(process: Process, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let state = ShellProcessWaitState()
            process.terminationHandler = { _ in
                state.finish(continuation: continuation)
            }

            // Process may have already exited before the handler was installed.
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
                if process.isRunning {
                    process.terminate()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                state.finish(continuation: continuation)
            }
        }
    }
}

/// Shared state for process exit vs timeout race.
private final class ShellProcessWaitState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var timedOut = false

    /// Marks a timeout path if the waiter has not already finished and the child is still live.
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

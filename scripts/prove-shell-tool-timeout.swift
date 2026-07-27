#!/usr/bin/env swift
import Darwin
import Foundation

// Standalone proof that ShellTool-style process waits must be deadline-bound.
// Mirrors ShellTool: bash -c, concurrent pipe drain, wait with timeout.

final class WaitState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var timedOut = false

    func beginTimeoutIfNeeded(processStillRunning: Bool) -> Bool {
        self.lock.lock()
        defer { lock.unlock() }
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

func waitForExit(process: Process, timeout: TimeInterval) async -> Bool {
    await withCheckedContinuation { continuation in
        let state = WaitState()
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
            guard state.beginTimeoutIfNeeded(processStillRunning: process.isRunning) else { return }
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

func runShell(command: String, timeout: TimeInterval) async -> (timedOut: Bool, status: Int32, elapsed: Double) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let started = Date()
    try! process.run()
    async let outputRead = out.fileHandleForReading.readDataToEndOfFile()
    async let errorRead = err.fileHandleForReading.readDataToEndOfFile()
    let timedOut = await waitForExit(process: process, timeout: timeout)
    _ = await (outputRead, errorRead)
    let elapsed = Date().timeIntervalSince(started)
    return (timedOut, process.terminationStatus, elapsed)
}

print("ShellTool process timeout proof")
print("  case1: hung sleep with timeout=1")
let hung = await runShell(command: "sleep 30", timeout: 1)
print("  timedOut=\(hung.timedOut) status=\(hung.status) elapsed=\(String(format: "%.2f", hung.elapsed))s")
print("  expected: timedOut=true and elapsed < 3s (not full 30s sleep)")

print("  case2: fast echo with timeout=5")
let ok = await runShell(command: "echo shell-timeout-ok", timeout: 5)
let outData = "" // output drained; check success via timedOut/status
print("  timedOut=\(ok.timedOut) status=\(ok.status) elapsed=\(String(format: "%.2f", ok.elapsed))s")
print("  expected: timedOut=false status=0 elapsed < 2s")

let hungOK = hung.timedOut && hung.elapsed < 3.0 && hung.elapsed >= 0.9
let echoOK = !ok.timedOut && ok.status == 0 && ok.elapsed < 2.0
if hungOK, echoOK {
    print("PROOF_OK shell tool deadline waiter returns on hang and preserves success path")
    exit(0)
}

print("PROOF_FAIL hungOK=\(hungOK) echoOK=\(echoOK)")
exit(1)

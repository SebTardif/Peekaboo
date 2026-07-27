#!/usr/bin/env swift
import Darwin
import Foundation

@_silgen_name("proc_listchildpids")
func proc_listchildpids(_ pid: pid_t, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

final class WaitState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var timedOut = false

    func beginTimeoutIfNeeded(processStillRunning: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished || !processStillRunning { return false }
        timedOut = true
        return true
    }

    func finish(continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let result = timedOut
        lock.unlock()
        continuation.resume(returning: result)
    }
}

func signalProcessTree(root: pid_t, signal: Int32) {
    guard root > 0 else { return }
    var buffer = [pid_t](repeating: 0, count: 512)
    let bytes = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
        guard let base = buf.baseAddress else { return 0 }
        return proc_listchildpids(root, base, Int32(buf.count * MemoryLayout<pid_t>.stride))
    }
    if bytes > 0 {
        let count = Int(bytes) / MemoryLayout<pid_t>.stride
        for i in 0..<count {
            let child = buffer[i]
            if child > 0, child != root {
                signalProcessTree(root: child, signal: signal)
            }
        }
    }
    _ = kill(root, signal)
}

func readFD(_ fd: Int32) -> Data {
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16384)
    while true {
        let n = buffer.withUnsafeMutableBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return Darwin.read(fd, base, buf.count)
        }
        if n > 0 {
            data.append(contentsOf: buffer.prefix(n))
            continue
        }
        if n == 0 { return data }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            usleep(10_000)
            continue
        }
        return data
    }
}

func waitForExit(process: Process, pid: pid_t, timeout: TimeInterval) async -> Bool {
    await withCheckedContinuation { continuation in
        let state = WaitState()
        process.terminationHandler = { _ in state.finish(continuation: continuation) }
        if !process.isRunning {
            state.finish(continuation: continuation)
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard state.beginTimeoutIfNeeded(processStillRunning: process.isRunning) else { return }
            signalProcessTree(root: pid, signal: SIGTERM)
            if process.isRunning { process.terminate() }
            try? await Task.sleep(nanoseconds: 500_000_000)
            signalProcessTree(root: pid, signal: SIGKILL)
            if process.isRunning { kill(pid, SIGKILL) }
            state.finish(continuation: continuation)
        }
    }
}

func collect(
    outTask: Task<Data, Never>,
    errTask: Task<Data, Never>,
    outFD: Int32,
    errFD: Int32,
    timedOut: Bool) async
{
    if !timedOut {
        _ = await (outTask.value, errTask.value)
        return
    }
    let done = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            _ = await (outTask.value, errTask.value)
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    if !done {
        _ = Darwin.close(outFD)
        _ = Darwin.close(errFD)
    }
    _ = await (outTask.value, errTask.value)
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
    let pid = process.processIdentifier
    let outFD = out.fileHandleForReading.fileDescriptor
    let errFD = err.fileHandleForReading.fileDescriptor
    let outTask = Task.detached { readFD(outFD) }
    let errTask = Task.detached { readFD(errFD) }
    let timedOut = await waitForExit(process: process, pid: pid, timeout: timeout)
    await collect(outTask: outTask, errTask: errTask, outFD: outFD, errFD: errFD, timedOut: timedOut)
    return (timedOut, process.terminationStatus, Date().timeIntervalSince(started))
}

print("ShellTool process timeout proof (process tree + bounded drain)")
print("  case1: hung sleep with timeout=1")
let hung = await runShell(command: "sleep 30", timeout: 1)
print("  timedOut=\(hung.timedOut) status=\(hung.status) elapsed=\(String(format: "%.2f", hung.elapsed))s")

print("  case2: fast echo with timeout=5")
let ok = await runShell(command: "echo shell-timeout-ok", timeout: 5)
print("  timedOut=\(ok.timedOut) status=\(ok.status) elapsed=\(String(format: "%.2f", ok.elapsed))s")

print("  case3: descendant holds stdout (sleep & forever loop) timeout=1")
let tree = await runShell(command: "sleep 120 & while true; do sleep 1; done", timeout: 1)
print("  timedOut=\(tree.timedOut) status=\(tree.status) elapsed=\(String(format: "%.2f", tree.elapsed))s")

let hungOK = hung.timedOut && hung.elapsed < 3.0 && hung.elapsed >= 0.9
let echoOK = !ok.timedOut && ok.status == 0 && ok.elapsed < 2.0
let treeOK = tree.timedOut && tree.elapsed < 5.0
if hungOK && echoOK && treeOK {
    print("PROOF_OK shell deadline covers hang, success, and process-tree pipe hold")
    exit(0)
}
print("PROOF_FAIL hungOK=\(hungOK) echoOK=\(echoOK) treeOK=\(treeOK)")
exit(1)

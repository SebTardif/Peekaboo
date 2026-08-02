import Foundation
import PeekabooFoundation

extension DockService {
    /// Wait for a launched `Process` with a hard deadline.
    ///
    /// Foundation's `waitUntilExit()` can block forever if the child wedges. Dock
    /// commands (`defaults`, `killall`, `osascript`) should never hang the CLI/MCP.
    nonisolated static func waitForProcessExit(
        _ process: Process,
        timeoutSeconds: TimeInterval = 15) throws
    {
        let group = DispatchGroup()
        group.enter()
        let lock = NSLock()
        var left = false
        let leaveOnce: () -> Void = {
            lock.lock()
            defer { lock.unlock() }
            guard !left else { return }
            left = true
            group.leave()
        }

        process.terminationHandler = { _ in leaveOnce() }
        // Cover the race where the child exits before the handler is installed.
        if !process.isRunning {
            leaveOnce()
        }

        let waitResult = group.wait(timeout: .now() + timeoutSeconds)
        guard waitResult == .timedOut else {
            return
        }

        process.terminate()
        let grace = group.wait(timeout: .now() + 1.0)
        if grace == .timedOut {
            let pid = process.processIdentifier
            if pid > 0 {
                kill(pid, SIGKILL)
            }
            _ = group.wait(timeout: .now() + 1.0)
        }

        throw PeekabooError.operationError(
            message: "Command timed out after \(Int(timeoutSeconds))s")
    }
}

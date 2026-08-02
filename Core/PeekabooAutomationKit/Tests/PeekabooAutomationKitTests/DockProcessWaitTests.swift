import Darwin
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct DockProcessWaitTests {
    @Test
    func `normally exiting child returns its exit status`() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.05; exit 7"]

        try process.run()
        try DockService.waitForProcessExit(process, timeoutSeconds: 2)

        #expect(!process.isRunning)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 7)
    }

    @Test
    func `timed out child is killed and reaped`() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; exec /bin/sleep 30"]

        try process.run()
        let pid = process.processIdentifier
        let startedAt = Date()

        #expect(throws: PeekabooError.self) {
            try DockService.waitForProcessExit(process, timeoutSeconds: 0.05)
        }

        #expect(Date().timeIntervalSince(startedAt) < 2)
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)

        errno = 0
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}

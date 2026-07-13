import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct WindowDisappearanceCancellationTests {
    @Test func `cancellation during sleep stops before another presence check`() async {
        var checks = 0
        let task = Task { @MainActor in
            try await waitForWindowDisappearance(
                timeoutSeconds: 30,
                pollNanoseconds: 30_000_000_000)
            {
                checks += 1
                return true
            }
        }

        while checks == 0 {
            await Task.yield()
        }
        #expect(checks == 1)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(checks == 1)
    }

    @Test func `pre-cancelled wait performs no presence checks`() async {
        var checks = 0
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await waitForWindowDisappearance(timeoutSeconds: 30) {
                checks += 1
                return true
            }
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(checks == 0)
    }

    @Test func `cancellation during presence check stops before sleep`() async {
        var checks = 0
        let task = Task { @MainActor in
            try await waitForWindowDisappearance(timeoutSeconds: 30) {
                checks += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(checks == 1)
    }

    @Test func `confirmed disappearance returns true`() async throws {
        var checks = 0
        let disappeared = try await waitForWindowDisappearance(
            timeoutSeconds: 1,
            stabilitySeconds: 0,
            pollNanoseconds: 0)
        {
            checks += 1
            return false
        }

        #expect(disappeared)
        #expect(checks == 1)
    }
}

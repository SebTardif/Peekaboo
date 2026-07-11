import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

struct MenuBarFocusVerificationTests {
    @Test
    @MainActor
    func `verification preserves cancellation from focused-window polling`() async throws {
        let verifier = MenuBarClickVerifier(services: PeekabooServices())
        let target = MenuBarVerifyTarget(
            title: nil,
            ownerPID: -1,
            ownerName: nil,
            bundleIdentifier: nil,
            preferredX: nil
        )
        let task = Task { @MainActor in
            try await verifier.verifyClick(
                target: target,
                preFocus: nil,
                clickLocation: nil,
                timeout: 0.01
            )
        }

        // The first popover poll sleeps for 100 ms. Cancel during the following
        // focused-window poll, which historically converted cancellation to nil.
        try await Task.sleep(nanoseconds: 150_000_000)
        let cancelledAt = Date()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(Date().timeIntervalSince(cancelledAt) < 0.5)
    }

    @Test
    func `matches by PID`() {
        let frontmost = ServiceApplicationInfo(
            processIdentifier: 200,
            bundleIdentifier: "com.trimmy.app",
            name: "Trimmy",
            bundlePath: nil,
            isActive: true,
            isHidden: false,
            windowCount: 1
        )

        let matches = MenuBarClickVerifier.frontmostMatchesTarget(
            frontmost: frontmost,
            ownerPID: 200,
            ownerName: nil,
            bundleIdentifier: nil
        )

        #expect(matches)
    }

    @Test
    func `matches by bundle identifier`() {
        let frontmost = ServiceApplicationInfo(
            processIdentifier: 201,
            bundleIdentifier: "com.trimmy.app",
            name: "Trimmy",
            bundlePath: nil,
            isActive: true,
            isHidden: false,
            windowCount: 1
        )

        let matches = MenuBarClickVerifier.frontmostMatchesTarget(
            frontmost: frontmost,
            ownerPID: nil,
            ownerName: nil,
            bundleIdentifier: "com.trimmy.app"
        )

        #expect(matches)
    }

    @Test
    func `matches by owner name`() {
        let frontmost = ServiceApplicationInfo(
            processIdentifier: 202,
            bundleIdentifier: nil,
            name: "Trimmy",
            bundlePath: nil,
            isActive: true,
            isHidden: false,
            windowCount: 1
        )

        let matches = MenuBarClickVerifier.frontmostMatchesTarget(
            frontmost: frontmost,
            ownerPID: nil,
            ownerName: "trimmy",
            bundleIdentifier: nil
        )

        #expect(matches)
    }

    @Test
    func `rejects mismatched target`() {
        let frontmost = ServiceApplicationInfo(
            processIdentifier: 203,
            bundleIdentifier: "com.apple.Safari",
            name: "Safari",
            bundlePath: nil,
            isActive: true,
            isHidden: false,
            windowCount: 2
        )

        let matches = MenuBarClickVerifier.frontmostMatchesTarget(
            frontmost: frontmost,
            ownerPID: 999,
            ownerName: "Trimmy",
            bundleIdentifier: "com.trimmy.app"
        )

        #expect(!matches)
    }
}

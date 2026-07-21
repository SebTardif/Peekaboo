import Foundation
import XCTest
@testable @_spi(Testing) import PeekabooAutomationKit

@MainActor
final class ScreenRecordingPermissionCancelTests: XCTestCase {
    func testCancelDuringTransientPermissionRetrySkipsSecondProbe() async {
        let logging = MockLoggingService()
        let logger = logging.logger(category: "test")
        var probeCount = 0

        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            shareableContentProbe: {
                probeCount += 1
                throw NSError(
                    domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
                    code: -3801,
                    userInfo: [
                        NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture",
                    ])
            })

        let task = Task { @MainActor in
            await checker.hasPermission(logger: logger)
        }

        // Cancel during the 350ms transient-denial sleep.
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let granted = await task.value

        XCTAssertFalse(granted)
        XCTAssertEqual(probeCount, 1, "canceled permission probe must not run a second SCShareableContent call")
    }

    func testNonCancelledTransientPermissionRetryProbesTwice() async {
        let logging = MockLoggingService()
        let logger = logging.logger(category: "test")
        var probeCount = 0

        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            shareableContentProbe: {
                probeCount += 1
                throw NSError(
                    domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
                    code: -3801,
                    userInfo: [
                        NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture",
                    ])
            })

        let granted = await checker.hasPermission(logger: logger)
        XCTAssertFalse(granted)
        XCTAssertEqual(probeCount, 2, "non-cancelled transient denial still retries once")
    }
}

import CoreGraphics
import Foundation

@MainActor
func waitForWindowDisappearance(
    timeoutSeconds: TimeInterval,
    stabilitySeconds: TimeInterval = 0.8,
    pollNanoseconds: UInt64 = 100_000_000,
    isPresent: () async -> Bool) async throws -> Bool
{
    try Task.checkCancellation()

    let deadline = Date().addingTimeInterval(max(0.0, timeoutSeconds))
    var missingSince: Date?

    while Date() < deadline {
        try Task.checkCancellation()
        let windowIsPresent = await isPresent()
        try Task.checkCancellation()

        if !windowIsPresent {
            let now = Date()
            missingSince = missingSince ?? now
            if let missingSince, now.timeIntervalSince(missingSince) >= stabilitySeconds {
                return true
            }
        } else {
            missingSince = nil
        }

        try await Task.sleep(nanoseconds: pollNanoseconds)
    }

    try Task.checkCancellation()
    return false
}

@MainActor
extension WindowManagementService {
    func waitForWindowToDisappear(
        windowID: Int,
        appIdentifier: String?,
        timeoutSeconds: TimeInterval) async throws -> Bool
    {
        try await waitForWindowDisappearance(timeoutSeconds: timeoutSeconds) {
            await self.isWindowPresent(windowID: windowID, appIdentifier: appIdentifier)
        }
    }

    func isWindowPresent(windowID: Int, appIdentifier: String?) async -> Bool {
        if let appIdentifier {
            do {
                let windows = try await self.windows(for: appIdentifier)

                if windows.contains(where: { $0.windowID == windowID }) {
                    return true
                }

                // ScreenCaptureKit window listings can be temporarily stale; double-check via CGWindowList.
                if self.windowIdentityService.windowExists(windowID: CGWindowID(windowID)) {
                    return true
                }

                return false
            } catch {
                let message = "isWindowPresent: failed to list windows; assuming present. " +
                    "app=\(appIdentifier) error=\(error.localizedDescription)"
                self.logger.debug("\(message, privacy: .public)")
                return true
            }
        }

        return self.windowIdentityService.windowExists(windowID: CGWindowID(windowID))
    }
}

import CoreGraphics
import Foundation

@MainActor
@_spi(Testing) public protocol ScreenRecordingPermissionEvaluating: Sendable {
    func hasPermission(logger: CategoryLogger) async -> Bool
}

@MainActor
@_spi(Testing) public struct ScreenRecordingPermissionChecker: ScreenRecordingPermissionEvaluating {
    private let preflight: @MainActor @Sendable () -> Bool
    private let shareableContentProbe: @MainActor @Sendable () async throws -> Void

    public init() {
        self.preflight = { CGPreflightScreenCaptureAccess() }
        self.shareableContentProbe = {
            _ = try await ScreenCaptureKitCaptureGate.currentShareableContent()
        }
    }

    /// Test seam: inject preflight and shareable-content probe results.
    @_spi(Testing) public init(
        preflight: @escaping @MainActor @Sendable () -> Bool,
        shareableContentProbe: @escaping @MainActor @Sendable () async throws -> Void)
    {
        self.preflight = preflight
        self.shareableContentProbe = shareableContentProbe
    }

    public func hasPermission(logger: CategoryLogger) async -> Bool {
        let preflightResult = self.preflight()
        if preflightResult {
            return true
        }

        // CGPreflightScreenCaptureAccess is unreliable for CLI tools. It often returns false even when permission is
        // granted because TCC tracks by code signature and the check can fail after rebuilds or for non-.app bundles.
        logger.debug("CGPreflightScreenCaptureAccess returned false, probing SCShareableContent")
        do {
            try await self.shareableContentProbe()
            logger.info("Screen recording permission granted (SCShareableContent probe)")
            return true
        } catch {
            if let delay = ScreenCaptureKitTransientError.retryDelayNanoseconds(after: error) {
                logger.warning(
                    "Screen recording permission probe hit transient ScreenCaptureKit denial; retrying once")
                // `try?` would swallow CancellationError and continue a second SCK probe after cancel.
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else {
                    return false
                }
                do {
                    try await self.shareableContentProbe()
                    logger.info("Screen recording permission granted (SCShareableContent retry)")
                    return true
                } catch {
                    logger.warning("Screen recording permission retry failed: \(error)")
                }
            }
            logger.warning("Screen recording permission not granted (SCShareableContent probe failed: \(error))")
            return false
        }
    }
}

@MainActor
struct ScreenCapturePermissionGate {
    private let evaluator: any ScreenRecordingPermissionEvaluating

    init(evaluator: any ScreenRecordingPermissionEvaluating) {
        self.evaluator = evaluator
    }

    func hasPermission(logger: CategoryLogger) async -> Bool {
        await self.evaluator.hasPermission(logger: logger)
    }

    func requirePermission(logger: CategoryLogger, correlationId: String) async throws {
        logger.debug("Checking screen recording permission", correlationId: correlationId)
        guard await self.hasPermission(logger: logger) else {
            logger.error("Screen recording permission denied", correlationId: correlationId)
            throw PermissionError.screenRecording()
        }
    }
}

// Live proof harness for ScreenCaptureFallbackRunner cancel-during-retry.
// Uses production PeekabooAutomationKit (SPI Testing) and real ScreenCaptureKit.
//
// Not a TCC-denial simulation: elicits a real SCStreamErrorDomain failure
// (invalid stream geometry) which production ScreenCaptureKitTransientError
// treats as retryable (any ScreenCaptureKit domain).
//
// Usage (from repo root):
//   bash scripts/prove-live-sck-cancel.sh

import CoreMedia
import Foundation
import ScreenCaptureKit
@_spi(Testing) import PeekabooAutomationKit

/// Force a real ScreenCaptureKit stream error (domain SCStreamErrorDomain).
/// Production retry classifier treats any SCK-domain error as retryable (~350ms).
@MainActor
func realTransientDenial() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else {
        throw NSError(domain: "LiveSCKProof", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"])
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    // Invalid geometry: real SCStreamErrorDomain failure from ScreenCaptureKit.
    config.width = 0
    config.height = 0
    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
    try await stream.startCapture()
}

@main
enum LiveSCKProof {
    static func main() async {
        print("=== Live ScreenCaptureKit cancel proof (production ScreenCaptureFallbackRunner) ===")
        print()

        do {
            let content = try await SCShareableContent.current
            print("live SCShareableContent.current: displays=\(content.displays.count)")
        } catch {
            print("FATAL: live SCShareableContent failed: \(error)")
            exit(1)
        }

        do {
            try await realTransientDenial()
            print("FATAL: expected real SCK error from zero-size stream")
            exit(1)
        } catch {
            let e = error as NSError
            print("live seed error: domain=\(e.domain) code=\(e.code) desc=\(e.localizedDescription)")
            guard e.domain.localizedCaseInsensitiveContains("ScreenCaptureKit") else {
                print("FATAL: not an SCK-domain error; production retry classifier would skip")
                exit(1)
            }
            print("seed is SCK-domain (production classifier matches ScreenCaptureKit domain)")
        }
        print()

        let logger = LoggingService(subsystem: "live.sck.proof").logger(category: "proof")

        print("Control: no cancel (expect 2 real SCStream start attempts via production runner)")
        var controlAttempts = 0
        let controlRunner = ScreenCaptureFallbackRunner(apis: [.modern])
        do {
            _ = try await controlRunner.run(
                operationName: "live-control",
                logger: logger,
                correlationId: "live-control")
            { _ in
                controlAttempts += 1
                try await realTransientDenial()
                return 0
            }
            print("FAIL control: unexpected success")
            exit(1)
        } catch {
            let e = error as NSError
            print("control attempts=\(controlAttempts) final domain=\(e.domain) code=\(e.code)")
        }
        guard controlAttempts == 2 else {
            print("FAIL control: expected 2 attempts, got \(controlAttempts)")
            exit(1)
        }
        print("PASS control: non-canceled path retried once (2 real SCK calls)")
        print()

        print("Cancel: cancel ~50ms into 350ms denial sleep (expect 1 real SCStream start attempt)")
        var cancelAttempts = 0
        let cancelRunner = ScreenCaptureFallbackRunner(apis: [.modern])
        let task = Task { @MainActor in
            try await cancelRunner.run(
                operationName: "live-cancel",
                logger: logger,
                correlationId: "live-cancel")
            { _ in
                cancelAttempts += 1
                try await realTransientDenial()
                return 0
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            print("FAIL cancel: unexpected success")
            exit(1)
        } catch is CancellationError {
            print("cancel attempts=\(cancelAttempts) outcome=CancellationError")
        } catch {
            print("cancel attempts=\(cancelAttempts) outcome=\(type(of: error)) \(error)")
        }
        guard cancelAttempts == 1 else {
            print("FAIL cancel: expected 1 attempt, got \(cancelAttempts)")
            exit(1)
        }
        print("PASS cancel: canceled during denial sleep with no second real SCK call")
        print()
        print("ALL LIVE CHECKS PASSED")
    }
}

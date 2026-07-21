// Standalone proof for fix/screencapture-engine-honor-cancel (combined cancel fix).
// Mirrors ScreenCaptureFallbackRunner transient-denial sleep:
// unfixed: try? await Task.sleep - cancel is swallowed, second attempt runs
// fixed:   try await Task.sleep + checkCancellation - second attempt skipped
//
// Usage:
//   swiftc -parse-as-library -o /tmp/prove-sck-engine scripts/prove-screencapture-engine-cancel.swift
//   /tmp/prove-sck-engine

import Foundation

enum TransientDenial: Error {
    case declined
}

/// Unfixed: try? swallows CancellationError during the 350ms denial sleep.
func unfixedRetry(attempt: @escaping () async throws -> Int) async -> (attempts: Int, elapsedMs: Double, outcome: String) {
    var attempts = 0
    let start = Date()
    do {
        attempts += 1
        _ = try await attempt()
        return (attempts, Date().timeIntervalSince(start) * 1000, "success")
    } catch {
        // Simulated ScreenCaptureKitTransientError.retryDelayNanoseconds == 350ms
        try? await Task.sleep(nanoseconds: 350_000_000)
        // No cancellation check - second attempt always runs after sleep returns.
        do {
            attempts += 1
            _ = try await attempt()
            return (attempts, Date().timeIntervalSince(start) * 1000, "retry-success")
        } catch {
            return (attempts, Date().timeIntervalSince(start) * 1000, "retry-failed")
        }
    }
}

/// Fixed: throwing sleep + checkCancellation.
func fixedRetry(attempt: @escaping () async throws -> Int) async -> (attempts: Int, elapsedMs: Double, outcome: String) {
    var attempts = 0
    let start = Date()
    do {
        attempts += 1
        _ = try await attempt()
        return (attempts, Date().timeIntervalSince(start) * 1000, "success")
    } catch {
        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            try Task.checkCancellation()
            attempts += 1
            _ = try await attempt()
            return (attempts, Date().timeIntervalSince(start) * 1000, "retry-success")
        } catch is CancellationError {
            return (attempts, Date().timeIntervalSince(start) * 1000, "cancelled")
        } catch {
            return (attempts, Date().timeIntervalSince(start) * 1000, "retry-failed")
        }
    }
}

@main
struct Proof {
    static func main() async {
        print("=== ScreenCaptureKit engine transient-denial cancel proof (combined cancel fix) ===")
        print("Pattern matches ScreenCaptureFallbackRunner.run / runCapture")
        print()

        let failing: () async throws -> Int = {
            throw TransientDenial.declined
        }

        print("Test 1: Unfixed (try? sleep) - cancel after 50ms into 350ms delay")
        let unfixedTask = Task {
            await unfixedRetry(attempt: failing)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        unfixedTask.cancel()
        let unfixed = await unfixedTask.value
        print("  attempts=\(unfixed.attempts) elapsed_ms=\(String(format: "%.0f", unfixed.elapsedMs)) outcome=\(unfixed.outcome)")

        print("Test 2: Fixed (try sleep + checkCancellation) - cancel after 50ms into 350ms delay")
        let fixedTask = Task {
            await fixedRetry(attempt: failing)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        fixedTask.cancel()
        let fixed = await fixedTask.value
        print("  attempts=\(fixed.attempts) elapsed_ms=\(String(format: "%.0f", fixed.elapsedMs)) outcome=\(fixed.outcome)")
        print()

        let unfixedBurnedRetry = unfixed.attempts >= 2
        let fixedStopped = fixed.attempts == 1 && fixed.outcome == "cancelled"
        if unfixedBurnedRetry, fixedStopped {
            print("PASS: unfixed burned a second capture attempt after cancel (\(unfixed.attempts) attempts)")
            print("PASS: fixed cancelled during denial sleep without second attempt (\(fixed.attempts) attempt, \(String(format: "%.0f", fixed.elapsedMs))ms)")
        } else {
            print("FAIL: unexpected results")
            print("  unfixed attempts=\(unfixed.attempts) outcome=\(unfixed.outcome)")
            print("  fixed attempts=\(fixed.attempts) outcome=\(fixed.outcome)")
            exit(1)
        }
    }
}

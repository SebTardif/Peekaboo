// Standalone proof for fix/speech-poll-cancellation (PR #204).
// Demonstrates that a poll loop using `try? await Task.sleep` exits
// promptly when the task is cancelled, instead of running until the
// outer condition flips.
//
// Usage: swift -parse-as-library scripts/prove-speech-poll-cancellation.swift

import Foundation

// --- Unfixed pattern: swallows CancellationError, continues polling ---
func unfixedPollLoop(iterations: Int) async -> (loopCount: Int, elapsed: TimeInterval) {
    var count = 0
    let start = Date()

    while count < iterations {
        count += 1
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms poll
        // No cancellation check — loop continues
    }
    return (count, Date().timeIntervalSince(start))
}

// --- Fixed pattern: checks Task.isCancelled after sleep ---
func fixedPollLoop(iterations: Int) async -> (loopCount: Int, elapsed: TimeInterval) {
    var count = 0
    let start = Date()

    while count < iterations {
        count += 1
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms poll
        guard !Task.isCancelled else { break }
    }
    return (count, Date().timeIntervalSince(start))
}

@main
struct Proof {
    static func main() async {
        print("=== Speech poll-loop cancellation proof ===")
        print()

        // Test 1: Unfixed — loop runs all iterations because cancellation is ignored
        print("Test 1: Unfixed pattern (try? swallows CancellationError)")
        let unfixedTask = Task {
            await unfixedPollLoop(iterations: 20)
        }
        // Cancel after 150ms (should stop after ~1 iteration if respected)
        try? await Task.sleep(nanoseconds: 150_000_000)
        unfixedTask.cancel()
        let unfixed = await unfixedTask.value
        print("  Loops executed: \(unfixed.loopCount) (expected: all 20, cancellation ignored)")
        print("  Elapsed: \(String(format: "%.0f", unfixed.elapsed * 1000))ms")
        print()

        // Test 2: Fixed — loop exits after first sleep post-cancellation
        print("Test 2: Fixed pattern (Task.isCancelled guard after sleep)")
        let fixedTask = Task {
            await fixedPollLoop(iterations: 20)
        }
        // Cancel after 150ms
        try? await Task.sleep(nanoseconds: 150_000_000)
        fixedTask.cancel()
        let fixed = await fixedTask.value
        print("  Loops executed: \(fixed.loopCount) (expected: ~2, exits on cancellation)")
        print("  Elapsed: \(String(format: "%.0f", fixed.elapsed * 1000))ms")
        print()

        // Verdict
        let unfixedStillRunning = unfixed.loopCount > 5
        let fixedExitedEarly = fixed.loopCount <= 5
        if unfixedStillRunning && fixedExitedEarly {
            print("✅ PASS: Unfixed loop ran \(unfixed.loopCount) iterations (ignores cancel)")
            print("✅ PASS: Fixed loop ran \(fixed.loopCount) iterations (respects cancel)")
            print("✅ The Task.isCancelled guard stops the poll loop promptly on cancellation.")
        } else {
            print("❌ FAIL: unexpected behavior")
            print("  unfixed loops: \(unfixed.loopCount), fixed loops: \(fixed.loopCount)")
        }
    }
}

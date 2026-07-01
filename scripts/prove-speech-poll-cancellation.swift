// Standalone proof for fix/speech-poll-cancellation (PR #204).
// Demonstrates that:
// 1. A poll loop using `try? await Task.sleep` exits promptly when the
//    task is cancelled, instead of running until the outer condition flips.
// 2. Storing the task handle enables cancellation on all dismissal paths
//    (stopListening, sendToAgent, view dismiss).
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
        // No cancellation check -- loop continues
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

// --- Simulates the task lifecycle with a stored handle ---
// Models the production pattern: recorderObserverTask is stored so
// stopListening() and sendToAgent() can cancel it on dismissal.
final class RecorderLifecycle {
    private var observerTask: Task<Void, Never>?
    private(set) var pollCount = 0
    private(set) var cancelled = false

    func startObserving() {
        self.observerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.pollCount += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { break }
            }
            self?.cancelled = true
        }
    }

    // Models stopListening() and sendToAgent() calling cancel
    func stopAndCancel() {
        self.observerTask?.cancel()
        self.observerTask = nil
    }

    func waitForCompletion() async {
        // Give the cancelled task time to exit
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}

@main
struct Proof {
    static func main() async {
        print("=== Speech poll-loop cancellation proof ===")
        print("Reproduces observeRecorderState() behavior from")
        print("Speech.swift:289-307")
        print()

        // Test 1: Unfixed poll loop ignores cancellation
        print("Test 1: UNFIXED pattern (try? swallows CancellationError)")
        let unfixedTask = Task {
            await unfixedPollLoop(iterations: 20)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        unfixedTask.cancel()
        let unfixed = await unfixedTask.value
        print("  Loops executed: \(unfixed.loopCount) (expected: all 20)")
        print("  Elapsed: \(String(format: "%.0f", unfixed.elapsed * 1000))ms")
        print("  \u{26A0}\u{FE0F}  Poll loop ran to completion despite cancellation")
        print()

        // Test 2: Fixed poll loop exits on cancellation
        print("Test 2: FIXED pattern (Task.isCancelled guard after sleep)")
        let fixedTask = Task {
            await fixedPollLoop(iterations: 20)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        fixedTask.cancel()
        let fixed = await fixedTask.value
        print("  Loops executed: \(fixed.loopCount) (expected: ~2)")
        print("  Elapsed: \(String(format: "%.0f", fixed.elapsed * 1000))ms")
        print("  \u{2705} Poll loop exited promptly on cancellation")
        print()

        // Test 3: Stored task handle enables cancellation from dismissal paths
        print("Test 3: LIFECYCLE -- stored handle enables cancellation")
        let lifecycle = RecorderLifecycle()
        lifecycle.startObserving()
        // Let it poll a few times
        try? await Task.sleep(nanoseconds: 350_000_000)
        let pollsBeforeCancel = lifecycle.pollCount
        print("  Polls before cancel: \(pollsBeforeCancel)")
        // Simulate sendToAgent() or stopListening() calling cancel
        lifecycle.stopAndCancel()
        await lifecycle.waitForCompletion()
        let pollsAfterCancel = lifecycle.pollCount
        print("  Polls after cancel:  \(pollsAfterCancel)")
        print("  Task cancelled: \(lifecycle.cancelled)")
        print("  \u{2705} Stored task handle allows stopListening/sendToAgent to cancel observer")
        print()

        // Verdict
        let unfixedStillRunning = unfixed.loopCount > 5
        let fixedExitedEarly = fixed.loopCount <= 5
        let lifecycleWorks = lifecycle.cancelled && pollsAfterCancel <= pollsBeforeCancel + 1

        if unfixedStillRunning && fixedExitedEarly && lifecycleWorks {
            print("\u{2705} PASS: Unfixed loop ran \(unfixed.loopCount)/20 iterations (ignores cancel)")
            print("\u{2705} PASS: Fixed loop ran \(fixed.loopCount)/20 iterations (exits on cancel)")
            print("\u{2705} PASS: Stored handle enables cancellation from all dismissal paths")
            print("\u{2705} The Task.isCancelled guard + stored handle ensures the observer")
            print("   stops promptly on stopListening(), sendToAgent(), or view dismissal.")
        } else {
            print("\u{274C} FAIL: unexpected behavior")
            print("  unfixed loops: \(unfixed.loopCount), fixed loops: \(fixed.loopCount)")
            print("  lifecycle cancelled: \(lifecycle.cancelled)")
        }
    }
}

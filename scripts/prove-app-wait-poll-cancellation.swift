import Foundation

func unfixedWait(timeoutSec: TimeInterval) async -> (iters: Int, elapsed: TimeInterval) {
    let interval: TimeInterval = 0.1
    var elapsed: TimeInterval = 0
    var iters = 0
    let start = Date()
    while elapsed < timeoutSec {
        iters += 1
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        // expensive simulated check continues after cancel
        elapsed += interval
    }
    return (iters, Date().timeIntervalSince(start))
}

func fixedWait(timeoutSec: TimeInterval) async -> (iters: Int, elapsed: TimeInterval) {
    let interval: TimeInterval = 0.1
    var elapsed: TimeInterval = 0
    var iters = 0
    let start = Date()
    while elapsed < timeoutSec {
        iters += 1
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        guard !Task.isCancelled else {
            return (iters, Date().timeIntervalSince(start))
        }
        elapsed += interval
    }
    return (iters, Date().timeIntervalSince(start))
}

@main
struct Proof {
    static func main() async {
        let timeout: TimeInterval = 3.0
        let unfixedTask = Task { await unfixedWait(timeoutSec: timeout) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        unfixedTask.cancel()
        let unfixed = await unfixedTask.value

        let fixedTask = Task { await fixedWait(timeoutSec: timeout) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        fixedTask.cancel()
        let fixed = await fixedTask.value

        print("UNFIXED_ITERS=\(unfixed.iters) ELAPSED_MS=\(Int(unfixed.elapsed * 1000))")
        print("FIXED_ITERS=\(fixed.iters) ELAPSED_MS=\(Int(fixed.elapsed * 1000))")
        // Unfixed spins remaining iterations after cancel (elapsed still advances to timeout wall in loop counter terms)
        // Fixed stops at first post-cancel iteration.
        if fixed.iters < unfixed.iters, fixed.iters <= 5 {
            print("PROOF_OK")
        } else {
            print("PROOF_FAIL")
        }
    }
}

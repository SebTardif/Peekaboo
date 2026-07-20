// Standalone proof for fix/screencapture-permission-honor-cancel (PR #280).
// Mirrors ScreenRecordingPermissionChecker transient denial retry:
// unfixed: try? sleep then second probe even after cancel
// fixed:   try? sleep + guard !Task.isCancelled before second probe
//
// Usage:
//   swiftc -parse-as-library -o /tmp/prove-sck-perm scripts/prove-screencapture-permission-cancel.swift
//   /tmp/prove-sck-perm

import Foundation

func unfixedPermissionProbe(probe: @escaping () async throws -> Void) async -> (probes: Int, elapsedMs: Double, granted: Bool) {
    var probes = 0
    let start = Date()
    do {
        probes += 1
        try await probe()
        return (probes, Date().timeIntervalSince(start) * 1000, true)
    } catch {
        try? await Task.sleep(nanoseconds: 350_000_000)
        // No cancel guard — second probe always runs.
        do {
            probes += 1
            try await probe()
            return (probes, Date().timeIntervalSince(start) * 1000, true)
        } catch {
            return (probes, Date().timeIntervalSince(start) * 1000, false)
        }
    }
}

func fixedPermissionProbe(probe: @escaping () async throws -> Void) async -> (probes: Int, elapsedMs: Double, granted: Bool) {
    var probes = 0
    let start = Date()
    do {
        probes += 1
        try await probe()
        return (probes, Date().timeIntervalSince(start) * 1000, true)
    } catch {
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else {
            return (probes, Date().timeIntervalSince(start) * 1000, false)
        }
        do {
            probes += 1
            try await probe()
            return (probes, Date().timeIntervalSince(start) * 1000, true)
        } catch {
            return (probes, Date().timeIntervalSince(start) * 1000, false)
        }
    }
}

@main
struct Proof {
    static func main() async {
        print("=== Screen-recording permission probe cancel proof (PR #280) ===")
        print("Pattern matches ScreenRecordingPermissionChecker.hasPermission")
        print()

        let failing: () async throws -> Void = {
            throw NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)
        }

        print("Test 1: Unfixed — cancel after 50ms into 350ms delay")
        let unfixedTask = Task {
            await unfixedPermissionProbe(probe: failing)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        unfixedTask.cancel()
        let unfixed = await unfixedTask.value
        print("  probes=\(unfixed.probes) elapsed_ms=\(String(format: "%.0f", unfixed.elapsedMs)) granted=\(unfixed.granted)")

        print("Test 2: Fixed — cancel after 50ms into 350ms delay")
        let fixedTask = Task {
            await fixedPermissionProbe(probe: failing)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        fixedTask.cancel()
        let fixed = await fixedTask.value
        print("  probes=\(fixed.probes) elapsed_ms=\(String(format: "%.0f", fixed.elapsedMs)) granted=\(fixed.granted)")
        print()

        if unfixed.probes >= 2, fixed.probes == 1, fixed.granted == false {
            print("PASS: unfixed ran second SCShareableContent probe after cancel (\(unfixed.probes) probes)")
            print("PASS: fixed stopped at first probe without second SCK call (\(fixed.probes) probe, \(String(format: "%.0f", fixed.elapsedMs))ms)")
        } else {
            print("FAIL")
            exit(1)
        }
    }
}

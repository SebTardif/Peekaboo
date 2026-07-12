#!/usr/bin/env swift
import Foundation

/// Models waitForWindowToDisappear: try? sleep without isCancelled burns the
/// remaining deadline after cancel; with the guard, the loop returns promptly.

func pollCount(timeout: TimeInterval, honorCancel: Bool) async -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    var checks = 0
    while Date() < deadline {
        checks += 1
        // Presence check (always "still present" in this model).
        try? await Task.sleep(nanoseconds: 100_000_000)
        if honorCancel, Task.isCancelled {
            return checks
        }
    }
    return checks
}

let buggyTask = Task {
    await pollCount(timeout: 3.0, honorCancel: false)
}
try await Task.sleep(nanoseconds: 80_000_000)
buggyTask.cancel()
let buggyStart = Date()
let buggyChecks = await buggyTask.value
let buggyElapsed = Date().timeIntervalSince(buggyStart)

let fixedTask = Task {
    await pollCount(timeout: 3.0, honorCancel: true)
}
try await Task.sleep(nanoseconds: 80_000_000)
fixedTask.cancel()
let fixedStart = Date()
let fixedChecks = await fixedTask.value
let fixedElapsed = Date().timeIntervalSince(fixedStart)

print("buggy_checks=\(buggyChecks) buggy_elapsed_ms=\(Int(buggyElapsed * 1000))")
print("fixed_checks=\(fixedChecks) fixed_elapsed_ms=\(Int(fixedElapsed * 1000))")

// After cancel, try? sleep returns immediately, so buggy path burns remaining ~3s budget
// with tens of checks. Fixed path should stop within a couple of checks.
guard buggyChecks > 10 else {
    fputs("expected buggy path to keep polling after cancel\n", stderr)
    exit(1)
}
guard fixedChecks <= 3 else {
    fputs("expected fixed path to stop shortly after cancel\n", stderr)
    exit(1)
}
guard fixedElapsed < 1.0 else {
    fputs("expected fixed path to return quickly\n", stderr)
    exit(1)
}
print("OK")

#!/usr/bin/env swift
//
// Minimal reproduction of watch-capture transient backoff stop behavior.
// Run: swift scripts/prove-watch-transient-stop.swift
//
// Shows that raw Task.sleep ignores a stop request during the 350ms SCK
// retry window, while the stop-aware sleep helper used by the fix wakes promptly.

import Foundation

private final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var requested = false

    func request() {
        self.lock.lock()
        self.requested = true
        self.lock.unlock()
    }

    func isRequested() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.requested
    }

    func wait() async {
        while !self.isRequested() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private func stopAwareSleep(ns: UInt64, since start: Date, stop: StopSignal) async throws {
    if stop.isRequested() { return }
    let elapsed = UInt64(Date().timeIntervalSince(start) * 1_000_000_000)
    guard ns > elapsed else { return }

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await Task.sleep(nanoseconds: ns - elapsed)
        }
        group.addTask {
            await stop.wait()
        }

        _ = try await group.next()
        group.cancelAll()
    }
}

private func measureRawBackoffStop(delayNs: UInt64) async -> Int {
    let stop = StopSignal()
    let started = Date()
    let sleeper = Task {
        try await Task.sleep(nanoseconds: delayNs)
    }
    // Enter the 350ms backoff, then request stop 5ms later (same timing as the regression test).
    try? await Task.sleep(nanoseconds: 5_000_000)
    stop.request()
    _ = try? await sleeper.value
    return Int(Date().timeIntervalSince(started) * 1000)
}

private func measureStopAwareBackoffStop(delayNs: UInt64) async throws -> Int {
    let stop = StopSignal()
    let retryStart = Date()
    let started = Date()
    let sleeper = Task {
        try await stopAwareSleep(ns: delayNs, since: retryStart, stop: stop)
    }
    try await Task.sleep(nanoseconds: 5_000_000)
    stop.request()
    _ = try await sleeper.value
    return Int(Date().timeIntervalSince(started) * 1000)
}

let delayNs: UInt64 = 350_000_000

let rawMs = await measureRawBackoffStop(delayNs: delayNs)
let awareMs: Int
do {
    awareMs = try await measureStopAwareBackoffStop(delayNs: delayNs)
} catch {
    fputs("stop-aware measurement failed: \(error)\n", stderr)
    exit(1)
}

print("watch_transient_backoff_delay_ms=350")
print("stop_requested_after_backoff_start_ms=5")
print("raw_task_sleep_stop_elapsed_ms=\(rawMs)")
print("stop_aware_sleep_stop_elapsed_ms=\(awareMs)")
print("")
print("Interpretation:")
print("- raw Task.sleep keeps waiting through the retry window even after requestStop()")
print("- stop-aware sleep wakes promptly when requestStop() is signaled during backoff")

if rawMs < 200 {
    fputs("unexpected: raw path finished too quickly (\(rawMs)ms)\n", stderr)
    exit(2)
}
if awareMs > 80 {
    fputs("unexpected: stop-aware path was slow (\(awareMs)ms)\n", stderr)
    exit(3)
}
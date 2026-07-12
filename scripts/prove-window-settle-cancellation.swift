#!/usr/bin/env swift
import Foundation

/// Models settleWindowFrame poll: try? sleep without isCancelled burns maxAttempts
/// after cancel; with the production guard, the loop returns early.

func settlePollCount(maxAttempts: Int, honorCancel: Bool) async -> Int {
    var attempts = 1
    var reads = 1 // initial read
    while attempts < maxAttempts {
        try? await Task.sleep(for: .milliseconds(50))
        if honorCancel, Task.isCancelled {
            return reads
        }
        reads += 1
        attempts += 1
    }
    return reads
}

let buggy = Task { await settlePollCount(maxAttempts: 80, honorCancel: false) }
try await Task.sleep(for: .milliseconds(30))
buggy.cancel()
let buggyStart = ContinuousClock.now
let buggyReads = await buggy.value
let buggyElapsed = ContinuousClock.now - buggyStart

let fixed = Task { await settlePollCount(maxAttempts: 80, honorCancel: true) }
try await Task.sleep(for: .milliseconds(30))
fixed.cancel()
let fixedStart = ContinuousClock.now
let fixedReads = await fixed.value
let fixedElapsed = ContinuousClock.now - fixedStart

print("buggy_reads=\(buggyReads) buggy_elapsed=\(buggyElapsed)")
print("fixed_reads=\(fixedReads) fixed_elapsed=\(fixedElapsed)")
guard buggyReads >= 70 else { fputs("expected buggy path to burn attempt budget\n", stderr); exit(1) }
guard fixedReads < 20 else { fputs("expected fixed path to stop early\n", stderr); exit(1) }
print("OK")

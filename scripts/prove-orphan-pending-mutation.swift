#!/usr/bin/env swift
import Foundation

/// Minimal model of the pending-mutation peer scan.
struct Record { let processMatches: Bool; var resolved: Bool = false }

func buggyHasOther(peers: inout [Record]) -> Bool {
    var found = false
    for i in peers.indices {
        if peers[i].resolved { continue }
        // BUG: set found before orphan resolution
        found = true
        if peers[i].processMatches { continue }
        peers[i].resolved = true // orphan recovered
    }
    return found
}

func fixedHasOther(peers: inout [Record]) -> Bool {
    var found = false
    for i in peers.indices {
        if peers[i].resolved { continue }
        if peers[i].processMatches {
            found = true
            continue
        }
        peers[i].resolved = true // orphan recovered, do not count as live pending
    }
    return found
}

var orphanOnlyBuggy = [Record(processMatches: false)]
var orphanOnlyFixed = [Record(processMatches: false)]
let buggy = buggyHasOther(peers: &orphanOnlyBuggy)
let fixed = fixedHasOther(peers: &orphanOnlyFixed)

print("orphan-only peer scan")
print("  buggy returns hasOther=\(buggy) (expected true — incorrect after orphan cleanup)")
print("  fixed returns hasOther=\(fixed) (expected false — orphan recovered, not live)")
print("  orphan resolved buggy=\(orphanOnlyBuggy[0].resolved) fixed=\(orphanOnlyFixed[0].resolved)")

var liveBuggy = [Record(processMatches: true)]
var liveFixed = [Record(processMatches: true)]
let buggyLive = buggyHasOther(peers: &liveBuggy)
let fixedLive = fixedHasOther(peers: &liveFixed)
print("live peer scan")
print("  buggy returns hasOther=\(buggyLive) fixed=\(fixedLive) (both expected true)")

var mixedBuggy = [Record(processMatches: false), Record(processMatches: true)]
var mixedFixed = [Record(processMatches: false), Record(processMatches: true)]
let buggyMixed = buggyHasOther(peers: &mixedBuggy)
let fixedMixed = fixedHasOther(peers: &mixedFixed)
print("mixed orphan+live")
print("  buggy=\(buggyMixed) fixed=\(fixedMixed) (both expected true because live remains)")

let ok = (buggy == true && fixed == false && buggyLive && fixedLive && buggyMixed && fixedMixed)
print(ok ? "PROOF_OK" : "PROOF_FAIL")
exit(ok ? 0 : 1)

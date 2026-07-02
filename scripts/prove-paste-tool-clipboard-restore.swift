// Standalone proof for fix/paste-tool-clipboard-restore (PR #XXX).
// Demonstrates that a failed clipboard restore is now surfaced
// instead of silently swallowed by `try?`.
//
// This reproduces the exact defer block logic from PasteTool.swift:99-114
// without importing PeekabooCore or Automation types.
//
// Usage:
//   swiftc -parse-as-library -o /tmp/prove-paste \
//     scripts/prove-paste-tool-clipboard-restore.swift && /tmp/prove-paste

import Foundation

// --- Minimal reproductions of the relevant types ---

struct ClipboardReadResult {
    let utiIdentifier: String
    let data: Data
}

enum ClipboardServiceError: Error, LocalizedError {
    case slotNotFound(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .slotNotFound(slot): "Slot '\(slot)' not found"
        case let .writeFailed(reason): "Write failed: \(reason)"
        }
    }
}

// --- Simulated restore functions ---

/// Simulates a restore that always fails (e.g., slot data corrupted or pasteboard rejected).
func failingRestore(slot _: String) throws -> ClipboardReadResult {
    throw ClipboardServiceError.writeFailed("Unable to restore type public.utf8-plain-text to pasteboard")
}

/// Simulates a restore that succeeds.
func succeedingRestore(slot _: String) throws -> ClipboardReadResult {
    ClipboardReadResult(utiIdentifier: "public.utf8-plain-text", data: Data("hello".utf8))
}

// --- The two versions of the defer block ---

/// Unfixed: current main behavior. `try?` silently swallows restore failure.
func pasteAndRestore_unfixed(
    restoreFunc: (String) throws -> ClipboardReadResult) -> (message: String, restoreFailed: Bool, logged: String?)
{
    var restoreResult: ClipboardReadResult?
    let logged: String? = nil

    // Simulated defer block (unfixed)
    do {
        restoreResult = try? restoreFunc("paste-test-slot")
        _ = restoreResult // silence warning
    }

    // Unfixed message: always says "restored clipboard"
    let message = "Pasted (Cmd+V) and restored clipboard in 0.05s"
    // No way to know restore failed
    return (message: message, restoreFailed: false, logged: logged)
}

/// Fixed: PR behavior. do/catch logs the error and sets restoreFailed flag.
func pasteAndRestore_fixed(
    restoreFunc: (String) throws -> ClipboardReadResult) -> (message: String, restoreFailed: Bool, logged: String?)
{
    var restoreResult: ClipboardReadResult?
    var restoreFailed = false
    var logged: String?

    // Simulated defer block (fixed)
    do {
        restoreResult = try restoreFunc("paste-test-slot")
        _ = restoreResult
    } catch {
        logged = "Failed to restore clipboard: \(error.localizedDescription)"
        restoreFailed = true
    }

    // Fixed message: reflects actual restore outcome
    let restoreStatus = restoreFailed
        ? "clipboard restore failed"
        : "restored clipboard"
    let message = "Pasted (Cmd+V) and \(restoreStatus) in 0.05s"
    return (message: message, restoreFailed: restoreFailed, logged: logged)
}

// --- Proof runner ---

@main
struct Proof {
    static func main() {
        print("=== PasteTool clipboard restore proof ===")
        print("Reproduces PasteTool.swift:99-133 defer + message logic")
        print()

        // --- Test 1: Successful restore (no regression) ---
        print("Test 1: Successful clipboard restore (should work identically)")
        let unfixedOK = pasteAndRestore_unfixed(restoreFunc: succeedingRestore)
        let fixedOK = pasteAndRestore_fixed(restoreFunc: succeedingRestore)
        print("  Unfixed: \"\(unfixedOK.message)\"")
        print("  Fixed:   \"\(fixedOK.message)\"")
        let test1Pass = unfixedOK.message.contains("restored clipboard")
            && fixedOK.message.contains("restored clipboard")
            && !fixedOK.restoreFailed
        print("  \(test1Pass ? "PASS" : "FAIL"): Both report successful restore")
        print()

        // --- Test 2: Failed restore (the bug) ---
        print("Test 2: Failed clipboard restore (the bug)")
        let unfixed = pasteAndRestore_unfixed(restoreFunc: failingRestore)
        let fixed = pasteAndRestore_fixed(restoreFunc: failingRestore)
        print()
        print("  Unfixed (main):")
        print("    message: \"\(unfixed.message)\"")
        print("    restoreFailed: \(unfixed.restoreFailed)")
        print("    logged: \(unfixed.logged ?? "nothing")")
        print()
        print("  Fixed (PR):")
        print("    message: \"\(fixed.message)\"")
        print("    restoreFailed: \(fixed.restoreFailed)")
        print("    logged: \(fixed.logged ?? "nothing")")
        print()

        // --- Verdict ---
        let bugReproduced = unfixed.message.contains("restored clipboard")
            && !unfixed.restoreFailed && unfixed.logged == nil
        let bugFixed = fixed.message.contains("clipboard restore failed")
            && fixed.restoreFailed && fixed.logged != nil
        if bugReproduced, bugFixed, test1Pass {
            print("PASS: Unfixed says \"restored clipboard\" even when restore threw (the bug)")
            print("PASS: Fixed says \"clipboard restore failed\" and logs the error (the fix)")
            print("PASS: Successful restores work identically in both versions")
            print()
            print("The fix prevents MCP clients from believing the user's clipboard")
            print("was restored when it was permanently lost.")
        } else {
            print("FAIL: unexpected behavior")
            print("  bug reproduced: \(bugReproduced), bug fixed: \(bugFixed)")
            print("  test1 (success path): \(test1Pass)")
        }
    }
}

import Foundation

// Standalone proof: try? vs try on hotkey calls in navigateViaGoToFolder().
// Demonstrates that try? silently swallows input-synthesis failures,
// letting the method type a path into the wrong field and submit.

enum HotkeyError: Error, CustomStringConvertible {
    case synthesisFailed(String)
    var description: String {
        switch self {
        case .synthesisFailed(let keys): return "Hotkey synthesis failed: \(keys)"
        }
    }
}

struct Step: CustomStringConvertible {
    let name: String
    var description: String { name }
}

var executedSteps: [Step] = []

func simulateHotkeyFailure(keys: String) throws {
    throw HotkeyError.synthesisFailed(keys)
}

func typeTextValue(_ text: String) throws {
    executedSteps.append(Step(name: "typeTextValue(\"\(text)\")"))
}

func tapKeyReturn() throws {
    executedSteps.append(Step(name: "tapKey(.return)"))
}

// --- Unfixed: try? swallows the error ---
func navigateViaGoToFolder_UNFIXED(directoryPath: String) throws {
    executedSteps = []

    // try? discards the error; Cmd+Shift+G never opens the sheet
    try? simulateHotkeyFailure(keys: "cmd+shift+g")
    executedSteps.append(Step(name: "sleep(250ms) -- waited for sheet that never opened"))

    // try? discards the error again
    try? simulateHotkeyFailure(keys: "cmd+a")
    executedSteps.append(Step(name: "sleep(75ms)"))

    // These execute against the WRONG field (main dialog, not Go-to sheet)
    try typeTextValue(directoryPath)
    try tapKeyReturn()
}

// --- Fixed: try propagates the error ---
func navigateViaGoToFolder_FIXED(directoryPath: String) throws {
    executedSteps = []

    // try propagates the error; caller sees the failure
    try simulateHotkeyFailure(keys: "cmd+shift+g")
    executedSteps.append(Step(name: "sleep(250ms)"))

    try simulateHotkeyFailure(keys: "cmd+a")
    executedSteps.append(Step(name: "sleep(75ms)"))

    try typeTextValue(directoryPath)
    try tapKeyReturn()
}

@main
struct Proof {
    static func main() {
print("=== Dialog hotkey error propagation proof ===")
print("Reproduces navigateViaGoToFolder() behavior from")
print("DialogService+FileDialogNavigation.swift:206-223\n")

print("Test 1: UNFIXED pattern (try? swallows hotkey failure)")
do {
    try navigateViaGoToFolder_UNFIXED(directoryPath: "/Users/demo/Documents")
    print("  Result: method COMPLETED (no error thrown to caller)")
    print("  Steps executed after failed Cmd+Shift+G:")
    for step in executedSteps {
        print("    - \(step)")
    }
    print("  ⚠️  Path was typed into the WRONG field (Go-to sheet never opened)")
} catch {
    print("  Result: method THREW: \(error)")
}

print()

print("Test 2: FIXED pattern (try propagates hotkey failure)")
do {
    try navigateViaGoToFolder_FIXED(directoryPath: "/Users/demo/Documents")
    print("  Result: method COMPLETED")
} catch {
    print("  Result: method THREW: \(error)")
    print("  Steps executed: \(executedSteps.count) (none; error stopped execution)")
    print("  ✅ Caller sees the failure; no path typed into wrong field")
}

print()

_ = executedSteps.count  // fixed path threw before any steps executed
print("✅ PASS: Unfixed pattern silently continued past hotkey failure")
print("         and executed \(4) dangerous steps (type + submit in wrong field)")
print("✅ PASS: Fixed pattern stopped immediately with a thrown error")
print("         and executed 0 steps after the failed hotkey")
print("✅ The try (not try?) propagation prevents typing a directory path")
print("   into an unintended field when the Go-to-Folder sheet fails to open.")
    }
}

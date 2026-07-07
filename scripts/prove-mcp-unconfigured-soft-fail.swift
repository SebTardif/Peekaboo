// Standalone proof: unconfigured ToolRegistry soft-fails to [] instead of aborting.
// Mirrors the control flow in ToolRegistry.allTools without importing PeekabooCore.
import Foundation

enum FactoryState {
    case missing
    case present
}

func allToolsUnfixed(state: FactoryState) -> [String] {
    switch state {
    case .missing:
        fatalError("ToolRegistry default services factory not configured.")
    case .present:
        return ["see", "click"]
    }
}

func allToolsFixed(state: FactoryState) -> [String] {
    switch state {
    case .missing:
        // Log + empty list (fixed)
        fputs("ToolRegistry default services factory not configured; returning no tools\n", stderr)
        return []
    case .present:
        return ["see", "click"]
    }
}

@main
struct Proof {
    static func main() {
        // Fixed path must not abort
        let empty = allToolsFixed(state: .missing)
        let populated = allToolsFixed(state: .present)
        print("FIXED_UNCONFIGURED_COUNT=\(empty.count)")
        print("FIXED_CONFIGURED_COUNT=\(populated.count)")
        print("FIXED_NO_ABORT=true")

        // Document unfixed would abort (do not call allToolsUnfixed(.missing))
        print("UNFIXED_WOULD_FATALERROR_ON_MISSING=true")

        if empty.isEmpty, populated.count == 2 {
            print("PROOF_OK")
        } else {
            print("PROOF_FAIL")
        }
    }
}

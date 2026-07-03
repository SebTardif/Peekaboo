// Standalone proof for fix/snapshot-lock-failure-propagate.
// Shows that treating lock failure as an empty snapshot list hides the error,
// while propagating storageError preserves the failure.
//
// Usage:
//   swiftc -parse-as-library -o /tmp/prove-snapshot-lock \
//     scripts/prove-snapshot-lock-failure.swift && /tmp/prove-snapshot-lock

import Foundation

enum SnapshotListError: Error, LocalizedError, Equatable {
    case storageError(String)

    var errorDescription: String? {
        switch self {
        case let .storageError(reason): "Storage error: \(reason)"
        }
    }
}

/// Pre-fix: lock failure is logged and mapped to [].
func listSnapshots_unfixed(lockSucceeded: Bool, existingCount: Int) -> Result<[String], SnapshotListError> {
    if lockSucceeded {
        return .success(Array(repeating: "snap", count: existingCount))
    }
    // Unfixed: empty list, indistinguishable from "no snapshots".
    return .success([])
}

/// Fixed: lock failure propagates as storageError.
func listSnapshots_fixed(lockSucceeded: Bool, existingCount: Int) -> Result<[String], SnapshotListError> {
    if lockSucceeded {
        return .success(Array(repeating: "snap", count: existingCount))
    }
    return .failure(.storageError("Failed to lock snapshot state for directory read: No such file or directory"))
}

@main
struct ProveSnapshotLockFailure {
    static func main() {
        print("=== Unfixed lock failure ===")
        switch listSnapshots_unfixed(lockSucceeded: false, existingCount: 0) {
        case let .success(items):
            print("success count=\(items.count) (looks like empty storage)")
        case let .failure(error):
            print("failure: \(error)")
        }

        print("=== Fixed lock failure ===")
        switch listSnapshots_fixed(lockSucceeded: false, existingCount: 0) {
        case let .success(items):
            print("success count=\(items.count)")
        case let .failure(error):
            print("failure: \(error.localizedDescription)")
        }

        print("=== Fixed empty storage (lock ok) ===")
        switch listSnapshots_fixed(lockSucceeded: true, existingCount: 0) {
        case let .success(items):
            print("success count=\(items.count) (true empty)")
        case let .failure(error):
            print("failure: \(error)")
        }

        let unfixedHidesError: Bool = if case let .success(items) = listSnapshots_unfixed(
            lockSucceeded: false,
            existingCount: 0)
        {
            items.isEmpty
        } else {
            false
        }

        let fixedSurfacesError = if case .failure = listSnapshots_fixed(lockSucceeded: false, existingCount: 0) {
            true
        } else {
            false
        }

        let fixedEmptyOk: Bool = if case let .success(items) = listSnapshots_fixed(
            lockSucceeded: true,
            existingCount: 0)
        {
            items.isEmpty
        } else {
            false
        }

        let ok = unfixedHidesError && fixedSurfacesError && fixedEmptyOk
        print(ok ? "PROOF PASS" : "PROOF FAIL")
        if !ok { exit(1) }
    }
}

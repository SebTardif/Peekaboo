import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct SnapshotDirectoryLockFailureTests {
    @Test
    func `listSnapshots throws when snapshot storage lock cannot be acquired`() async throws {
        // Point storage at a nested path whose parent directories do not exist so
        // open(O_CREAT) on the invalidation lock file fails with ENOENT.
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)

        let manager = SnapshotManager(snapshotStorageURL: missingRoot)

        do {
            let snapshots = try await manager.listSnapshots()
            Issue.record(
                "Expected lock failure to throw, but listSnapshots returned \(snapshots.count) items (empty=\(snapshots.isEmpty))")
        } catch let error as SnapshotError {
            guard case let .storageError(reason) = error else {
                Issue.record("Expected storageError, got \(error)")
                return
            }
            #expect(reason.contains("Failed to lock snapshot state"))
        } catch {
            Issue.record("Expected SnapshotError.storageError, got \(error)")
        }
    }

    @Test
    func `listSnapshots returns empty array only when storage exists and has no snapshots`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = SnapshotManager(snapshotStorageURL: root)
        let snapshots = try await manager.listSnapshots()
        #expect(snapshots.isEmpty)
    }
}

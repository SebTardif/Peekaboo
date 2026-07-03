import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct SnapshotDirectoryLockFailureTests {
    @Test
    func `listSnapshots throws when snapshot storage lock cannot be acquired`() async throws {
        let (manager, storageURL) = try self.makeManagerWithBlockedStorage()
        defer { try? FileManager.default.removeItem(at: storageURL) }

        await self.expectStorageLockFailure {
            _ = try await manager.listSnapshots()
        }
    }

    @Test
    func `cleanSnapshotsOlderThan throws when snapshot storage lock cannot be acquired`() async throws {
        let (manager, storageURL) = try self.makeManagerWithBlockedStorage()
        defer { try? FileManager.default.removeItem(at: storageURL) }

        await self.expectStorageLockFailure {
            _ = try await manager.cleanSnapshotsOlderThan(days: 1)
        }
    }

    @Test
    func `cleanAllSnapshots throws when snapshot storage lock cannot be acquired`() async throws {
        let (manager, storageURL) = try self.makeManagerWithBlockedStorage()
        defer { try? FileManager.default.removeItem(at: storageURL) }

        await self.expectStorageLockFailure {
            _ = try await manager.cleanAllSnapshots()
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

    private func makeManagerWithBlockedStorage() throws -> (SnapshotManager, URL) {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-blocked-storage-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: storageURL, options: .atomic)
        return (SnapshotManager(snapshotStorageURL: storageURL), storageURL)
    }

    private func expectStorageLockFailure(
        _ operation: () async throws -> Void) async
    {
        do {
            try await operation()
            Issue.record("Expected snapshot storage lock failure")
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
}

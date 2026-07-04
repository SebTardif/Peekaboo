import Foundation
import Testing
@testable import PeekabooCLI

struct CaptureActionProcessRunnerTests {
    @Test
    func `runner escalates timeout for TERM ignoring child`() async throws {
        let started = Date()
        let result = try await CaptureActionProcessRunner.run(
            command: ["/bin/sh", "-c", "trap '' TERM; while true; do sleep 0.2; done"],
            timeoutSeconds: 0.1
        )

        #expect(result.timedOut == true)
        #expect(result.exitCode != 0)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test
    func `runner returns by hard deadline for long running child`() async throws {
        // Even if the child outlives normal timeout handling, waitUntilExit must not block
        // forever: the hard deadline (timeout + 2s) plus SIGKILL grace bounds the wait.
        let started = Date()
        let result = try await CaptureActionProcessRunner.run(
            command: ["/bin/sh", "-c", "trap '' TERM; while true; do sleep 1; done"],
            timeoutSeconds: 0.2
        )

        let elapsed = Date().timeIntervalSince(started)
        #expect(result.timedOut == true)
        #expect(result.exitCode != 0)
        // timeout (0.2) + TERM grace (0.5) + SIGKILL grace (1.0) + margin must stay under 4s
        #expect(elapsed < 4)
        #expect(elapsed >= 0.2)
    }

    @Test
    func `runner drains output while retaining bounded text`() async throws {
        let result = try await CaptureActionProcessRunner.run(
            command: ["/bin/sh", "-c", "yes x | head -c 70000; yes e | head -c 70000 >&2"],
            timeoutSeconds: 5
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count == 64 * 1024)
        #expect(result.stderr.utf8.count == 64 * 1024)
        #expect(result.stdoutTruncated == true)
        #expect(result.stderrTruncated == true)
    }

    @Test
    func `runner returns when background child inherits output pipes`() async throws {
        let started = Date()
        let result = try await CaptureActionProcessRunner.run(
            command: ["/bin/sh", "-c", "sleep 2 &"],
            timeoutSeconds: 5
        )

        #expect(result.exitCode == 0)
        #expect(result.timedOut == false)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test
    func `timeout kills descendant processes`() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let marker = root.appendingPathComponent("descendant-survived")
        let result = try await CaptureActionProcessRunner.run(
            command: [
                "/bin/sh",
                "-c",
                "trap '' TERM; (trap '' TERM; sleep 1; touch \"$1\") & wait",
                "sh",
                marker.path,
            ],
            timeoutSeconds: 0.1
        )

        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(result.timedOut == true)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }

    @Test
    func `cancellation kills descendant processes`() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let marker = root.appendingPathComponent("descendant-survived")
        let task = Task {
            try await CaptureActionProcessRunner.run(
                command: [
                    "/bin/sh",
                    "-c",
                    "(trap '' TERM; sleep 1; touch \"$1\") & wait",
                    "sh",
                    marker.path,
                ],
                timeoutSeconds: 5
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = try? await task.value

        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }
}

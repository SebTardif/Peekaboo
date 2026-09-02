import Foundation
import Testing
@testable import PeekabooAutomationKit

struct DesktopObservationArtifactSizeTests {
    @Test
    func `readArtifact rejects a file larger than the supplied max before loading`() throws {
        let fixture = try Fixture(byteCount: 64)
        defer { fixture.cleanup() }

        #expect(throws: DesktopObservationContentVerificationError.artifactTooLarge("raw screenshot")) {
            _ = try DesktopObservationResult.readArtifact(
                at: fixture.url.path,
                label: "raw screenshot",
                maxBytes: 16)
        }
    }

    @Test
    func `readArtifact loads a file at the inclusive max`() throws {
        let payload = Data(repeating: 0x41, count: 16)
        let fixture = try Fixture(data: payload)
        defer { fixture.cleanup() }

        let data = try DesktopObservationResult.readArtifact(
            at: fixture.url.path,
            label: "raw screenshot",
            maxBytes: 16)
        #expect(data == payload)
    }

    @Test
    func `readArtifactIfPresent skips a missing path and rejects an oversized present file`() throws {
        #expect(try DesktopObservationResult.readArtifactIfPresent(
            at: nil,
            label: "raw screenshot",
            maxBytes: 16) == nil)

        let fixture = try Fixture(byteCount: 32)
        defer { fixture.cleanup() }
        #expect(throws: DesktopObservationContentVerificationError.artifactTooLarge("annotated screenshot")) {
            _ = try DesktopObservationResult.readArtifactIfPresent(
                at: fixture.url.path,
                label: "annotated screenshot",
                maxBytes: 16)
        }
    }

    @Test
    func `verified raw screenshot rejects a sparse file over the capture limit`() throws {
        let fixture = try Fixture(sparseByteCount: DesktopObservationResult.maximumArtifactBytes + 1)
        defer { fixture.cleanup() }

        let pixels = Data("pixels".utf8)
        let result = DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: pixels,
                savedPath: fixture.url.path,
                metadata: CaptureMetadata(size: .init(width: 1, height: 1), mode: .screen)),
            elements: nil,
            files: DesktopObservationFiles(rawScreenshotPath: fixture.url.path))

        #expect(throws: DesktopObservationContentVerificationError.artifactTooLarge("raw screenshot")) {
            _ = try result.verifiedRawScreenshotData()
        }
    }

    @Test
    func `attesting capture content rejects an oversized annotated artifact`() throws {
        let fixture = try Fixture(sparseByteCount: DesktopObservationResult.maximumArtifactBytes + 1)
        defer { fixture.cleanup() }

        let pixels = Data("pixels".utf8)
        let result = DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: pixels,
                metadata: CaptureMetadata(size: .init(width: 1, height: 1), mode: .screen)),
            elements: nil,
            files: DesktopObservationFiles(annotatedScreenshotPath: fixture.url.path))

        #expect(throws: DesktopObservationContentVerificationError.artifactTooLarge("annotated screenshot")) {
            _ = try result.attestingCaptureContent()
        }
    }

    @Test
    func `readArtifact still reports an unreadable missing file`() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-missing-observation-\(UUID().uuidString).png")
        #expect(throws: DesktopObservationContentVerificationError.unreadableArtifact("raw screenshot")) {
            _ = try DesktopObservationResult.readArtifact(at: missing.path, label: "raw screenshot")
        }
    }
}

private struct Fixture {
    let root: URL
    let url: URL

    init(byteCount: Int) throws {
        try self.init(data: Data(repeating: 0x41, count: byteCount))
    }

    init(data: Data) throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-observation-artifact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: false)
        self.url = self.root.appendingPathComponent("artifact.png")
        try data.write(to: self.url, options: .atomic)
    }

    init(sparseByteCount: Int) throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-observation-sparse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: false)
        self.url = self.root.appendingPathComponent("sparse.png")
        FileManager.default.createFile(atPath: self.url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: self.url)
        try handle.truncate(atOffset: UInt64(sparseByteCount))
        try handle.close()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.root)
    }
}

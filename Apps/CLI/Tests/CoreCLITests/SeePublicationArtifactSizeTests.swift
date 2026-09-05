import AppKit
import Foundation
import PeekabooAutomation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
struct SeePublicationArtifactSizeTests {
    @Test
    @MainActor
    func `pixel publication rejects an oversized replacement before loading`() throws {
        let fixture = try Fixture(byteCount: 64)
        defer { fixture.cleanup() }
        let verifiedData = Data("verified-pixels".utf8)
        #expect(verifiedData.count < 64)

        let capture = Self.capture(path: fixture.url.path, imageData: verifiedData)

        let error = #expect(throws: CaptureError.self) {
            try SeeCommand.requireCurrentCaptureArtifacts([capture])
        }
        guard case let .captureFailure(message) = error else {
            Issue.record("Expected size-mismatch refusal before load")
            return
        }
        #expect(message.contains("exceeds the capture size limit"))
    }

    @Test
    @MainActor
    func `pixel publication rejects a sparse file larger than verified bytes`() throws {
        let verifiedData = Data("verified-pixels".utf8)
        let fixture = try Fixture(sparseByteCount: ClipboardPayloadBuilder.defaultSizeLimit + 1)
        defer { fixture.cleanup() }

        let capture = Self.capture(path: fixture.url.path, imageData: verifiedData)

        let error = #expect(throws: CaptureError.self) {
            try SeeCommand.requireCurrentCaptureArtifacts([capture])
        }
        guard case let .captureFailure(message) = error else {
            Issue.record("Expected sparse-file size refusal before load")
            return
        }
        #expect(message.contains("exceeds the capture size limit"))
    }

    @Test
    @MainActor
    func `observation publication rejects an oversized screenshot before loading`() throws {
        let fixture = try Fixture(byteCount: 32)
        defer { fixture.cleanup() }
        let verifiedData = Data("see-shot".utf8)
        #expect(verifiedData.count < 32)

        let error = #expect(throws: CaptureError.self) {
            try SeeCommand.requireCurrentArtifact(
                path: fixture.url.path,
                verifiedData: verifiedData,
                label: "screenshot"
            )
        }
        guard case let .captureFailure(message) = error else {
            Issue.record("Expected observation size-mismatch refusal")
            return
        }
        #expect(message.contains("exceeds the capture size limit"))
    }

    @Test
    func `bounded annotated reload refuses a file over the capture cap`() throws {
        let fixture = try Fixture(sparseByteCount: ClipboardPayloadBuilder.defaultSizeLimit + 1)
        defer { fixture.cleanup() }

        let error = #expect(throws: CaptureError.self) {
            _ = try SeePublicationArtifact.readBounded(
                at: fixture.url.path,
                maxBytes: ClipboardPayloadBuilder.defaultSizeLimit,
                label: "annotated screenshot"
            )
        }
        guard case let .captureFailure(message) = error else {
            Issue.record("Expected annotated size-limit refusal")
            return
        }
        #expect(message.contains("exceeds the capture size limit"))
    }

    @Test
    func `bounded annotated reload loads a file at the inclusive max`() throws {
        let payload = Data(repeating: 0x41, count: 16)
        let fixture = try Fixture(data: payload)
        defer { fixture.cleanup() }

        let data = try SeePublicationArtifact.readBounded(
            at: fixture.url.path,
            maxBytes: 16,
            label: "annotated screenshot"
        )
        #expect(data == payload)
    }

    @Test
    func `valid annotation larger than both raw capture and ten MiB remains readable`() throws {
        func makeBitmap() throws -> NSBitmapImageRep {
            try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2048,
                pixelsHigh: 2048,
                bitsPerSample: 8,
                samplesPerPixel: 3,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 24
            ))
        }
        let source = try makeBitmap()
        let sourceBytes = try #require(source.bitmapData)
        sourceBytes.initialize(repeating: 0, count: source.bytesPerRow * source.pixelsHigh)
        let raw = try #require(source.representation(using: .png, properties: [:]))
        let bitmap = try makeBitmap()
        let bytes = try #require(bitmap.bitmapData)
        let count = bitmap.bytesPerRow * bitmap.pixelsHigh
        var random: UInt32 = 0x1234_5678
        for index in 0..<count {
            random ^= random << 13
            random ^= random >> 17
            random ^= random << 5
            bytes[index] = UInt8(truncatingIfNeeded: random)
        }
        let annotated = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(annotated.count > max(ClipboardPayloadBuilder.defaultSizeLimit, raw.count))
        let fixture = try Fixture(data: annotated)
        defer { fixture.cleanup() }
        #expect(try SeePublicationArtifact.readBounded(
            at: fixture.url.path, label: "annotated screenshot"
        ) == annotated)
    }

    @Test
    @MainActor
    func `pixel publication still reports digest mismatch for same-size replacement`() throws {
        let verifiedData = Data("verified-pixels".utf8)
        let replacement = Data("replaced-pixels".utf8)
        #expect(verifiedData.count == replacement.count)
        let fixture = try Fixture(data: replacement)
        defer { fixture.cleanup() }

        #expect(throws: DesktopObservationContentVerificationError.digestMismatch) {
            try SeeCommand.requireCurrentCaptureArtifacts([
                Self.capture(path: fixture.url.path, imageData: verifiedData),
            ])
        }
    }
}

extension SeePublicationArtifactSizeTests {
    @MainActor
    private static func capture(path: String, imageData: Data) -> ImageCapturedFile {
        ImageCapturedFile(
            file: SavedFile(path: path, mime_type: "image/png"),
            imageData: imageData,
            observation: ImageObservationDiagnostics(
                timings: ObservationTimings(),
                diagnostics: DesktopObservationDiagnostics()
            ),
            snapshotID: nil,
            receipt: .none
        )
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
            .appendingPathComponent("peekaboo-see-publication-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: false)
        self.url = self.root.appendingPathComponent("artifact.png")
        try data.write(to: self.url, options: .atomic)
    }

    init(sparseByteCount: Int) throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-see-publication-sparse-\(UUID().uuidString)", isDirectory: true)
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

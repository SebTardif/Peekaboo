import AppKit
import PeekabooFoundation
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooAutomationKit

@available(macOS 14.0, *)
@MainActor
final class ClipboardWriteRequestTests: XCTestCase {
    func testTextRepresentationsIncludePlainTextAndString() {
        let request = try? ClipboardPayloadBuilder.textRequest(text: "hello")
        let types = request?.representations.map(\.utiIdentifier) ?? []

        XCTAssertTrue(types.contains(UTType.plainText.identifier))
        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType.string.rawValue))
        XCTAssertEqual(Set(types).count, types.count)
    }

    func testSetReturnsPreviewForUTF8PlainTextRepresentation() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let request = ClipboardWriteRequest(representations: [
            ClipboardRepresentation(utiIdentifier: UTType.utf8PlainText.identifier, data: Data("hello".utf8)),
        ])

        let result = try clipboard.set(request)

        XCTAssertEqual(result.textPreview, "hello")
    }

    func testFileRequestRejectsOversizedFileBeforeLoadingBytes() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-clipboard-size-\(UUID().uuidString).bin")
        let payload = Data(repeating: 0x61, count: 16)
        try payload.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertThrowsError(
            try ClipboardPayloadBuilder.dataRequest(fileURL: fileURL, sizeLimit: 4))
        { error in
            guard case let ClipboardServiceError.sizeExceeded(current, limit) = error else {
                return XCTFail("Expected sizeExceeded, got \(error)")
            }
            XCTAssertEqual(current, payload.count)
            XCTAssertEqual(limit, 4)
        }
    }

    func testFileRequestCountsAlsoTextAgainstSizeLimit() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-clipboard-companion-\(UUID().uuidString).bin")
        try Data(repeating: 0x62, count: 3).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertThrowsError(
            try ClipboardPayloadBuilder.dataRequest(
                fileURL: fileURL,
                alsoText: "two",
                sizeLimit: 5))
        { error in
            guard case let ClipboardServiceError.sizeExceeded(current, limit) = error else {
                return XCTFail("Expected sizeExceeded, got \(error)")
            }
            XCTAssertEqual(current, 6)
            XCTAssertEqual(limit, 5)
        }
    }

    func testFileRequestAllowsOversizedFileWhenAllowLarge() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-clipboard-allow-\(UUID().uuidString).bin")
        let payload = Data(repeating: 0x63, count: 16)
        try payload.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let request = try ClipboardPayloadBuilder.dataRequest(
            fileURL: fileURL,
            allowLarge: true,
            sizeLimit: 4)
        XCTAssertEqual(request.representations.first?.data, payload)
        XCTAssertTrue(request.allowLarge)
    }

    func testFileRequestCannotBypassSizeGuardByReplacingSymlinkAfterOpen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-clipboard-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = directory.appendingPathComponent("original.bin")
        let replacement = directory.appendingPathComponent("replacement.bin")
        let link = directory.appendingPathComponent("payload.bin")
        let originalData = Data("original".utf8)
        try originalData.write(to: original)
        try Data(repeating: 0x66, count: 64).write(to: replacement)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)

        let request = try ClipboardPayloadBuilder.dataRequest(
            fileURL: link,
            sizeLimit: originalData.count,
            hooks: ClipboardFileReadHooks(
                afterOpen: {
                    try FileManager.default.removeItem(at: link)
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacement)
                },
                afterStat: {}))

        XCTAssertEqual(request.representations.first?.data, originalData)
    }

    func testFileRequestBoundsGrowthAfterDescriptorInspection() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-clipboard-growth-\(UUID().uuidString).bin")
        try Data(repeating: 0x64, count: 4).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertThrowsError(
            try ClipboardPayloadBuilder.dataRequest(
                fileURL: fileURL,
                sizeLimit: 4,
                hooks: ClipboardFileReadHooks(
                    afterOpen: {},
                    afterStat: {
                        let handle = try FileHandle(forWritingTo: fileURL)
                        defer { try? handle.close() }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data(repeating: 0x65, count: 16))
                    }))) { error in
            guard case let ClipboardServiceError.sizeExceeded(current, limit) = error else {
                return XCTFail("Expected sizeExceeded, got \(error)")
            }
            XCTAssertEqual(current, 20)
            XCTAssertEqual(limit, 4)
        }
    }

    func testSetCountsAlsoTextAgainstLargePayloadLimit() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard = ClipboardService(pasteboard: pasteboard, sizeLimit: 4)
        let request = ClipboardWriteRequest(
            representations: [
                ClipboardRepresentation(utiIdentifier: "com.example.payload", data: Data([0x01])),
            ],
            alsoText: "oversized")

        XCTAssertThrowsError(try clipboard.set(request)) { error in
            guard case let ClipboardServiceError.sizeExceeded(current, limit) = error else {
                return XCTFail("Expected sizeExceeded, got \(error)")
            }
            XCTAssertGreaterThan(current, limit)
        }
    }

    func testResultAwareMutationsConfirmVerifiedPasteboardState() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let delivery = ClipboardMutationResultSemantics.delivery

        let set = try clipboard.setResult(ClipboardPayloadBuilder.textRequest(text: "stored"))
        XCTAssertEqual(set.outcome, .confirmedChange(delivery: delivery))

        try clipboard.save(slot: "fixture")
        _ = try clipboard.set(ClipboardPayloadBuilder.textRequest(text: "temporary"))
        let restore = try clipboard.restoreResult(slot: "fixture")
        XCTAssertEqual(restore.outcome, .confirmedChange(delivery: delivery))
        XCTAssertEqual(String(data: restore.payload.data, encoding: .utf8), "stored")

        let clear = try clipboard.clearResult()
        XCTAssertEqual(clear.outcome, .confirmedChange(delivery: delivery))
        XCTAssertNil(try clipboard.get(prefer: nil))
    }

    func testResultAwareSetValidationRefusesWithoutPasteboardDispatch() {
        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let initialChangeCount = pasteboard.changeCount

        XCTAssertThrowsError(try clipboard.setResult(ClipboardWriteRequest(representations: []))) { error in
            guard let failure = error as? DesktopActionFailure else {
                return XCTFail("Expected DesktopActionFailure, got \(error)")
            }
            XCTAssertEqual(failure.outcome, .refused(reason: .invalidRequest))
        }
        XCTAssertEqual(pasteboard.changeCount, initialChangeCount)
    }
}

import Foundation
import PeekabooCore
import PeekabooFoundation

enum SeePublicationArtifact {
    static func readMatchingVerifiedBytes(
        at path: String,
        expectedByteCount: Int,
        label: String
    ) throws -> Data {
        let size = try self.regularFileSize(at: path, label: label)
        guard size == expectedByteCount else {
            throw CaptureError.captureFailure(
                "Verified \(label) size \(size) does not match verified content " +
                    "(\(expectedByteCount) bytes) before publication"
            )
        }
        return try self.contents(at: path, label: label)
    }

    static func readBounded(
        at path: String,
        maxBytes: Int = ClipboardPayloadBuilder.defaultSizeLimit,
        label: String
    ) throws -> Data {
        let size = try self.regularFileSize(at: path, label: label)
        guard size <= maxBytes else {
            throw CaptureError.captureFailure(
                "Verified \(label) exceeds the capture size limit " +
                    "(\(size) bytes, limit \(maxBytes)) before publication"
            )
        }
        return try self.contents(at: path, label: label)
    }

    private static func regularFileSize(at path: String, label: String) throws -> Int {
        let url = URL(fileURLWithPath: path)
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                throw CaptureError.captureFailure("Verified \(label) could not be read before publication")
            }
            return size
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.captureFailure("Verified \(label) could not be read before publication")
        }
    }

    private static func contents(at path: String, label: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw CaptureError.captureFailure("Verified \(label) could not be read before publication")
        }
    }
}

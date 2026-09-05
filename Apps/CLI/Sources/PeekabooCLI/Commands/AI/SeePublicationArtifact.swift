import Foundation
import PeekabooCore
import PeekabooFoundation

enum SeePublicationArtifact {
    static func readMatchingVerifiedBytes(
        at path: String,
        expectedByteCount: Int,
        label: String
    ) throws -> Data {
        let file = try self.open(at: path, maxBytes: expectedByteCount, label: label)
        guard file.byteCount == expectedByteCount else {
            throw CaptureError.captureFailure(
                "Verified \(label) size \(file.byteCount) does not match verified content " +
                    "(\(expectedByteCount) bytes) before publication"
            )
        }
        return try self.contents(of: file, label: label)
    }

    static func readBounded(
        at path: String,
        maxBytes: Int = CaptureArtifactIntegrityValidator.maximumPNGBytes,
        label: String
    ) throws -> Data {
        try self.contents(of: self.open(at: path, maxBytes: maxBytes, label: label), label: label)
    }

    private static func open(at path: String, maxBytes: Int, label: String) throws -> BoundedArtifactFile {
        do {
            return try BoundedArtifactFile(path: path, maximumBytes: maxBytes)
        } catch BoundedArtifactFileError.tooLarge {
            throw CaptureError.captureFailure("Verified \(label) exceeds the capture size limit before publication")
        } catch {
            throw CaptureError.captureFailure("Verified \(label) could not be read before publication")
        }
    }

    private static func contents(of file: BoundedArtifactFile, label: String) throws -> Data {
        do {
            return try file.read()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CaptureError.captureFailure("Verified \(label) could not be read before publication")
        }
    }
}

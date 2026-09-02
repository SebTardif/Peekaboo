import Darwin
import Foundation
import PeekabooFoundation

/// Owns the descriptor from inspection through the bounded read, even if the path is replaced.
final class AnalyzeImageFile {
    static let sizeLimit = 10 * 1024 * 1024

    private let descriptor: Int32
    private let initialSize: Int

    init(url: URL) throws {
        // Follow ordinary symlinks, but never block waiting for a FIFO writer.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw Self.fileError("open image file")
        }
        var ownsDescriptor = false
        defer {
            if !ownsDescriptor {
                Darwin.close(descriptor)
            }
        }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw Self.fileError("inspect opened image file")
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw PeekabooError.invalidInput("Image path is not a regular file.")
        }
        guard info.st_size >= 0, let size = Int(exactly: info.st_size) else {
            throw PeekabooError.fileIOError("Opened image file has an invalid size.")
        }
        guard size <= Self.sizeLimit else {
            throw Self.sizeError(observedBytes: size)
        }
        self.descriptor = descriptor
        self.initialSize = size
        ownsDescriptor = true
    }

    deinit {
        Darwin.close(self.descriptor)
    }

    func read() throws -> Data {
        var data = Data()
        data.reserveCapacity(self.initialSize)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // Metadata is only an early refusal: growth must not bypass the actual read bound.
            let readCount = min(buffer.count, Self.sizeLimit - data.count + 1)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(self.descriptor, bytes.baseAddress, readCount)
            }
            if count == 0 {
                return data
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw Self.fileError("read opened image file")
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.sizeLimit else {
                throw Self.sizeError(observedBytes: data.count)
            }
        }
    }

    private static func sizeError(observedBytes: Int) -> PeekabooError {
        .invalidInput(
            "Image file is too large: \(observedBytes) bytes (limit 10 MiB / \(self.sizeLimit) bytes). " +
                "Resize or compress the image before retrying.")
    }

    private static func fileError(_ operation: String) -> PeekabooError {
        .fileIOError("Unable to \(operation): \(String(cString: strerror(errno))).")
    }
}

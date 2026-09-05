import Darwin
import Foundation

public enum BoundedArtifactFileError: Error, Equatable {
    case invalidLimit
    case unreadable
    case tooLarge
    case changedDuringRead
}

/// Retains one regular-file descriptor and caps every read, including growth after opening.
public final class BoundedArtifactFile {
    public let byteCount: Int
    private let descriptor: Int32
    private let path: String
    private let maximumBytes: Int
    private let initialInfo: stat

    public init(path: String, maximumBytes: Int) throws {
        guard maximumBytes >= 0 else { throw BoundedArtifactFileError.invalidLimit }
        // Preserve ordinary symlink paths without waiting for a special-file writer.
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw BoundedArtifactFileError.unreadable }
        var retained = false
        defer {
            if !retained {
                Darwin.close(descriptor)
            }
        }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              let byteCount = Int(exactly: info.st_size)
        else { throw BoundedArtifactFileError.unreadable }
        guard byteCount <= maximumBytes else { throw BoundedArtifactFileError.tooLarge }
        self.descriptor = descriptor
        self.path = path
        self.maximumBytes = maximumBytes
        self.initialInfo = info
        self.byteCount = byteCount
        retained = true
    }

    deinit { Darwin.close(self.descriptor) }

    /// Read once; refuse replacement or mutation rather than publishing bytes under a stale path.
    public func read() throws -> Data {
        var data = Data()
        data.reserveCapacity(self.byteCount)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let remaining = self.maximumBytes - data.count
            let requested = remaining < buffer.count ? remaining + 1 : buffer.count
            let count = Darwin.read(self.descriptor, &buffer, requested)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw BoundedArtifactFileError.unreadable
            }
            guard count <= remaining else { throw BoundedArtifactFileError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        var descriptorInfo = stat()
        var pathInfo = stat()
        guard Darwin.fstat(self.descriptor, &descriptorInfo) == 0,
              Darwin.fstatat(AT_FDCWD, self.path, &pathInfo, 0) == 0,
              Self.unchanged(self.initialInfo, descriptorInfo),
              Self.unchanged(self.initialInfo, pathInfo),
              data.count == self.byteCount
        else { throw BoundedArtifactFileError.changedDuringRead }
        return data
    }

    private static func unchanged(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino &&
            first.st_mode == second.st_mode && first.st_size == second.st_size &&
            first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec &&
            first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec &&
            first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec &&
            first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}

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

    /// Read once, requiring unchanged path identity and descriptor metadata.
    public func read() throws -> Data {
        try self.read(requireStablePath: true)
    }

    /// Read a frame from an atomic-only publisher without requiring its path to remain current.
    /// Size and mtime must still match; ctime may change only after the opened file is unlinked.
    /// This is not snapshot isolation against a writer that mutates a published inode,
    /// restores its timestamps, and then unlinks it. Such writers must use `read()`.
    public func readImmutableFrame() throws -> Data {
        try self.read(requireStablePath: false)
    }

    private func read(requireStablePath: Bool) throws -> Data {
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
        guard Darwin.fstat(self.descriptor, &descriptorInfo) == 0,
              data.count == self.byteCount
        else { throw BoundedArtifactFileError.changedDuringRead }
        if requireStablePath {
            var pathInfo = stat()
            guard Self.unchanged(self.initialInfo, descriptorInfo),
                  Darwin.fstatat(AT_FDCWD, self.path, &pathInfo, 0) == 0,
                  Self.unchanged(self.initialInfo, pathInfo)
            else { throw BoundedArtifactFileError.changedDuringRead }
        } else if !Self.unchanged(self.initialInfo, descriptorInfo) {
            guard Self.contentUnchanged(self.initialInfo, descriptorInfo),
                  self.wasUnlinked(descriptorInfo)
            else { throw BoundedArtifactFileError.changedDuringRead }
        }
        return data
    }

    private func wasUnlinked(_ info: stat) -> Bool {
        guard info.st_nlink < self.initialInfo.st_nlink else { return false }
        var pathInfo = stat()
        if Darwin.fstatat(AT_FDCWD, self.path, &pathInfo, 0) == 0 {
            return pathInfo.st_dev != info.st_dev || pathInfo.st_ino != info.st_ino
        }
        return errno == ENOENT
    }

    private static func unchanged(_ first: stat, _ second: stat) -> Bool {
        self.contentUnchanged(first, second) &&
            first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec &&
            first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    private static func contentUnchanged(_ first: stat, _ second: stat) -> Bool {
        // Atomic replacement can change the retained inode's ctime when its link is removed.
        first.st_dev == second.st_dev && first.st_ino == second.st_ino &&
            first.st_mode == second.st_mode && first.st_size == second.st_size &&
            first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec &&
            first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
    }
}

import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

public enum ClipboardPayloadBuilder {
    public static let defaultSizeLimit = 10 * 1024 * 1024

    public static func textRequest(
        text: String,
        alsoText: String? = nil,
        allowLarge: Bool = false) throws -> ClipboardWriteRequest
    {
        guard let data = text.data(using: .utf8) else {
            throw ClipboardServiceError.writeFailed("Unable to encode text as UTF-8.")
        }
        return ClipboardWriteRequest(
            representations: ClipboardWriteRequest.textRepresentations(from: data),
            alsoText: alsoText,
            allowLarge: allowLarge)
    }

    public static func dataRequest(
        data: Data,
        uti: UTType,
        alsoText: String? = nil,
        allowLarge: Bool = false) -> ClipboardWriteRequest
    {
        ClipboardWriteRequest(
            representations: [ClipboardRepresentation(utiIdentifier: uti.identifier, data: data)],
            alsoText: alsoText,
            allowLarge: allowLarge)
    }

    public static func dataRequest(
        data: Data,
        utiIdentifier: String,
        alsoText: String? = nil,
        allowLarge: Bool = false) -> ClipboardWriteRequest
    {
        ClipboardWriteRequest(
            representations: [ClipboardRepresentation(utiIdentifier: utiIdentifier, data: data)],
            alsoText: alsoText,
            allowLarge: allowLarge)
    }

    public static func dataRequest(
        fileURL: URL,
        uti: UTType? = nil,
        alsoText: String? = nil,
        allowLarge: Bool = false,
        sizeLimit: Int = ClipboardPayloadBuilder.defaultSizeLimit) throws -> ClipboardWriteRequest
    {
        try self.dataRequest(
            fileURL: fileURL,
            uti: uti,
            alsoText: alsoText,
            allowLarge: allowLarge,
            sizeLimit: sizeLimit,
            hooks: .none)
    }

    static func dataRequest(
        fileURL: URL,
        uti: UTType? = nil,
        alsoText: String? = nil,
        allowLarge: Bool = false,
        sizeLimit: Int = ClipboardPayloadBuilder.defaultSizeLimit,
        hooks: ClipboardFileReadHooks) throws -> ClipboardWriteRequest
    {
        let alsoTextSize = alsoText?.utf8.count ?? 0
        let maximumFileBytes: Int?
        if allowLarge {
            maximumFileBytes = nil
        } else {
            guard sizeLimit >= 0, alsoTextSize <= sizeLimit else {
                throw ClipboardServiceError.sizeExceeded(current: alsoTextSize, limit: sizeLimit)
            }
            maximumFileBytes = sizeLimit - alsoTextSize
        }

        let file: (data: Data, size: Int)
        do {
            file = try self.readFile(
                at: fileURL,
                maximumBytes: maximumFileBytes,
                hooks: hooks)
        } catch let ClipboardServiceError.sizeExceeded(current, _) {
            let (totalSize, overflow) = current.addingReportingOverflow(alsoTextSize)
            throw ClipboardServiceError.sizeExceeded(
                current: overflow ? Int.max : totalSize,
                limit: sizeLimit)
        }
        let (totalSize, overflow) = file.size.addingReportingOverflow(alsoTextSize)
        guard !overflow else {
            throw ClipboardServiceError.sizeExceeded(current: Int.max, limit: sizeLimit)
        }
        if !allowLarge, totalSize > sizeLimit {
            throw ClipboardServiceError.sizeExceeded(current: totalSize, limit: sizeLimit)
        }

        let resolvedType = uti ?? UTType(filenameExtension: fileURL.pathExtension) ?? .data
        return self.dataRequest(
            data: file.data,
            uti: resolvedType,
            alsoText: alsoText,
            allowLarge: allowLarge)
    }

    public static func base64Request(
        base64: String,
        utiIdentifier: String,
        alsoText: String? = nil,
        allowLarge: Bool = false) throws -> ClipboardWriteRequest
    {
        guard let data = Data(base64Encoded: base64) else {
            throw ClipboardServiceError.writeFailed("Invalid base64 payload.")
        }
        return self.dataRequest(
            data: data,
            utiIdentifier: utiIdentifier,
            alsoText: alsoText,
            allowLarge: allowLarge)
    }

    private static func readFile(
        at fileURL: URL,
        maximumBytes: Int?,
        hooks: ClipboardFileReadHooks) throws -> (data: Data, size: Int)
    {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw ClipboardServiceError.writeFailed(
                "Unable to open file: \(self.posixErrorMessage()).")
        }
        defer { Darwin.close(descriptor) }
        try hooks.afterOpen()

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0 else {
            throw ClipboardServiceError.writeFailed(
                "Unable to inspect opened file: \(self.posixErrorMessage()).")
        }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ClipboardServiceError.writeFailed("Path is not a regular file.")
        }
        guard before.st_size >= 0, let initialSize = Int(exactly: before.st_size) else {
            throw ClipboardServiceError.writeFailed("Opened file has an invalid size.")
        }
        if let maximumBytes, initialSize > maximumBytes {
            throw ClipboardServiceError.sizeExceeded(current: initialSize, limit: maximumBytes)
        }
        try hooks.afterStat()

        var data = Data()
        data.reserveCapacity(initialSize)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var exceededBound = false
        while true {
            let readCount: Int
            if let maximumBytes {
                guard data.count <= maximumBytes else {
                    exceededBound = true
                    break
                }
                let remaining = maximumBytes - data.count
                readCount = min(buffer.count, remaining == Int.max ? remaining : remaining + 1)
            } else {
                readCount = buffer.count
            }

            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, readCount)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw ClipboardServiceError.writeFailed(
                    "Unable to read opened file: \(self.posixErrorMessage()).")
            }
        }

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else {
            throw ClipboardServiceError.writeFailed(
                "Unable to inspect opened file after reading: \(self.posixErrorMessage()).")
        }
        guard after.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_size >= 0,
              let finalSize = Int(exactly: after.st_size)
        else {
            throw ClipboardServiceError.writeFailed("Opened file changed identity while being read.")
        }
        if let maximumBytes, exceededBound || finalSize > maximumBytes {
            let observedSize = max(finalSize, maximumBytes == Int.max ? Int.max : maximumBytes + 1)
            throw ClipboardServiceError.sizeExceeded(current: observedSize, limit: maximumBytes)
        }
        guard finalSize == data.count else {
            throw ClipboardServiceError.writeFailed("Opened file changed size while being read.")
        }
        return (data, finalSize)
    }

    private static func posixErrorMessage(_ code: Int32 = errno) -> String {
        String(cString: strerror(code))
    }
}

struct ClipboardFileReadHooks: Sendable {
    let afterOpen: @Sendable () throws -> Void
    let afterStat: @Sendable () throws -> Void

    static let none = ClipboardFileReadHooks(afterOpen: {}, afterStat: {})
}

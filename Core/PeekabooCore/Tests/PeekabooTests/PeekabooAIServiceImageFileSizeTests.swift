import Darwin
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomation

@Suite(.serialized)
@MainActor
struct PeekabooAIServiceImageFileSizeTests {
    nonisolated static let limit = 10 * 1024 * 1024

    @Test(arguments: [AnalyzeImageEntryPoint.file, .detailedFile])
    func `rejects overflow before provider dispatch`(entryPoint: AnalyzeImageEntryPoint) async throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        let data = Data(repeating: 0, count: Self.limit + 1)
        let url = try context.file("oversized.png", data: data)
        do {
            _ = try await entryPoint.call(context, url: url, data: data)
            Issue.record("Expected oversized image refusal")
        } catch let PeekabooError.invalidInput(message) {
            #expect(message.contains("10485760"))
            #expect(message.localizedCaseInsensitiveContains("resize"))
            #expect(message.localizedCaseInsensitiveContains("compress"))
        }
        #expect(context.provider.dispatches == 0)
        #expect(context.provider.requestCount == 0)
    }

    @Test(arguments: [Self.limit - 1, Self.limit], [AnalyzeImageEntryPoint.file, .detailedFile])
    func `inclusive boundary`(bytes: Int, entryPoint: AnalyzeImageEntryPoint) async throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        var data = try AnalyzeImageTestContext.fixture("png")
        data.append(Data(repeating: 0, count: bytes - data.count))
        let url = try context.file("boundary.png", data: data)
        _ = try await entryPoint.call(context, url: url, data: data)
        #expect(context.provider.dispatches == 1)
        try context.provider.expectImage(data, mimeType: "image/png")
    }
}

extension PeekabooAIServiceImageFileSizeTests {
    @Test(arguments: RejectedAnalyzeImage.allCases, [AnalyzeImageEntryPoint.file, .detailedFile])
    func `rejects invalid files promptly`(
        input: RejectedAnalyzeImage,
        entryPoint: AnalyzeImageEntryPoint) async throws
    {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        let url = try input.makeURL(in: context)
        let rescue = input.unblockIfNeeded(url)
        defer { rescue.cancel() }
        let start = ContinuousClock.now
        do {
            _ = try await entryPoint.call(context, url: url, data: Data())
            Issue.record("Expected invalid file refusal")
        } catch {
            if input == .fifo || input == .directory {
                #expect(error.localizedDescription.contains("not a regular file"))
            }
        }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(context.provider.dispatches == 0)
        #expect(context.provider.requestCount == 0)
    }

    @Test(arguments: ["symlink", "hardlink", "group-writable"], [AnalyzeImageEntryPoint.file, .detailedFile])
    func `ordinary file compatibility`(kind: String, entryPoint: AnalyzeImageEntryPoint) async throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        let data = try AnalyzeImageTestContext.fixture("jpg")
        let original = try context.file("original.jpg", data: data)
        let url = context.directory.appendingPathComponent("compatible.jpg")
        switch kind {
        case "symlink":
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original)
        case "hardlink":
            try FileManager.default.linkItem(at: original, to: url)
        default:
            try data.write(to: url)
            #expect(Darwin.chmod(url.path, 0o666) == 0)
        }
        _ = try await entryPoint.call(context, url: url, data: data)
        try context.provider.expectImage(data, mimeType: "image/jpeg")
    }

    @Test(arguments: [false, true])
    func `replacement keeps opened descriptor`(symlink: Bool) throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        let data = try AnalyzeImageTestContext.fixture("png")
        let original = try context.file("original.png", data: data)
        let path = context.directory.appendingPathComponent("selected.png")
        if symlink {
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: original)
        } else {
            try data.write(to: path)
        }
        let opened = try AnalyzeImageFile(url: path)
        try FileManager.default.removeItem(at: path)
        let replacement = try context.file("replacement.png", data: Data(repeating: 0, count: Self.limit + 1))
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: replacement)
        #expect(try opened.read() == data)
    }

    @Test
    func `growth after inspection stops at overflow byte`() throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        let url = try context.file("growing.png", data: Data([0]))
        let opened = try AnalyzeImageFile(url: url)
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: UInt64(Self.limit * 10))
        try writer.close()
        let error = #expect(throws: PeekabooError.self) { try opened.read() }
        guard case let .invalidInput(message) = error else {
            Issue.record("Expected file-growth refusal")
            return
        }
        #expect(message.contains("10485761 bytes"))
    }
}

extension PeekabooAIServiceImageFileSizeTests {
    @Test(arguments: [1, 8])
    func `size changes within limit remain readable`(newSize: Int) throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        let url = try context.file("changing.png", data: Data(repeating: 0, count: 4))
        let opened = try AnalyzeImageFile(url: url)
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: UInt64(newSize))
        try writer.close()
        #expect(try opened.read() == Data(repeating: 0, count: newSize))
    }

    @Test(arguments: [AnalyzeImageEntryPoint.data, .detailedData])
    func `data only analysis does not inherit file limit`(entryPoint: AnalyzeImageEntryPoint) async throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        var data = try AnalyzeImageTestContext.fixture("png")
        data.append(Data(repeating: 0, count: Self.limit + 1 - data.count))
        _ = try await entryPoint.call(context, url: context.directory, data: data)
        #expect(context.provider.dispatches == 1)
        try context.provider.expectImage(data, mimeType: "image/png")
    }
}

import Foundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
@MainActor
struct MCPAnalyzeImageFileTests {
    @Test
    func `oversized file refused before provider dispatch`() async throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        let url = try context.file("oversized.png", data: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(PeekabooAIServiceImageFileSizeTests.limit + 1))
        try handle.close()
        let response = try await AnalyzeTool().execute(arguments: ToolArguments(raw: [
            "image_path": url.path,
            "question": "Describe this pixel",
        ]))
        #expect(response.isError)
        let text = response.content.compactMap { content -> String? in
            if case let .text(text, _, _) = content {
                return text
            }
            return nil
        }.joined()
        #expect(text.contains("10485760"))
        #expect(text.localizedCaseInsensitiveContains("resize"))
        #expect(text.localizedCaseInsensitiveContains("compress"))
        #expect(context.provider.dispatches == 0)
        #expect(context.provider.requestCount == 0)
    }

    @Test(arguments: ["png", "jpg", "webp"])
    func `real image request`(ext: String) async throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        let data = try AnalyzeImageTestContext.fixture(ext)
        let url = try context.file("pixel.\(ext.uppercased())", data: data)
        let response = try await AnalyzeTool().execute(arguments: ToolArguments(raw: [
            "image_path": url.path,
            "question": "Describe this pixel",
        ]))
        #expect(!response.isError)
        #expect(context.provider.dispatches == 1)
        try context.provider.expectImage(data, mimeType: ext == "jpg" ? "image/jpeg" : "image/\(ext)")
    }
}

extension MCPAnalyzeImageFileTests {
    @Test(arguments: RejectedAnalyzeImage.allCases)
    func `invalid files refused before provider dispatch`(input: RejectedAnalyzeImage) async throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        let url = try input.makeURL(in: context)
        let rescue = input.unblockIfNeeded(url)
        defer { rescue.cancel() }
        let start = ContinuousClock.now
        let response = try await AnalyzeTool().execute(arguments: ToolArguments(raw: [
            "image_path": url.path,
            "question": "Describe this pixel",
        ]))
        #expect(response.isError)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(context.provider.dispatches == 0)
        #expect(context.provider.requestCount == 0)
    }

    @Test
    func `inclusive file limit still dispatches`() async throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        var data = try AnalyzeImageTestContext.fixture("png")
        data.append(Data(repeating: 0, count: PeekabooAIServiceImageFileSizeTests.limit - data.count))
        let url = try context.file("boundary.png", data: data)
        let response = try await AnalyzeTool().execute(arguments: ToolArguments(raw: [
            "image_path": url.path,
            "question": "Describe this pixel",
        ]))
        #expect(!response.isError)
        #expect(context.provider.dispatches == 1)
        try context.provider.expectImage(data, mimeType: "image/png")
    }
}

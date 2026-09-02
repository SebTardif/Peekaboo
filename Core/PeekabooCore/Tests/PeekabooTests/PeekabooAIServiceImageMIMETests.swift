import Foundation
import Testing

@Suite(.serialized)
@MainActor
struct PeekabooAIServiceImageMIMETests {
    @Test(arguments: ["png", "jpg", "webp"], AnalyzeImageEntryPoint.allCases)
    func `real image requests`(ext: String, entryPoint: AnalyzeImageEntryPoint) async throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        let data = try AnalyzeImageTestContext.fixture(ext)
        // Unknown extensions exercise byte detection without a filename hint.
        let url = try context.file("pixel.unknown", data: data)
        let text = try await entryPoint.call(context, url: url, data: data)
        #expect(text == "synthetic pixel")
        #expect(context.provider.dispatches == 1)
        try context.provider.expectImage(data, mimeType: ext == "jpg" ? "image/jpeg" : "image/\(ext)")
    }

    @Test(arguments: ["png", "jpg", "webp"], [AnalyzeImageEntryPoint.file, .detailedFile])
    func `bytes win over misleading extension`(ext: String, entryPoint: AnalyzeImageEntryPoint) async throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        let data = try AnalyzeImageTestContext.fixture(ext)
        let url = try context.file(ext == "png" ? "pixel.jpg" : "pixel.png", data: data)
        _ = try await entryPoint.call(context, url: url, data: data)
        try context.provider.expectImage(data, mimeType: ext == "jpg" ? "image/jpeg" : "image/\(ext)")
    }

    @Test(
        arguments: ["PNG", "JPG", "JPEG", "WEBP", "GIF", "unknown"],
        [AnalyzeImageEntryPoint.file, .detailedFile])
    func `extension fallback`(ext: String, entryPoint: AnalyzeImageEntryPoint) async throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        let data = Data([0])
        let url = try context.file("unknown.\(ext)", data: data)
        _ = try await entryPoint.call(context, url: url, data: data)
        let mime = switch ext {
        case "JPG", "JPEG": "image/jpeg"
        case "WEBP": "image/webp"
        case "GIF": "image/gif"
        default: "image/png"
        }
        try context.provider.expectImage(data, mimeType: mime)
    }

    @Test(arguments: [AnalyzeImageEntryPoint.data, .detailedData])
    func `unknown data keeps PNG fallback`(entryPoint: AnalyzeImageEntryPoint) async throws {
        let context = try AnalyzeImageTestContext()
        defer { context.cleanUp() }
        let data = Data([0])
        _ = try await entryPoint.call(context, url: context.directory, data: data)
        try context.provider.expectImage(data, mimeType: "image/png")
    }
}

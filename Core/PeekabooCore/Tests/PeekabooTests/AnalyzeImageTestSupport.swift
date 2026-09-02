import Darwin
import Foundation
import ImageIO
import Testing
@testable import PeekabooAutomation
@testable import Tachikoma

/// Synthetic pixels only; every request terminates at the in-memory provider below.
@MainActor
final class AnalyzeImageTestContext {
    let directory: URL
    let provider = AnalyzeImageRequestCapture()
    let service: PeekabooAIService
    private let previousEnvironment: [String: String?]
    private let previousConfiguration: TachikomaConfiguration?
    private let previousProfile: String

    init() throws {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-analyze-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let overrides = [
            "PEEKABOO_CONFIG_DIR": self.directory.path,
            "PEEKABOO_CONFIG_DISABLE_MIGRATION": "1",
            "PEEKABOO_AI_PROVIDERS": "ollama/llava:latest",
        ]
        let keys = Array(overrides.keys) + [
            "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY",
            "MINIMAX_API_KEY", "MINIMAX_CN_API_KEY", "MOONSHOT_API_KEY", "KIMI_API_KEY",
            "OPENROUTER_API_KEY", "X_AI_API_KEY", "XAI_API_KEY", "GROK_API_KEY", "API_KEY",
        ]
        self.previousEnvironment = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, ProcessInfo.processInfo.environment[$0])
        })
        self.previousConfiguration = TachikomaConfiguration.default
        self.previousProfile = TachikomaConfiguration.profileDirectoryName
        for key in keys {
            unsetenv(key)
        }
        for (key, value) in overrides {
            setenv(key, value, 1)
        }
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        let provider = self.provider
        configuration.setProviderFactoryOverride { _, _ in
            provider.recordDispatch()
            return provider
        }
        TachikomaConfiguration.default = configuration
        ConfigurationManager.shared.resetForTesting()
        self.service = PeekabooAIService()
    }

    func cleanUp() {
        ConfigurationManager.shared.resetForTesting()
        TachikomaConfiguration.default = self.previousConfiguration
        TachikomaConfiguration.profileDirectoryName = self.previousProfile
        for (key, value) in self.previousEnvironment {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        try? FileManager.default.removeItem(at: self.directory)
    }

    func file(_ name: String, data: Data) throws -> URL {
        let url = self.directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func fixture(_ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "pixel", withExtension: ext))
        let data = try Data(contentsOf: url)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1)
        #expect(image.height == 1)
        return data
    }
}

enum AnalyzeImageEntryPoint: String, CaseIterable, Sendable {
    case file, detailedFile, data, detailedData

    @MainActor
    func call(_ context: AnalyzeImageTestContext, url: URL, data: Data) async throws -> String {
        switch self {
        case .file:
            try await context.service.analyzeImageFile(at: url.path, question: "Describe this pixel")
        case .detailedFile:
            try await context.service.analyzeImageFileDetailed(at: url.path, question: "Describe this pixel").text
        case .data:
            try await context.service.analyzeImage(imageData: data, question: "Describe this pixel")
        case .detailedData:
            try await context.service.analyzeImageDetailed(imageData: data, question: "Describe this pixel").text
        }
    }
}

final class AnalyzeImageRequestCapture: ModelProvider, @unchecked Sendable {
    let modelId = "analyze-request-capture"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities(supportsVision: true)
    private let lock = NSLock()
    private var dispatchCount = 0
    private var capturedRequests: [ProviderRequest] = []
    private var capturedWire: [Data] = []

    var dispatches: Int {
        self.lock.withLock { self.dispatchCount }
    }

    var requestCount: Int {
        self.lock.withLock { self.capturedRequests.count }
    }

    var requests: [ProviderRequest] {
        self.lock.withLock { self.capturedRequests }
    }

    var wire: [Data] {
        self.lock.withLock { self.capturedWire }
    }

    func recordDispatch() {
        self.lock.withLock { self.dispatchCount += 1 }
    }

    func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        // Use the real provider message converter/encoder, not an equivalent MIME mapper.
        let (_, messages) = try AnthropicMessageConversion.convertMessagesToAnthropic(
            request.messages, thinkingEnabled: false)
        let encoded = try JSONEncoder().encode(messages)
        self.lock.withLock {
            self.capturedRequests.append(request)
            self.capturedWire.append(encoded)
        }
        return ProviderResponse(text: "synthetic pixel", finishReason: .stop)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        throw TachikomaError.unsupportedOperation("Unexpected streaming request")
    }

    func expectImage(_ data: Data, mimeType: String) throws {
        let request = try #require(self.requests.last)
        let images = request.messages.flatMap(\.content).compactMap { part -> ModelMessage.ContentPart.ImageContent? in
            if case let .image(image) = part {
                return image
            }
            return nil
        }
        #expect(images.count == 1)
        let image = try #require(images.first)
        #expect(image.mimeType == mimeType)
        #expect(Data(base64Encoded: image.data) == data)

        let messages = try JSONDecoder().decode([WireMessage].self, from: #require(self.wire.last))
        let sources = messages.flatMap(\.content).compactMap(\.source)
        #expect(sources.count == 1)
        let source = try #require(sources.first)
        #expect(source.media_type == mimeType)
        #expect(Data(base64Encoded: source.data) == data)
    }

    private struct WireMessage: Decodable {
        let content: [Content]
        struct Content: Decodable {
            let source: Source?
        }

        struct Source: Decodable {
            let media_type: String
            let data: String
        }
    }
}

enum RejectedAnalyzeImage: String, CaseIterable, Sendable {
    case missing, directory, fifo, unreadable

    @MainActor
    func makeURL(in context: AnalyzeImageTestContext) throws -> URL {
        let url = context.directory.appendingPathComponent("\(self.rawValue).png")
        switch self {
        case .missing:
            break
        case .directory:
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        case .fifo:
            #expect(Darwin.mkfifo(url.path, 0o600) == 0)
        case .unreadable:
            try Data([0]).write(to: url)
            #expect(Darwin.chmod(url.path, 0) == 0)
        }
        return url
    }

    /// Release a regressed blocking FIFO open so failure reports instead of hanging the suite.
    func unblockIfNeeded(_ url: URL) -> DispatchWorkItem {
        let rescue = DispatchWorkItem {
            guard self == .fifo else { return }
            let descriptor = Darwin.open(url.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 {
                Darwin.close(descriptor)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: rescue)
        return rescue
    }
}

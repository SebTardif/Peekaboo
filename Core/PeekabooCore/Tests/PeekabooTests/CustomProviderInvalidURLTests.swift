import Darwin
import Foundation
import Network
import Tachikoma
import Testing
@testable import PeekabooAutomation
@testable import PeekabooCore

@Suite(.serialized)
struct CustomProviderInvalidURLTests {
    private let manager = ConfigurationManager.shared

    /// Persisted values can bypass `addCustomProvider` validation. An unterminated IPv6
    /// authority stays unparseable when an endpoint path is appended.
    private static let invalidBaseURL = "https://["

    @Test
    func `testCustomProvider reports invalid OpenAI URL instead of crashing`() async throws {
        try self.requireUnparseableEndpoint(path: "models")
        try await withIsolatedConfigurationEnvironment { _ in
            try self.seedBrokenProvider(id: "broken-openai", type: .openai)

            let result = await self.manager.testCustomProvider(id: "broken-openai")

            #expect(result.success == false)
            let error = try #require(result.error)
            #expect(error.contains("Invalid provider URL"))
        }
    }

    @Test
    func `testCustomProvider reports invalid Anthropic URL instead of crashing`() async throws {
        try self.requireUnparseableEndpoint(path: "messages")
        try await withIsolatedConfigurationEnvironment { _ in
            try self.seedBrokenProvider(id: "broken-anthropic", type: .anthropic)

            let result = await self.manager.testCustomProvider(id: "broken-anthropic")

            #expect(result.success == false)
            let error = try #require(result.error)
            #expect(error.contains("Invalid provider URL"))
        }
    }

    @Test
    func `custom provider probes accept exactly HTTP 200`() {
        #expect(ConfigurationManager.isSuccessfulCustomProviderProbe(statusCode: 200))
        #expect(!ConfigurationManager.isSuccessfulCustomProviderProbe(statusCode: 201))
        #expect(!ConfigurationManager.isSuccessfulCustomProviderProbe(statusCode: 401))
        #expect(!ConfigurationManager.isSuccessfulCustomProviderProbe(statusCode: 500))
    }

    @Test
    func `testCustomProvider accepts Anthropic HTTP 200`() async throws {
        let result = try await self.testAnthropicProvider(
            statusCode: 200,
            body: #"{"content":[]}"#,
            id: "anthropic-200")

        #expect(result.success)
        #expect(result.error == nil)
    }

    @Test
    func `testCustomProvider rejects Anthropic HTTP 201`() async throws {
        let result = try await self.testAnthropicProvider(
            statusCode: 201,
            body: #"{"error":"unexpected-created"}"#,
            id: "anthropic-201")

        #expect(result.success == false)
        let error = try #require(result.error)
        #expect(error.contains("unexpected-created"))
    }

    @Test
    func `discoverModelsForCustomProvider reports invalid URL instead of crashing`() async throws {
        try self.requireUnparseableEndpoint(path: "models")
        try await withIsolatedConfigurationEnvironment { _ in
            try self.seedBrokenProvider(id: "broken-discover", type: .openai)

            let result = await self.manager.discoverModelsForCustomProvider(id: "broken-discover")

            #expect(result.models.isEmpty)
            let error = try #require(result.error)
            #expect(error.contains("Invalid provider URL"))
        }
    }

    private func requireUnparseableEndpoint(path: String) throws {
        let candidate = "\(Self.invalidBaseURL)/\(path)"
        try #require(URL(string: candidate) == nil, "Fixture unexpectedly parsed: \(candidate)")
    }

    private func seedBrokenProvider(
        id: String,
        type: Configuration.CustomProvider.ProviderType) throws
    {
        try self.seedProvider(id: id, type: type, baseURL: Self.invalidBaseURL)
    }

    private func seedProvider(
        id: String,
        type: Configuration.CustomProvider.ProviderType,
        baseURL: String) throws
    {
        let provider = Configuration.CustomProvider(
            name: "Broken",
            type: type,
            options: .init(baseURL: baseURL, apiKey: "test-key"))
        try self.manager.updateConfiguration { configuration in
            if configuration.customProviders == nil {
                configuration.customProviders = [:]
            }
            configuration.customProviders?[id] = provider
        }
    }

    private func testAnthropicProvider(
        statusCode: Int,
        body: String,
        id: String) async throws -> (success: Bool, error: String?)
    {
        let server = try await ProviderProbeHTTPServer.start(statusCode: statusCode, body: body)
        defer { server.stop() }

        return try await withIsolatedConfigurationEnvironment { _ in
            try self.seedProvider(id: id, type: .anthropic, baseURL: server.baseURL)
            return await self.manager.testCustomProvider(id: id)
        }
    }
}

private func withIsolatedConfigurationEnvironment<T>(_ body: (URL) async throws -> T) async throws -> T {
    let fileManager = FileManager.default
    let configDir = fileManager.temporaryDirectory
        .appendingPathComponent("peekaboo-invalid-url-tests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)

    let previousConfigDir = getenv("PEEKABOO_CONFIG_DIR").map { String(cString: $0) }
    let previousDisableMigration = getenv("PEEKABOO_CONFIG_DISABLE_MIGRATION").map { String(cString: $0) }
    let previousProfileDirectory = TachikomaConfiguration.profileDirectoryName

    setenv("PEEKABOO_CONFIG_DIR", configDir.path, 1)
    setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
    ConfigurationManager.shared.resetForTesting()

    defer {
        if let previousConfigDir {
            setenv("PEEKABOO_CONFIG_DIR", previousConfigDir, 1)
        } else {
            unsetenv("PEEKABOO_CONFIG_DIR")
        }
        if let previousDisableMigration {
            setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", previousDisableMigration, 1)
        } else {
            unsetenv("PEEKABOO_CONFIG_DISABLE_MIGRATION")
        }
        TachikomaConfiguration.profileDirectoryName = previousProfileDirectory
        ConfigurationManager.shared.resetForTesting()
        try? fileManager.removeItem(at: configDir)
    }

    return try await body(configDir)
}

private final class ProviderProbeHTTPServer {
    private let listener: NWListener

    private init(listener: NWListener) {
        self.listener = listener
    }

    var baseURL: String {
        guard let port = self.listener.port else {
            preconditionFailure("HTTP test server must be ready before use")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    static func start(statusCode: Int, body: String) async throws -> ProviderProbeHTTPServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "peekaboo.tests.provider-probe-http")
        let response = Self.response(statusCode: statusCode, body: body)

        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                connection.send(
                    content: response,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        return ProviderProbeHTTPServer(listener: listener)
    }

    func stop() {
        self.listener.cancel()
    }

    private static func response(statusCode: Int, body: String) -> Data {
        let reason = statusCode == 200 ? "OK" : "Error"
        let bodyData = Data(body.utf8)
        let headers = "HTTP/1.1 \(statusCode) \(reason)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n\r\n"
        var data = Data(headers.utf8)
        data.append(bodyData)
        return data
    }
}

import Darwin
import Foundation
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
        let provider = Configuration.CustomProvider(
            name: "Broken",
            type: type,
            options: .init(baseURL: Self.invalidBaseURL, apiKey: "test-key"))
        try self.manager.updateConfiguration { configuration in
            if configuration.customProviders == nil {
                configuration.customProviders = [:]
            }
            configuration.customProviders?[id] = provider
        }
    }
}

private func withIsolatedConfigurationEnvironment(_ body: (URL) async throws -> Void) async throws {
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

    try await body(configDir)
}

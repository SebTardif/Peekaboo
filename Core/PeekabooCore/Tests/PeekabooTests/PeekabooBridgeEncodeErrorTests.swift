import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeEncodeErrorTests {
    @Test
    func `encodeError returns non-empty decodable error with default encoder`() throws {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .decodingFailed,
            message: "Failed to decode request",
            details: "unexpected end of file")

        let data = PeekabooBridgeResponse.encodeError(envelope)

        #expect(!data.isEmpty)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
        guard case let .error(decodedEnvelope) = decoded else {
            Issue.record("Expected error response, got \(decoded)")
            return
        }
        #expect(decodedEnvelope.code == .decodingFailed)
        #expect(decodedEnvelope.message == "Failed to decode request")
        #expect(decodedEnvelope.details == "unexpected end of file")
    }

    @Test
    func `encodeError static fallback JSON shape still decodes as error`() throws {
        let json = Data(
            #"{"error":{"_0":{"code":"internalError","message":"Failed to encode bridge error response","operationMayHaveCompleted":false}}}"#
                .utf8)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: json)
        guard case let .error(envelope) = decoded else {
            Issue.record("Expected error response from static JSON, got \(decoded)")
            return
        }
        #expect(envelope.code == .internalError)
        #expect(envelope.message == "Failed to encode bridge error response")
    }

    @Test
    func `decodeAndHandle never returns empty data for malformed request`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }

        let responseData = await server.decodeAndHandle(Data("not-json".utf8), peer: nil)

        #expect(!responseData.isEmpty)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: responseData)
        guard case let .error(envelope) = decoded else {
            Issue.record("Expected error response for malformed request, got \(decoded)")
            return
        }
        #expect(envelope.code == .decodingFailed)
    }

    @Test
    func `unfixed empty fallback pattern is empty when encode fails`() {
        // Documents the pre-fix contract: `?? Data()` yields empty bytes when encode fails.
        let unfixed: Data = (Data?.none) ?? Data()
        #expect(unfixed.isEmpty)

        let envelope = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: "encode failed")
        let fixed = PeekabooBridgeResponse.encodeError(envelope)
        #expect(!fixed.isEmpty)
    }
}

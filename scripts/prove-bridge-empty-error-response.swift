// Standalone proof for fix/bridge-empty-error-response.
// Shows that an empty error-payload fallback leaves clients unable to decode,
// while a non-empty error JSON remains decodable.
//
// Usage:
//   swiftc -parse-as-library -o /tmp/prove-bridge-empty \
//     scripts/prove-bridge-empty-error-response.swift && /tmp/prove-bridge-empty

import Foundation

/// Pre-fix behavior: when encoding an error envelope fails, return empty Data.
func encodeError_unfixed(encodeSucceeded: Bool) -> Data {
    let encoded: Data? = encodeSucceeded
        ? Data(#"{"error":{"code":"decodingFailed","message":"bad request","operationMayHaveCompleted":false}}"#.utf8)
        : nil
    return encoded ?? Data()
}

/// Fixed behavior: never return empty Data; use a static last-resort error JSON.
func encodeError_fixed(encodeSucceeded: Bool) -> Data {
    if encodeSucceeded,
       let encoded = Optional(
           Data(#"{"error":{"code":"decodingFailed","message":"bad request","operationMayHaveCompleted":false}}"#
               .utf8)),
       !encoded.isEmpty
    {
        return encoded
    }
    return Data(
        #"{"error":{"_0":{"code":"internalError","message":"Failed to encode bridge error response","operationMayHaveCompleted":false}}}"#
            .utf8)
}

func looksLikeErrorJSON(_ data: Data) -> Bool {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = obj["error"] as? [String: Any]
    else {
        return false
    }
    // Synthesized associated-value payload uses `_0`; also accept flat `code` for resilience.
    if error["code"] is String { return true }
    if let payload = error["_0"] as? [String: Any], payload["code"] is String { return true }
    return false
}

@main
struct ProveBridgeEmptyErrorResponse {
    static func main() {
        print("=== Unfixed (encode fails) ===")
        let unfixedFail = encodeError_unfixed(encodeSucceeded: false)
        print("bytes: \(unfixedFail.count)")
        print("decodable error JSON: \(looksLikeErrorJSON(unfixedFail))")

        print("=== Fixed (encode fails) ===")
        let fixedFail = encodeError_fixed(encodeSucceeded: false)
        print("bytes: \(fixedFail.count)")
        print("decodable error JSON: \(looksLikeErrorJSON(fixedFail))")
        if let s = String(data: fixedFail, encoding: .utf8) {
            print("payload: \(s)")
        }

        print("=== Fixed (encode succeeds) ===")
        let fixedOk = encodeError_fixed(encodeSucceeded: true)
        print("bytes: \(fixedOk.count)")
        print("decodable error JSON: \(looksLikeErrorJSON(fixedOk))")

        let ok = unfixedFail.isEmpty
            && !fixedFail.isEmpty
            && looksLikeErrorJSON(fixedFail)
            && looksLikeErrorJSON(fixedOk)
        print(ok ? "PROOF PASS" : "PROOF FAIL")
        if !ok { exit(1) }
    }
}

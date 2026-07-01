import XCTest
@testable import PitStop

final class GeminiPatchTests: XCTestCase {
    private func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - patchCliBlob

    func testPatchCliBlobUpdatesTokenAndPreservesUnknownKeys() {
        let jwt = "\(b64url("{}")).\(b64url(#"{"email":"user@example.com"}"#)).sig"
        let original = try! JSONSerialization.data(withJSONObject: [
            "access_token": "OLD_AT",
            "refresh_token": "RT",
            "id_token": jwt,
            "scope": "cloud-platform",
            "token_type": "Bearer",
            "expiry_date": 1_000_000.0,
            "extra_unknown_field": "keep_me",
        ] as [String: Any])

        let newExpiry = 2_000_000.0
        let patched = Gemini.patchCliBlob(original, access: "NEW_AT", idToken: nil, expiryMs: newExpiry)
        XCTAssertNotNil(patched, "patchCliBlob should return non-nil for a valid CLI blob")
        guard let patched else { return }

        let root = try! JSONSerialization.jsonObject(with: patched) as! [String: Any]
        // Updated fields
        XCTAssertEqual(root["access_token"] as? String, "NEW_AT")
        XCTAssertEqual((root["expiry_date"] as? NSNumber)?.doubleValue, newExpiry)
        // Unknown field preserved
        XCTAssertEqual(root["extra_unknown_field"] as? String, "keep_me")
        // Other fields preserved
        XCTAssertEqual(root["refresh_token"] as? String, "RT")
        XCTAssertEqual(root["token_type"] as? String, "Bearer")

        // Round-trips through cliCreds parser
        let creds = Gemini.cliCreds(from: patched)
        XCTAssertEqual(creds?.accessToken, "NEW_AT")
        XCTAssertEqual(creds?.expiryMs, newExpiry)
        XCTAssertEqual(creds?.email, "user@example.com")
    }

    func testPatchCliBlobUpdatesIdTokenWhenProvided() {
        let original = try! JSONSerialization.data(withJSONObject: [
            "access_token": "AT",
            "expiry_date": 1_000_000.0,
        ] as [String: Any])

        let newJwt = "\(b64url("{}")).\(b64url(#"{"email":"new@example.com"}"#)).sig"
        let patched = Gemini.patchCliBlob(original, access: "AT2", idToken: newJwt, expiryMs: 2_000_000.0)
        XCTAssertNotNil(patched)
        guard let patched else { return }

        let root = try! JSONSerialization.jsonObject(with: patched) as! [String: Any]
        XCTAssertEqual(root["id_token"] as? String, newJwt)

        // Round-trips with new email
        let creds = Gemini.cliCreds(from: patched)
        XCTAssertEqual(creds?.email, "new@example.com")
    }

    func testPatchCliBlobReturnsNilForInvalidInput() {
        let notJSON = Data("not-json".utf8)
        XCTAssertNil(Gemini.patchCliBlob(notJSON, access: "AT", idToken: nil, expiryMs: 0),
                     "patchCliBlob should return nil for non-JSON input")
    }

    // MARK: - patchAntigravityBlob

    func testPatchAntigravityBlobUpdatesTokenAndPreservesUnknownKeys() {
        let jwt = "\(b64url("{}")).\(b64url(#"{"email":"ag@example.com"}"#)).sig"
        let inner = try! JSONSerialization.data(withJSONObject: [
            "token": [
                "access_token": "OLD_AT",
                "token_type": "Bearer",
                "refresh_token": "RT",
                "id_token": jwt,
                "expiry": "2026-01-01T00:00:00+00:00",
                "inner_unknown": "inner_keep",
            ] as [String: Any],
            "auth_method": "consumer",
        ] as [String: Any])
        let original = Data(Gemini.encodeGoKeyring(inner).utf8)

        let newExpiry = "2027-01-01T00:00:00+00:00"
        let patched = Gemini.patchAntigravityBlob(original, access: "NEW_AT", idToken: nil, expiryISO: newExpiry)
        XCTAssertNotNil(patched, "patchAntigravityBlob should return non-nil for a valid blob")
        guard let patched else { return }

        // Result must still start with go-keyring-base64:
        let raw = String(data: patched, encoding: .utf8)!
        XCTAssertTrue(raw.hasPrefix("go-keyring-base64:"), "patched blob must retain go-keyring-base64: prefix")

        // Decode and inspect
        let innerData = Gemini.decodeGoKeyring(raw)!
        let innerObj = try! JSONSerialization.jsonObject(with: innerData) as! [String: Any]
        let tok = innerObj["token"] as! [String: Any]

        // Updated fields
        XCTAssertEqual(tok["access_token"] as? String, "NEW_AT")
        XCTAssertEqual(tok["expiry"] as? String, newExpiry)
        // Unknown inner key preserved
        XCTAssertEqual(tok["inner_unknown"] as? String, "inner_keep")
        // auth_method preserved
        XCTAssertEqual(innerObj["auth_method"] as? String, "consumer")
        // refresh_token preserved
        XCTAssertEqual(tok["refresh_token"] as? String, "RT")

        // Round-trips through antigravityCreds parser
        let creds = Gemini.antigravityCreds(from: patched)
        XCTAssertEqual(creds?.accessToken, "NEW_AT")
        XCTAssertEqual(creds?.email, "ag@example.com")
    }

    func testPatchAntigravityBlobUpdatesIdTokenWhenProvided() {
        let inner = try! JSONSerialization.data(withJSONObject: [
            "token": [
                "access_token": "AT",
                "expiry": "2026-01-01T00:00:00+00:00",
            ] as [String: Any],
            "auth_method": "consumer",
        ] as [String: Any])
        let original = Data(Gemini.encodeGoKeyring(inner).utf8)

        let newJwt = "\(b64url("{}")).\(b64url(#"{"email":"new@ag.com"}"#)).sig"
        let patched = Gemini.patchAntigravityBlob(original, access: "AT2", idToken: newJwt,
                                                  expiryISO: "2027-01-01T00:00:00+00:00")
        XCTAssertNotNil(patched)
        guard let patched else { return }

        let creds = Gemini.antigravityCreds(from: patched)
        XCTAssertEqual(creds?.email, "new@ag.com")
    }

    func testPatchAntigravityBlobReturnsNilForInvalidInput() {
        let notKeyring = Data("not-go-keyring".utf8)
        XCTAssertNil(Gemini.patchAntigravityBlob(notKeyring, access: "AT", idToken: nil, expiryISO: ""),
                     "patchAntigravityBlob should return nil for non-keyring input")
    }
}

import XCTest
@testable import PitStop

final class GeminiLoginAdapterTests: XCTestCase {
    func testCliAuthorizeURL() {
        let url = GeminiCliLoginAdapter().authorizeURL(
            challenge: "CH", state: "ST", redirectURI: "http://127.0.0.1:51000/oauth2callback",
            pasteMode: false,
            target: LoginTarget(email: "a@x.com", credentialAccount: "a@x.com"))
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.host, "accounts.google.com")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["client_id"], Gemini.cliClient.id)
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["access_type"], "offline")           // to get a refresh_token
        XCTAssertEqual(q["prompt"], "consent")
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:51000/oauth2callback")
        XCTAssertTrue((q["scope"] ?? "").contains("cloud-platform"))
    }

    func testCliBuildBlobShape() throws {
        let a = GeminiCliLoginAdapter()
        let tokens = FreshTokens(accessToken: "AT", refreshToken: "RT", idToken: "ID", expiresAtMs: 999)
        let blob = try a.buildBlob(old: Data(), tokens: tokens)
        XCTAssertEqual(Gemini.cliCreds(from: blob)?.accessToken, "AT")
    }

    func testAntigravityUsesOwnClientAndScopes() {
        XCTAssertEqual(GeminiAntigravityLoginAdapter().provider, .gemini)
        let url = GeminiAntigravityLoginAdapter().authorizeURL(
            challenge: "CH", state: "ST", redirectURI: "http://127.0.0.1:51000/oauth2callback",
            pasteMode: false,
            target: LoginTarget(email: "a@x.com", credentialAccount: "a@x.com"))
        let q = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["client_id"], Gemini.antigravityClient.id)
        XCTAssertTrue((q["scope"] ?? "").contains("cclog"))
    }

    func testCliBuildBlobPreservesRefreshTokenAndUnknownKeys() throws {
        let old = try JSONSerialization.data(withJSONObject: [
            "access_token": "OLD", "refresh_token": "KEEP-RT",
            "scope": "cloud-platform", "extra": "keep",
        ] as [String: Any])
        let tokens = FreshTokens(accessToken: "NEW", refreshToken: nil, idToken: nil, expiresAtMs: 999)
        let blob = try GeminiCliLoginAdapter().buildBlob(old: old, tokens: tokens)
        let root = try JSONSerialization.jsonObject(with: blob) as! [String: Any]
        XCTAssertEqual(root["access_token"] as? String, "NEW")
        XCTAssertEqual(root["refresh_token"] as? String, "KEEP-RT")   // preserved
        XCTAssertEqual(root["extra"] as? String, "keep")              // preserved
    }

    func testAntigravityBuildBlobPreservesRefreshToken() throws {
        let inner = try JSONSerialization.data(withJSONObject: [
            "token": ["access_token": "OLD", "refresh_token": "KEEP-RT",
                      "expiry": "2026-01-01T00:00:00+00:00"] as [String: Any],
            "auth_method": "consumer",
        ] as [String: Any])
        let old = Data(Gemini.encodeGoKeyring(inner).utf8)
        let tokens = FreshTokens(accessToken: "NEW", refreshToken: nil, idToken: nil, expiresAtMs: 999)
        let blob = try GeminiAntigravityLoginAdapter().buildBlob(old: old, tokens: tokens)
        let creds = Gemini.antigravityCreds(from: blob)
        XCTAssertEqual(creds?.accessToken, "NEW")
        XCTAssertEqual(creds?.refreshToken, "KEEP-RT")
    }
}

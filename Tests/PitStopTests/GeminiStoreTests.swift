import XCTest
@testable import PitStop

final class GeminiStoreTests: XCTestCase {
    func testBuildCliBlobIsValidOauthCreds() {
        let blob = GeminiStore.buildCliBlob(access: "AT", refresh: "RT",
                                            idToken: "ID", expiryMs: 123456)
        let root = try! JSONSerialization.jsonObject(with: blob) as! [String: Any]
        XCTAssertEqual(root["access_token"] as? String, "AT")
        XCTAssertEqual(root["refresh_token"] as? String, "RT")
        XCTAssertEqual(root["token_type"] as? String, "Bearer")
        XCTAssertEqual((root["expiry_date"] as? NSNumber)?.doubleValue, 123456)
        // round-trips through the parser
        XCTAssertEqual(Gemini.cliCreds(from: blob)?.accessToken, "AT")
    }

    func testBuildAntigravityBlobRoundTrips() {
        let blob = GeminiStore.buildAntigravityBlob(access: "AT2", refresh: "RT2",
                                                    idToken: "ID2", expiryISO: "2026-07-01T16:15:44+05:30")
        // stored value is the go-keyring-base64 string
        let raw = String(data: blob, encoding: .utf8)!
        XCTAssertTrue(raw.hasPrefix("go-keyring-base64:"))
        let creds = Gemini.antigravityCreds(from: blob)
        XCTAssertEqual(creds?.accessToken, "AT2")
        XCTAssertEqual(creds?.refreshToken, "RT2")
        // inner JSON carries auth_method
        let inner = try! JSONSerialization.jsonObject(with: Gemini.decodeGoKeyring(raw)!) as! [String: Any]
        XCTAssertEqual(inner["auth_method"] as? String, "consumer")
    }

    func testServicesAndPaths() {
        XCTAssertEqual(GeminiStore.cliService, "PitStop-gemini-cli")
        XCTAssertEqual(GeminiStore.antigravityService, "PitStop-gemini-antigravity")
        XCTAssertEqual(GeminiStore.liveKeychainService, "gemini")
        XCTAssertEqual(GeminiStore.liveKeychainAccount, "antigravity")
        XCTAssertTrue(GeminiStore.cliCredsURL.path.hasSuffix(".gemini/oauth_creds.json"))
        XCTAssertTrue(GeminiStore.googleAccountsURL.path.hasSuffix(".gemini/google_accounts.json"))
    }
}

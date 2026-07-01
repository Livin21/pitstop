import XCTest
@testable import PitStop

final class ClaudeExchangeTests: XCTestCase {
    func testExchangeRequestShape() throws {
        let host = URL(string: "https://platform.claude.com/v1/oauth/token")!
        let req = UsageAPI.exchangeCodeRequest(
            code: "C", state: "S", verifier: "V",
            redirectURI: "http://localhost:1455/callback", host: host)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url, host)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["grant_type"] as? String, "authorization_code")
        XCTAssertEqual(body?["code"] as? String, "C")
        XCTAssertEqual(body?["state"] as? String, "S")           // Claude sends state in the body
        XCTAssertEqual(body?["code_verifier"] as? String, "V")
        XCTAssertEqual(body?["client_id"] as? String, UsageAPI.clientID)
        XCTAssertEqual(body?["redirect_uri"] as? String, "http://localhost:1455/callback")
    }

    func testProfileRequestShape() {
        let req = UsageAPI.profileRequest(accessToken: "sk-ant-oat01-TOKEN")
        XCTAssertEqual(req.url?.host, "api.anthropic.com")
        XCTAssertTrue(req.url?.path.contains("/oauth/profile") ?? false)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-TOKEN")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }
}

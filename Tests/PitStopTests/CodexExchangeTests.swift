import XCTest
@testable import PitStop

final class CodexExchangeTests: XCTestCase {
    func testExchangeRequestIsFormUrlEncoded() {
        let req = Codex.exchangeCodeRequest(
            code: "C+1", verifier: "V", redirectURI: "http://localhost:1455/auth/callback")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://auth.openai.com/oauth/token")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"),
                       "application/x-www-form-urlencoded")
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=C%2B1"))                 // '+' percent-encoded
        XCTAssertTrue(body.contains("code_verifier=V"))
        XCTAssertTrue(body.contains("client_id=\(Codex.clientID)"))
        XCTAssertTrue(body.contains("redirect_uri="))              // required field present
        XCTAssertFalse(body.contains("state="))                    // Codex omits state in the body
    }

    func testIdentityFallbackAndNil() {
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        // No top-level email — fall back to the profile-namespace email.
        let fallback = #"{"https://api.openai.com/profile":{"email":"p@example.com"}}"#
        let id = Codex.identity(fromIDToken: "\(b64url("{}")).\(b64url(fallback)).sig")
        XCTAssertEqual(id?.email, "p@example.com")
        XCTAssertNil(id?.accountID)
        // No email anywhere — nil.
        XCTAssertNil(Codex.identity(fromIDToken: "\(b64url("{}")).\(b64url(#"{"sub":"x"}"#)).sig"))
    }

    func testIdentityFromIDToken() {
        // Minimal unsigned JWT: header.payload.sig ; payload carries email + auth.
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload = #"{"email":"user@example.com","https://api.openai.com/auth":{"chatgpt_account_id":"acct_123","chatgpt_plan_type":"plus"}}"#
        let jwt = "\(b64url("{}")).\(b64url(payload)).sig"
        let id = Codex.identity(fromIDToken: jwt)
        XCTAssertEqual(id?.email, "user@example.com")
        XCTAssertEqual(id?.accountID, "acct_123")
    }
}

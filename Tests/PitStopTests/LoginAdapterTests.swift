import XCTest
@testable import PitStop

final class LoginAdapterTests: XCTestCase {
    private let target = LoginTarget(email: "a@x.com", organizationID: "org-a",
                                     credentialAccount: "slot")

    func testClaudeAuthorizeURLLoopback() throws {
        let url = ClaudeLoginAdapter().authorizeURL(
            challenge: "CH", state: "ST",
            redirectURI: "http://localhost:51000/callback", pasteMode: false,
            target: target)
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.host, "claude.ai")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["client_id"], UsageAPI.clientID)
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["code_challenge"], "CH")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["state"], "ST")
        XCTAssertEqual(q["redirect_uri"], "http://localhost:51000/callback")
        XCTAssertTrue((q["scope"] ?? "").contains("user:inference"))
        XCTAssertNil(q["code"])                       // no code=true in loopback mode
        XCTAssertEqual(q["orgUUID"], "org-a")
    }

    func testClaudeAuthorizeURLPasteMode() throws {
        let url = ClaudeLoginAdapter().authorizeURL(
            challenge: "CH", state: "ST",
            redirectURI: ClaudeLoginAdapter().pasteRedirectURI, pasteMode: true,
            target: target)
        let q = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["code"], "true")             // paste mode sets code=true
        XCTAssertEqual(q["redirect_uri"], "https://platform.claude.com/oauth/code/callback")
    }

    func testCodexAuthorizeURL() throws {
        let a = CodexLoginAdapter()
        XCTAssertEqual(a.loopbackPorts, [1455, 1457])
        XCTAssertEqual(a.loopbackPath, "/auth/callback")
        XCTAssertFalse(a.supportsPaste)
        let url = a.authorizeURL(challenge: "CH", state: "ST",
                                 redirectURI: "http://localhost:1455/auth/callback", pasteMode: false,
                                 target: target)
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.host, "auth.openai.com")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["client_id"], Codex.clientID)
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["id_token_add_organizations"], "true")
        XCTAssertEqual(q["codex_cli_simplified_flow"], "true")
        XCTAssertTrue((q["scope"] ?? "").contains("openid"))
    }

    func testClaudeBuildBlobPatchesTokensPreservesRest() throws {
        let old = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "OLD", "refreshToken": "OLDR", "expiresAt": 1000,
                "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x",
            ],
            "mcpOAuth": ["keep": "me"],
        ])
        let tokens = FreshTokens(accessToken: "NEW", refreshToken: "NEWR",
                                 idToken: nil, expiresAtMs: 9_999_000)
        let blob = try ClaudeLoginAdapter().buildBlob(old: old, tokens: tokens)
        let creds = try CredentialBlob.parse(blob)
        XCTAssertEqual(creds.accessToken, "NEW")
        XCTAssertEqual(creds.refreshToken, "NEWR")
        XCTAssertEqual(creds.expiresAtMs, 9_999_000)
        XCTAssertEqual(creds.subscriptionType, "max")            // preserved
        XCTAssertEqual(creds.rateLimitTier, "default_claude_max_5x")  // preserved
        let root = try JSONSerialization.jsonObject(with: blob) as? [String: Any]
        XCTAssertNotNil(root?["mcpOAuth"])                        // preserved verbatim
    }

    func testCodexBuildBlobIsCompactAndPatched() throws {
        let old = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": ["access_token": "OLD", "refresh_token": "OLDR",
                       "id_token": "OLDID", "account_id": "acct_1"],
        ])
        let tokens = FreshTokens(accessToken: "NEW", refreshToken: "NEWR",
                                 idToken: "NEWID", expiresAtMs: nil)
        let blob = try CodexLoginAdapter().buildBlob(old: old, tokens: tokens)
        XCTAssertFalse(String(data: blob, encoding: .utf8)!.contains("\n"))   // compact
        let creds = Codex.credentials(from: blob)
        XCTAssertEqual(creds?.accessToken, "NEW")
        let root = try JSONSerialization.jsonObject(with: blob) as? [String: Any]
        XCTAssertEqual(root?["auth_mode"] as? String, "chatgpt")             // preserved
        let toks = root?["tokens"] as? [String: Any]
        XCTAssertEqual(toks?["id_token"] as? String, "NEWID")
        XCTAssertEqual(toks?["account_id"] as? String, "acct_1")            // preserved
    }
}

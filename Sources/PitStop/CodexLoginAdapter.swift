import Foundation

/// OpenAI Codex ("Sign in with ChatGPT") login. Fully automatic loopback on the
/// ports the Codex CLI already registers (1455, fallback 1457).
struct CodexLoginAdapter: LoginAdapter {
    var provider: Provider { .codex }
    var loopbackPorts: [UInt16] { [1455, 1457] }
    var loopbackPath: String { "/auth/callback" }
    var supportsPaste: Bool { false }
    var pasteRedirectURI: String { "" }

    static let scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke"

    func authorizeURL(challenge: String, state: String, redirectURI: String,
                      pasteMode: Bool, target: LoginTarget) -> URL {
        var c = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Codex.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
        ]
        return c.url!
    }

    func exchange(code: String, state: String, verifier: String,
                  redirectURI: String) async throws -> FreshTokens {
        let r = try await Codex.exchangeCode(code: code, verifier: verifier, redirectURI: redirectURI)
        return FreshTokens(accessToken: r.accessToken, refreshToken: r.refreshToken,
                           idToken: r.idToken, expiresAtMs: nil)
    }

    func identity(from tokens: FreshTokens) async throws -> LoginIdentity {
        guard let idToken = tokens.idToken,
              let id = Codex.identity(fromIDToken: idToken) else {
            throw LoginError.badResponse("Codex sign-in returned no id_token")
        }
        return LoginIdentity(email: id.email, accountID: id.accountID, organizationID: nil)
    }

    func buildBlob(old: Data, tokens: FreshTokens) throws -> Data {
        let refreshed = Codex.Refreshed(accessToken: tokens.accessToken,
                                        refreshToken: tokens.refreshToken,
                                        idToken: tokens.idToken)
        guard let patched = Codex.patching(old, with: refreshed) else {
            throw LoginError.badResponse("Could not patch Codex credentials")
        }
        return Codex.normalizedBlob(patched)
    }

    func persist(_ tokens: FreshTokens, target: LoginTarget) async throws {
        guard let old = try await Keychain.read(service: CodexStore.service,
                                                account: target.credentialAccount) else {
            throw LoginError.noSavedProfile(target.email)
        }
        let blob = try buildBlob(old: old, tokens: tokens)
        try await Keychain.upsert(service: CodexStore.service,
                                  account: target.credentialAccount, data: blob)
    }
}

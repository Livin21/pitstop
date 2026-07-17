import Foundation

/// Claude Code (Claude.ai subscription) login. [verify] items: localhost
/// redirect acceptance, token host, and the /api/oauth/profile identity source.
struct ClaudeLoginAdapter: LoginAdapter {
    var provider: Provider { .claude }
    // A small candidate range; the exact port is embedded in redirect_uri, so any
    // free loopback port works if the client accepts localhost at all.
    var loopbackPorts: [UInt16] { [51000, 51001, 51002, 51003] }
    var loopbackPath: String { "/callback" }
    var supportsPaste: Bool { true }
    var pasteRedirectURI: String { "https://platform.claude.com/oauth/code/callback" }

    static let scopes = "org:create_api_key user:profile user:inference "
        + "user:sessions:claude_code user:mcp_servers user:file_upload"

    func authorizeURL(challenge: String, state: String, redirectURI: String,
                      pasteMode: Bool, target: LoginTarget) -> URL {
        var c = URLComponents(string: "https://claude.ai/oauth/authorize")!
        var items = [
            URLQueryItem(name: "client_id", value: UsageAPI.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if pasteMode { items.insert(URLQueryItem(name: "code", value: "true"), at: 0) }
        if let org = target.organizationID {
            items.append(URLQueryItem(name: "orgUUID", value: org))
        }
        c.queryItems = items
        return c.url!
    }

    func exchange(code: String, state: String, verifier: String,
                  redirectURI: String) async throws -> FreshTokens {
        let r = try await UsageAPI.exchangeCode(code: code, state: state,
                                                verifier: verifier, redirectURI: redirectURI)
        return FreshTokens(accessToken: r.accessToken, refreshToken: r.refreshToken,
                           idToken: nil, expiresAtMs: r.expiresAtMs)
    }

    func identity(from tokens: FreshTokens) async throws -> LoginIdentity {
        let identity = try await UsageAPI.fetchAccountIdentity(accessToken: tokens.accessToken)
        return LoginIdentity(email: identity.email, accountID: nil,
                             organizationID: identity.organizationUUID)
    }

    func buildBlob(old: Data, tokens: FreshTokens) throws -> Data {
        try CredentialBlob.patching(old,
                                    accessToken: tokens.accessToken,
                                    refreshToken: tokens.refreshToken,
                                    expiresAtMs: tokens.expiresAtMs ?? 0)
    }

    func persist(_ tokens: FreshTokens, target: LoginTarget) async throws {
        guard let old = try await Keychain.read(service: CredentialBlob.profileService,
                                                account: target.credentialAccount) else {
            throw LoginError.noSavedProfile(target.email)
        }
        let blob = try buildBlob(old: old, tokens: tokens)
        try await Keychain.upsert(service: CredentialBlob.profileService,
                                  account: target.credentialAccount, data: blob)
    }
}

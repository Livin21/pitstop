import Foundation

/// Shared Google OAuth login behavior for the two Gemini surfaces. Google
/// installed-app clients accept an arbitrary loopback redirect, so re-login is
/// fully automatic (no paste fallback).
protocol GeminiLoginAdapter: LoginAdapter {
    var client: Gemini.Client { get }
    var surface: Gemini.Surface { get }
    var profileService: String { get }
}

extension GeminiLoginAdapter {
    var provider: Provider { .gemini }
    var loopbackPorts: [UInt16] { [51000, 51001, 51002, 51003] }
    var loopbackPath: String { "/oauth2callback" }
    var supportsPaste: Bool { false }
    var pasteRedirectURI: String { "" }

    func authorizeURL(challenge: String, state: String, redirectURI: String,
                      pasteMode: Bool, target: LoginTarget) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: client.id),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: client.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    func exchange(code: String, state: String, verifier: String, redirectURI: String) async throws -> FreshTokens {
        var req = URLRequest(url: Gemini.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        func enc(_ s: String) -> String {
            var cs = CharacterSet.alphanumerics; cs.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
        }
        let fields = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
                      "client_id": client.id, "client_secret": client.secret, "code_verifier": verifier]
        req.httpBody = Data(fields.map { "\(enc($0.key))=\(enc($0.value))" }.joined(separator: "&").utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String else {
            throw LoginError.badResponse("Google token exchange failed")
        }
        let expiresIn = (root["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return FreshTokens(accessToken: access, refreshToken: root["refresh_token"] as? String,
                           idToken: root["id_token"] as? String,
                           expiresAtMs: (Date().timeIntervalSince1970 + expiresIn) * 1000)
    }

    func identity(from tokens: FreshTokens) async throws -> LoginIdentity {
        guard let idt = tokens.idToken, let email = Gemini.decodeJWTEmail(idt) else {
            throw LoginError.badResponse("Google sign-in returned no id_token email")
        }
        return LoginIdentity(email: email, accountID: nil, organizationID: nil)
    }

    func persist(_ tokens: FreshTokens, target: LoginTarget) async throws {
        // Patch the saved blob when one exists — Google may omit refresh_token
        // on re-auth, and rebuilding from scratch would destroy the stored one.
        let old = (try? await Keychain.read(service: profileService,
                                            account: target.credentialAccount)) ?? Data()
        let blob = try buildBlob(old: old, tokens: tokens)
        try await Keychain.upsert(service: profileService,
                                  account: target.credentialAccount, data: blob)
    }
}

struct GeminiCliLoginAdapter: GeminiLoginAdapter {
    var client: Gemini.Client { Gemini.cliClient }
    var surface: Gemini.Surface { .cli }
    var profileService: String { GeminiStore.cliService }
    func buildBlob(old: Data, tokens: FreshTokens) throws -> Data {
        // Patch the old blob when it parses (preserves refresh_token and any
        // keys the CLI added); build from scratch only when there's nothing.
        let expiryMs = tokens.expiresAtMs ?? 0
        if var obj = try? JSONSerialization.jsonObject(with: old) as? [String: Any] {
            obj["access_token"] = tokens.accessToken
            obj["expiry_date"] = expiryMs
            if let r = tokens.refreshToken { obj["refresh_token"] = r }
            if let id = tokens.idToken { obj["id_token"] = id }
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                return data
            }
        }
        return GeminiStore.buildCliBlob(access: tokens.accessToken, refresh: tokens.refreshToken,
                                        idToken: tokens.idToken, expiryMs: expiryMs)
    }
}

struct GeminiAntigravityLoginAdapter: GeminiLoginAdapter {
    var client: Gemini.Client { Gemini.antigravityClient }
    var surface: Gemini.Surface { .antigravity }
    var profileService: String { GeminiStore.antigravityService }
    func buildBlob(old: Data, tokens: FreshTokens) throws -> Data {
        let iso = Gemini.iso8601.string(from: Date(timeIntervalSince1970: (tokens.expiresAtMs ?? 0) / 1000))
        // Patch the old blob when it parses (preserves refresh_token and any
        // sibling keys); build from scratch only when there's nothing.
        if let raw = String(data: old, encoding: .utf8),
           let inner = Gemini.decodeGoKeyring(raw),
           var obj = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
           var tok = obj["token"] as? [String: Any] {
            tok["access_token"] = tokens.accessToken
            tok["expiry"] = iso
            if let r = tokens.refreshToken { tok["refresh_token"] = r }
            if let id = tokens.idToken { tok["id_token"] = id }
            obj["token"] = tok
            if let re = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                return Data(Gemini.encodeGoKeyring(re).utf8)
            }
        }
        return GeminiStore.buildAntigravityBlob(access: tokens.accessToken, refresh: tokens.refreshToken,
                                                idToken: tokens.idToken, expiryISO: iso)
    }
}

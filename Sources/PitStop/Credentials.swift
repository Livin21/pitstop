import Foundation

/// A Claude subscription is scoped to an organization, not just an email.
/// The same Claude user can belong to multiple organizations whose usage and
/// credentials must remain independent.
struct ClaudeAccountIdentity: Hashable, Codable {
    let email: String
    let organizationUUID: String

    init(email: String, organizationUUID: String) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.organizationUUID = organizationUUID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    init?(oauthAccount: [String: Any]) {
        guard let email = oauthAccount["emailAddress"] as? String,
              let organizationUUID = oauthAccount["organizationUuid"] as? String,
              !email.isEmpty, !organizationUUID.isEmpty else { return nil }
        self.init(email: email, organizationUUID: organizationUUID)
    }

    /// Opaque provider-namespaced key used by all per-account app state.
    var key: String { "claude:\(email)#\(organizationUUID)" }
}

/// The decoded `claudeAiOauth` section of the Claude Code credential blob.
struct OAuthCredentials {
    var accessToken: String
    var refreshToken: String?
    var expiresAtMs: Double
    var subscriptionType: String?
    var rateLimitTier: String?

    var expiresAt: Date { Date(timeIntervalSince1970: expiresAtMs / 1000) }
    /// Treat anything within 2 minutes of expiry as expired.
    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-120) }
}

/// The Claude Code keychain payload is a JSON object with `claudeAiOauth`
/// plus other sections (e.g. `mcpOAuth`). Profiles store the whole blob
/// verbatim so switching accounts also carries each account's MCP auth.
enum CredentialBlob {
    static let liveService = "Claude Code-credentials"
    static let profileService = "PitStop-profile"

    struct Malformed: LocalizedError {
        var errorDescription: String? { "Credential blob is not in the expected format" }
    }

    static func parse(_ data: Data) throws -> OAuthCredentials {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String else {
            throw Malformed()
        }
        return OAuthCredentials(
            accessToken: access,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAtMs: (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }

    /// Returns a copy of the blob with fresh tokens patched into
    /// `claudeAiOauth`, leaving every other section untouched.
    static func patching(_ data: Data, accessToken: String,
                         refreshToken: String?, expiresAtMs: Double) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw Malformed()
        }
        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        oauth["expiresAt"] = expiresAtMs
        root["claudeAiOauth"] = oauth
        return try JSONSerialization.data(withJSONObject: root)
    }
}

/// Reads/writes the `oauthAccount` section of ~/.claude.json — the identity
/// (email, org) Claude Code displays for the logged-in account.
enum ClaudeConfig {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    struct Unreadable: LocalizedError {
        var errorDescription: String? { "~/.claude.json is missing or not valid JSON" }
    }

    static func oauthAccount() -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return root["oauthAccount"] as? [String: Any]
    }

    static func activeIdentity() -> ClaudeAccountIdentity? {
        oauthAccount().flatMap(ClaudeAccountIdentity.init(oauthAccount:))
    }

    static func setOauthAccount(_ account: [String: Any]) throws {
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Unreadable()
        }
        root["oauthAccount"] = account
        let out = try JSONSerialization.data(withJSONObject: root)
        try AtomicFile.write(out, to: url)
    }
}

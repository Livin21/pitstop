import Foundation

/// Reads OpenAI Codex accounts and their usage, and is the source of truth for
/// the Codex credential store.
///
/// Codex (both the CLI and the Codex.app GUI) signs into ChatGPT and stores its
/// OAuth tokens in `~/.codex/auth.json` — a plain JSON file. On a given Mac the
/// app and CLI share that file (`CODEX_HOME=~/.codex`), so the *live* account is
/// whatever's in it. `CodexStore` saves snapshots of it per account so PitStop
/// can switch between them (swapping the file), mirroring the Claude Code model
/// — only here the live store is a file rather than a keychain item.
///
/// Usage comes from `chatgpt.com/backend-api/codex/usage`, a cheap metadata GET
/// (no model turn) returning each rate-limit window's used-percent and reset.
enum Codex {
    /// The Codex account identity (no secrets).
    struct Account: Equatable {
        var email: String
        var planLabel: String
    }

    /// Credentials parsed from an `auth.json` blob.
    struct Creds {
        var accessToken: String
        var refreshToken: String?
        var accountId: String
        var account: Account
    }

    /// Codex CLI's public OAuth client (the `aud` claim of its id_token).
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    /// Provider-neutral usage for the row: a labelled bar per rate-limit window.
    struct Usage {
        struct Window {
            var label: String          // "5h" / "7d" / "30d"
            var usedPercent: Double
            var resetsAt: Date?
        }
        var windows: [Window]
        var fetchedAt = Date()
        var maxUtilization: Double { windows.map(\.usedPercent).max() ?? 0 }

        /// Auto-switch's filtered view. Codex windows are account-wide
        /// duration windows: "5h" is the session kind; "7d"/"30d" — and
        /// anything unrecognized — count as weekly, the safer long-window
        /// bucket. nil when no enabled window exists.
        func maxUtilization(kinds: Set<LimitKind>) -> Double? {
            windows.filter { kinds.contains($0.label == "5h" ? .session : .weekly) }
                .map(\.usedPercent).max()
        }
    }

    enum CodexError: LocalizedError {
        case sessionExpired
        case malformed
        case notSignedIn
        var errorDescription: String? {
            switch self {
            case .sessionExpired: return "Codex token expired"
            case .malformed: return "Unexpected Codex usage response"
            case .notSignedIn: return "Not signed in to Codex with a ChatGPT account"
            }
        }
    }

    static var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    /// True when Codex is installed and configured at all.
    static var isPresent: Bool {
        FileManager.default.fileExists(atPath: authURL.path)
    }

    private static let usageURL =
        URL(string: "https://chatgpt.com/backend-api/codex/usage")!

    // MARK: - Credentials

    /// The current `~/.codex/auth.json` contents, or nil if absent.
    static func liveBlob() -> Data? { try? Data(contentsOf: authURL) }

    /// Re-serialize an auth blob as compact, key-sorted JSON. The keychain read
    /// path (`security -w`) hex-encodes any secret containing newlines, and
    /// Codex writes `auth.json` pretty-printed — so it must be flattened before
    /// it's stored, or it reads back as a hex string and corrupts the file on
    /// restore. JSON is whitespace-insensitive, so Codex reads the compact form
    /// back fine; sorted keys make the bytes stable for change detection.
    static func normalizedBlob(_ data: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let compact = try? JSONSerialization.data(withJSONObject: obj,
                                                        options: [.sortedKeys]) else {
            return data
        }
        return compact
    }

    /// If the live auth.json carries an OPENAI_API_KEY that the saved snapshot
    /// lacks, carry it into the blob being written — a switch must not destroy
    /// API-key auth that only ever lived in the file (captureCurrent can't
    /// snapshot it: there's no account identity to file it under).
    static func preservingAPIKey(from live: Data?, into blob: Data) -> Data {
        guard let live,
              let liveRoot = try? JSONSerialization.jsonObject(with: live) as? [String: Any],
              let apiKey = liveRoot["OPENAI_API_KEY"] as? String, !apiKey.isEmpty,
              var root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              (root["OPENAI_API_KEY"] as? String)?.isEmpty ?? true else { return blob }
        root["OPENAI_API_KEY"] = apiKey
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? blob
    }

    /// Parse a ChatGPT (not API-key) Codex auth blob into credentials +
    /// identity. Returns nil for API-key auth or a blob without ChatGPT tokens.
    static func credentials(from blob: Data) -> Creds? {
        guard let root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let accountId = tokens["account_id"] as? String,
              let idToken = tokens["id_token"] as? String else {
            return nil
        }
        let claims = decodeJWTClaims(idToken)
        let email = claims?["email"] as? String ?? "Codex account"
        let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
        let plan = (auth?["chatgpt_plan_type"] as? String)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return Creds(accessToken: access,
                     refreshToken: tokens["refresh_token"] as? String,
                     accountId: accountId,
                     account: Account(email: email, planLabel: plan ?? ""))
    }

    /// Decode (without verifying) the claims of a JWT.
    private static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Usage fetch

    /// Live usage for one account's credentials. Throws `.sessionExpired` on a
    /// 401/403 (its token has gone stale — Codex only keeps the live one fresh).
    static func fetchUsage(_ creds: Creds) async throws -> Usage {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(creds.accountId, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue("PitStop", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CodexError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw CodexError.sessionExpired }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageAPI.APIError.rateLimited(retryAfter: retryAfter)
        }
        guard http.statusCode == 200 else { throw UsageAPI.APIError.http(http.statusCode) }
        return try parseUsage(data)
    }

    /// Convenience for the live account (used by `--check`).
    static func poll() async throws -> (account: Account, usage: Usage)? {
        guard let blob = liveBlob(), let creds = credentials(from: blob) else { return nil }
        return (creds.account, try await fetchUsage(creds))
    }

    // MARK: - Token refresh

    struct Refreshed { var accessToken: String; var refreshToken: String?; var idToken: String? }

    /// Exchange a refresh token for fresh tokens via the ChatGPT OAuth token
    /// endpoint. Used only for inactive saved accounts (Codex keeps the live
    /// one fresh itself). Throws `.sessionExpired` if the refresh token is
    /// rejected — it won't recover without a re-login.
    static func refresh(refreshToken: String) async throws -> Refreshed {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CodexError.malformed }
        if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
            throw CodexError.sessionExpired
        }
        guard http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String else {
            throw CodexError.malformed
        }
        return Refreshed(accessToken: access,
                         refreshToken: root["refresh_token"] as? String,
                         idToken: root["id_token"] as? String)
    }

    /// Return a copy of `blob` with refreshed tokens patched into `tokens`,
    /// leaving every other field (auth_mode, OPENAI_API_KEY, …) untouched.
    static func patching(_ blob: Data, with refreshed: Refreshed) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: blob)) as? [String: Any],
              var tokens = root["tokens"] as? [String: Any] else { return nil }
        tokens["access_token"] = refreshed.accessToken
        if let rt = refreshed.refreshToken { tokens["refresh_token"] = rt }
        if let idt = refreshed.idToken { tokens["id_token"] = idt }
        root["tokens"] = tokens
        root["last_refresh"] = iso8601.string(from: Date())
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    // MARK: - Fresh login (authorization_code)

    /// Build the authorization_code exchange request (form-urlencoded, no
    /// `state` in the body — the shape the Codex CLI uses). Pure, for testing.
    static func exchangeCodeRequest(code: String, verifier: String,
                                    redirectURI: String) -> URLRequest {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        func enc(_ s: String) -> String {
            var cs = CharacterSet.alphanumerics
            cs.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
        }
        let fields = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]
        req.httpBody = Data(fields.map { "\(enc($0.key))=\(enc($0.value))" }
            .joined(separator: "&").utf8)
        return req
    }

    /// Exchange an authorization code for Codex tokens.
    static func exchangeCode(code: String, verifier: String,
                             redirectURI: String) async throws -> Refreshed {
        let (data, resp) = try await URLSession.shared.data(
            for: exchangeCodeRequest(code: code, verifier: verifier, redirectURI: redirectURI))
        guard let http = resp as? HTTPURLResponse else { throw CodexError.malformed }
        if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
            throw CodexError.sessionExpired
        }
        guard http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String else {
            throw CodexError.malformed
        }
        return Refreshed(accessToken: access,
                         refreshToken: root["refresh_token"] as? String,
                         idToken: root["id_token"] as? String)
    }

    /// Decode identity (email + ChatGPT account id) from an id_token JWT.
    static func identity(fromIDToken idToken: String) -> (email: String, accountID: String?)? {
        guard let claims = decodeJWTClaims(idToken) else { return nil }
        let email = (claims["email"] as? String)
            ?? ((claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String)
        guard let email else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let accountID = auth?["chatgpt_account_id"] as? String
        return (email, accountID)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseUsage(_ data: Data) throws -> Usage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexError.malformed
        }
        var windows: [Usage.Window] = []
        if let rl = root["rate_limit"] as? [String: Any] {
            for key in ["primary_window", "secondary_window"] {
                if let w = window(rl[key]) { windows.append(w) }
            }
        }
        return Usage(windows: windows)
    }

    private static func window(_ any: Any?) -> Usage.Window? {
        guard let d = any as? [String: Any],
              let used = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let seconds = (d["limit_window_seconds"] as? NSNumber)?.intValue ?? 0
        let resetAt = (d["reset_at"] as? NSNumber)?.doubleValue
        return Usage.Window(label: windowLabel(seconds: seconds),
                            usedPercent: used,
                            resetsAt: resetAt.map { Date(timeIntervalSince1970: $0) })
    }

    /// A compact label for a window duration: "5h", "7d", "30d".
    private static func windowLabel(seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        if seconds % 86400 == 0 { return "\(seconds / 86400)d" }
        if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        return "\(seconds / 60)m"
    }
}

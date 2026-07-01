import Foundation

/// Google Gemini provider: the Gemini CLI (~/.gemini/oauth_creds.json) and
/// Antigravity (keychain gemini/antigravity) surfaces, both authenticating one
/// Google account against the Code Assist backend (cloudcode-pa.googleapis.com).
enum Gemini {
    /// Which surface a credential blob came from — they use different OAuth
    /// clients and different on-disk formats.
    enum Surface { case cli, antigravity }

    struct Creds {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var expiryMs: Double        // ms epoch; 0 = unknown
        var email: String
    }

    enum GeminiError: LocalizedError {
        case sessionExpired, malformed, notSignedIn
        var errorDescription: String? {
            switch self {
            case .sessionExpired: return "Gemini session expired — sign in again"
            case .malformed: return "Unexpected Gemini response"
            case .notSignedIn: return "Not signed in to Gemini"
            }
        }
    }

    private static let goKeyringPrefix = "go-keyring-base64:"

    /// The Antigravity keychain value is `"go-keyring-base64:" + base64(JSON)`.
    static func decodeGoKeyring(_ raw: String) -> Data? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(goKeyringPrefix) else { return nil }
        return Data(base64Encoded: String(s.dropFirst(goKeyringPrefix.count)))
    }

    static func encodeGoKeyring(_ json: Data) -> String {
        goKeyringPrefix + json.base64EncodedString()
    }

    /// Parse the Gemini CLI `oauth_creds.json` blob.
    static func cliCreds(from blob: Data) -> Creds? {
        guard let root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let access = root["access_token"] as? String, !access.isEmpty else { return nil }
        let idToken = root["id_token"] as? String
        return Creds(accessToken: access,
                     refreshToken: root["refresh_token"] as? String,
                     idToken: idToken,
                     expiryMs: (root["expiry_date"] as? NSNumber)?.doubleValue ?? 0,
                     email: idToken.flatMap(decodeJWTEmail) ?? "Gemini account")
    }

    /// Parse the Antigravity keychain blob (the whole `go-keyring-base64:` string).
    static func antigravityCreds(from blob: Data) -> Creds? {
        guard let raw = String(data: blob, encoding: .utf8),
              let json = decodeGoKeyring(raw),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let tok = root["token"] as? [String: Any],
              let access = tok["access_token"] as? String, !access.isEmpty else { return nil }
        let idToken = tok["id_token"] as? String
        // expiry is ISO8601 with tz offset; convert to ms (0 if unparseable).
        var expiryMs: Double = 0
        if let e = tok["expiry"] as? String, let d = iso8601.date(from: e) {
            expiryMs = d.timeIntervalSince1970 * 1000
        }
        return Creds(accessToken: access,
                     refreshToken: tok["refresh_token"] as? String,
                     idToken: idToken,
                     expiryMs: expiryMs,
                     email: idToken.flatMap(decodeJWTEmail) ?? "Gemini account")
    }

    /// Email from an id_token JWT payload (email or profile.email). No verify.
    static func decodeJWTEmail(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let e = claims["email"] as? String { return e }
        if let p = claims["https://api.openai.com/profile"] as? [String: Any],
           let e = p["email"] as? String { return e }
        return nil
    }

    /// "gemini-3.1-pro-preview" -> "3.1-pro" (drop gemini- prefix and -preview suffix).
    static func shortModelName(_ modelId: String) -> String {
        var s = modelId
        if s.hasPrefix("gemini-") { s.removeFirst("gemini-".count) }
        if s.hasSuffix("-preview") { s.removeLast("-preview".count) }
        return s
    }

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f
    }()

    // MARK: - Usage

    struct Usage {
        struct Window { var label: String; var usedPercent: Double; var resetsAt: Date? }
        var windows: [Window]
        var fetchedAt = Date()
        var maxUtilization: Double { windows.map(\.usedPercent).max() ?? 0 }
    }

    /// Parse a retrieveUserQuota response into per-model windows. Buckets whose
    /// `remainingFraction` is missing are skipped (the field is optional).
    static func parseQuota(_ data: Data) -> Usage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["buckets"] as? [[String: Any]] else {
            return Usage(windows: [])
        }
        let windows: [Usage.Window] = buckets.compactMap { b in
            guard let model = b["modelId"] as? String,
                  let frac = (b["remainingFraction"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (b["resetTime"] as? String).flatMap { quotaReset.date(from: $0) }
            return Usage.Window(label: shortModelName(model),
                                usedPercent: max(0, min(100, (1 - frac) * 100)),
                                resetsAt: reset)
        }
        return Usage(windows: windows)
    }

    /// The compact extras line: the up-to-2 most-used models after the binding
    /// one, dropping 0%. nil when there's nothing to add.
    static func extrasLine(_ usage: Usage) -> String? {
        let sorted = usage.windows.sorted { $0.usedPercent > $1.usedPercent }
        let extras = sorted.dropFirst().filter { $0.usedPercent >= 0.5 }.prefix(2)
        guard !extras.isEmpty else { return nil }
        return extras.map { "\($0.label) \(Int($0.usedPercent.rounded()))%" }.joined(separator: " · ")
    }

    /// Parse loadCodeAssist -> (cloudaicompanionProject, short plan label).
    static func parseLoadCodeAssist(_ data: Data) -> (project: String?, planLabel: String) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let project = root["cloudaicompanionProject"] as? String
        let paid = (root["paidTier"] as? [String: Any])?["name"] as? String
        let current = (root["currentTier"] as? [String: Any])?["name"] as? String
        return (project, planLabel(paid: paid, current: current))
    }

    private static func planLabel(paid: String?, current: String?) -> String {
        if let paid {
            if paid.contains("Ultra") { return "Ultra" }
            if paid.contains("Pro") { return "AI Pro" }
        }
        if let current { return current.replacingOccurrences(of: "Gemini ", with: "") }
        return "Code Assist"
    }

    private static let quotaReset: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    // MARK: - Network

    struct Client { let id: String; let secret: String; let scopes: String }

    static let cliClient = Client(
        id: "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com",
        secret: "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",
        scopes: "https://www.googleapis.com/auth/cloud-platform "
            + "https://www.googleapis.com/auth/userinfo.email "
            + "https://www.googleapis.com/auth/userinfo.profile")

    static let antigravityClient = Client(
        id: "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com",
        secret: "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",
        scopes: cliClient.scopes + " https://www.googleapis.com/auth/cclog "
            + "https://www.googleapis.com/auth/experimentsandconfigs")

    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let codeAssistBase = "https://cloudcode-pa.googleapis.com/v1internal"

    static func client(for surface: Surface) -> Client {
        surface == .cli ? cliClient : antigravityClient
    }

    private static func formEncode(_ s: String) -> String {
        var cs = CharacterSet.alphanumerics; cs.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
    }

    static func refreshRequest(refreshToken: String, client: Client) -> URLRequest {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let fields = ["grant_type": "refresh_token", "refresh_token": refreshToken,
                      "client_id": client.id, "client_secret": client.secret]
        req.httpBody = Data(fields.map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&").utf8)
        return req
    }

    private static func codeAssistRequest(method: String, accessToken: String,
                                          body: [String: Any]) -> URLRequest {
        var req = URLRequest(url: URL(string: "\(codeAssistBase):\(method)")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func loadCodeAssistRequest(accessToken: String) -> URLRequest {
        codeAssistRequest(method: "loadCodeAssist", accessToken: accessToken,
                          body: ["metadata": ["ideType": "IDE_UNSPECIFIED",
                                              "platform": "DARWIN_ARM64",
                                              "pluginType": "GEMINI"]])
    }

    static func quotaRequest(accessToken: String, project: String) -> URLRequest {
        codeAssistRequest(method: "retrieveUserQuota", accessToken: accessToken,
                          body: ["project": project])
    }

    /// Google refresh_token grant. Returns a fresh access token; Google does NOT
    /// rotate the refresh token, so the caller keeps the existing one.
    static func refresh(refreshToken: String, client: Client) async throws
        -> (accessToken: String, idToken: String?, expiryMs: Double) {
        let (data, resp) = try await URLSession.shared.data(for: refreshRequest(refreshToken: refreshToken, client: client))
        guard let http = resp as? HTTPURLResponse else { throw GeminiError.malformed }
        if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
            throw GeminiError.sessionExpired
        }
        guard http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String else { throw GeminiError.malformed }
        let expiresIn = (root["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return (access, root["id_token"] as? String,
                (Date().timeIntervalSince1970 + expiresIn) * 1000)
    }

    static func loadProject(accessToken: String) async throws -> (project: String?, planLabel: String) {
        let (data, resp) = try await URLSession.shared.data(for: loadCodeAssistRequest(accessToken: accessToken))
        guard let http = resp as? HTTPURLResponse else { throw GeminiError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw GeminiError.sessionExpired }
        if http.statusCode == 429 {
            let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageAPI.APIError.rateLimited(retryAfter: ra)
        }
        guard http.statusCode == 200 else { throw UsageAPI.APIError.http(http.statusCode) }
        return parseLoadCodeAssist(data)
    }

    static func fetchUsage(accessToken: String, project: String) async throws -> Usage {
        let (data, resp) = try await URLSession.shared.data(for: quotaRequest(accessToken: accessToken, project: project))
        guard let http = resp as? HTTPURLResponse else { throw GeminiError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw GeminiError.sessionExpired }
        if http.statusCode == 429 {
            let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageAPI.APIError.rateLimited(retryAfter: ra)
        }
        guard http.statusCode == 200 else { throw UsageAPI.APIError.http(http.statusCode) }
        return parseQuota(data)
    }
}

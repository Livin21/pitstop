import Foundation

struct UsageWindow: Codable, Equatable {
    let utilization: Double?
    let resetsAt: Date?
}

/// A per-model weekly limit ("Fable", …) from the limits array's
/// weekly_scoped entries. An independent cap: hitting it blocks only that
/// model, but per user preference it still counts toward the binding number.
struct ScopedWindow: Codable, Equatable {
    let label: String
    let window: UsageWindow
}

struct UsageReport: Codable, Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var scoped: [ScopedWindow] = []
    var extraUsageEnabled = false
    var extraUsageUtilization: Double?
    var fetchedAt = Date()

    /// The binding constraint — whichever window is closest to its limit.
    var maxUtilization: Double { bindingWindow?.utilization ?? 0 }

    /// The window driving `maxUtilization`, for reset-time display.
    /// First-wins on ties, so 5h beats 7d beats scoped at equal utilization.
    var bindingWindow: UsageWindow? {
        var best: UsageWindow?
        for w in [fiveHour, sevenDay].compactMap({ $0 }) + scoped.map(\.window)
        where best == nil || (w.utilization ?? 0) > (best?.utilization ?? 0) {
            best = w
        }
        return best
    }

    /// Auto-switch's filtered view: the max utilization over windows of the
    /// enabled kinds that report a number, or nil when none does — callers
    /// treat nil as "no trustworthy data" (never a trigger, never a target).
    func maxUtilization(kinds: Set<LimitKind>) -> Double? {
        var values: [Double] = []
        if kinds.contains(.session), let u = fiveHour?.utilization { values.append(u) }
        if kinds.contains(.weekly), let u = sevenDay?.utilization { values.append(u) }
        if kinds.contains(.perModel) { values += scoped.compactMap(\.window.utilization) }
        return values.max()
    }
}

enum UsageAPI {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    /// Claude Code's public OAuth client ID (PKCE public client — no secret).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    enum APIError: LocalizedError {
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case http(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Token rejected — re-login needed"
            case .rateLimited: return "Rate limited by Anthropic"
            case .http(let code): return "HTTP \(code) from Anthropic"
            case .malformed: return "Unexpected response format"
            }
        }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func fetchUsage(accessToken: String) async throws -> UsageReport {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw APIError.rateLimited(retryAfter: retryAfter)
        }
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode) }
        return try parse(data)
    }

    /// Parse a usage payload. The OAuth endpoint (`api.anthropic.com`) and the
    /// claude.ai web endpoint Claude Desktop uses return the same shape, so
    /// both fetch paths share this.
    static func parse(_ data: Data) throws -> UsageReport {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.malformed
        }
        var report = UsageReport()
        report.fiveHour = window(root["five_hour"])
        report.sevenDay = window(root["seven_day"])
        let limits = (root["limits"] as? [[String: Any]]) ?? []
        if report.fiveHour == nil { report.fiveHour = limitWindow(limits, kind: "session") }
        if report.sevenDay == nil { report.sevenDay = limitWindow(limits, kind: "weekly_all") }
        report.scoped = limits
            .filter { $0["kind"] as? String == "weekly_scoped" }
            .compactMap { entry in
                guard let w = limitWindow(entry) else { return nil }
                let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
                return ScopedWindow(label: model?["display_name"] as? String ?? "Scoped", window: w)
            }
        if let extra = root["extra_usage"] as? [String: Any] {
            report.extraUsageEnabled = (extra["is_enabled"] as? Bool) ?? false
            report.extraUsageUtilization = (extra["utilization"] as? NSNumber)?.doubleValue
        }
        return report
    }

    private static func window(_ any: Any?) -> UsageWindow? {
        guard let d = any as? [String: Any] else { return nil }
        let util = (d["utilization"] as? NSNumber)?.doubleValue
        var date: Date?
        if let s = d["resets_at"] as? String {
            date = isoFrac.date(from: s) ?? iso.date(from: s)
        }
        return UsageWindow(utilization: util, resetsAt: date)
    }

    /// A UsageWindow from a `limits[]` entry (percent + resets_at).
    private static func limitWindow(_ entry: [String: Any]) -> UsageWindow? {
        guard let pct = (entry["percent"] as? NSNumber)?.doubleValue else { return nil }
        var date: Date?
        if let s = entry["resets_at"] as? String {
            date = isoFrac.date(from: s) ?? iso.date(from: s)
        }
        return UsageWindow(utilization: pct, resetsAt: date)
    }

    private static func limitWindow(_ limits: [[String: Any]], kind: String) -> UsageWindow? {
        limits.first { $0["kind"] as? String == kind }.flatMap(limitWindow)
    }

    /// Standard OAuth refresh-token grant against Claude Code's public client.
    /// Used only for saved (inactive) profiles whose tokens have gone stale —
    /// the active account's tokens are kept fresh by Claude Code itself.
    static func refresh(refreshToken: String) async throws
        -> (accessToken: String, refreshToken: String?, expiresAtMs: Double) {
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
        guard let http = resp as? HTTPURLResponse else { throw APIError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 400 {
            throw APIError.unauthorized
        }
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String,
              let expiresIn = (root["expires_in"] as? NSNumber)?.doubleValue else {
            throw APIError.malformed
        }
        let expiresAtMs = (Date().timeIntervalSince1970 + expiresIn) * 1000
        return (access, root["refresh_token"] as? String, expiresAtMs)
    }

    // MARK: - Fresh login (authorization_code)

    /// Anthropic OAuth token hosts, tried in order — the current `platform`
    /// host first, then the legacy `console` host PitStop's refresh already
    /// uses. [verify] which accepts the authorization_code grant.
    static let authorizeTokenHosts: [URL] = [
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
    ]

    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// Build the authorization_code exchange request (JSON body, `state`
    /// included — the shape Claude Code uses). Pure, for testing.
    static func exchangeCodeRequest(code: String, state: String, verifier: String,
                                    redirectURI: String, host: URL) -> URLRequest {
        var req = URLRequest(url: host)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
        return req
    }

    /// Exchange an authorization code for tokens. The two hosts are tried only to
    /// discover which one serves this grant, so we fall through to the next host
    /// ONLY when this one can't have processed the code — a transport failure or
    /// a 404 (endpoint not on this host). Any other definitive response is
    /// authoritative and terminal: an authorization code is single-use, so we
    /// must not replay a possibly-consumed code against the other host. A reachable
    /// 400/401/403 is `.unauthorized`; any other non-200 surfaces as `.http`.
    static func exchangeCode(code: String, state: String, verifier: String,
                             redirectURI: String) async throws
        -> (accessToken: String, refreshToken: String?, expiresAtMs: Double) {
        var lastError: Error = APIError.malformed
        for host in authorizeTokenHosts {
            do {
                let req = exchangeCodeRequest(code: code, state: state, verifier: verifier,
                                              redirectURI: redirectURI, host: host)
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw APIError.malformed }
                if http.statusCode == 404 {
                    lastError = APIError.http(404); continue   // endpoint not here — try next host
                }
                if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
                    throw APIError.unauthorized
                }
                guard http.statusCode == 200 else { throw APIError.http(http.statusCode) }
                // A definitive 200 is terminal even if the body is junk —
                // JSONSerialization throwing here must NOT fall into the
                // transport-failure catch below and replay the consumed code.
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let access = root["access_token"] as? String,
                      let expiresIn = (root["expires_in"] as? NSNumber)?.doubleValue else {
                    throw APIError.malformed
                }
                let expiresAtMs = (Date().timeIntervalSince1970 + expiresIn) * 1000
                return (access, root["refresh_token"] as? String, expiresAtMs)
            } catch let error as APIError {
                // A definitive response from a reachable host is authoritative;
                // only transport failures (below) retry the next host.
                throw error
            } catch {
                lastError = error   // connection/DNS — try the next host
            }
        }
        throw lastError
    }

    /// Build the identity (profile) request. Pure, for testing.
    static func profileRequest(accessToken: String) -> URLRequest {
        var req = URLRequest(url: profileURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        return req
    }

    /// Parse the exact subscription identity returned by `/api/oauth/profile`.
    /// Email alone is not unique: one user may have personal and team orgs.
    static func parseAccountIdentity(_ data: Data) throws -> ClaudeAccountIdentity {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.malformed
        }
        let account = root["account"] as? [String: Any]
        let organization = root["organization"] as? [String: Any]
        guard let email = account?["email_address"] as? String
                ?? account?["email"] as? String
                ?? root["email_address"] as? String
                ?? root["email"] as? String,
              let organizationUUID = organization?["uuid"] as? String
                ?? root["organization_uuid"] as? String else {
            throw APIError.malformed
        }
        return ClaudeAccountIdentity(email: email, organizationUUID: organizationUUID)
    }

    /// Fetch the authenticated account and organization. Used to prevent a
    /// same-email token from being filed under the wrong Claude organization.
    static func fetchAccountIdentity(accessToken: String) async throws -> ClaudeAccountIdentity {
        let (data, resp) = try await URLSession.shared.data(for: profileRequest(accessToken: accessToken))
        guard let http = resp as? HTTPURLResponse else { throw APIError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized }
        guard http.statusCode == 200 else {
            throw APIError.http(http.statusCode)
        }
        return try parseAccountIdentity(data)
    }
}

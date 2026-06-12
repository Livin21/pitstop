import Foundation

struct UsageWindow {
    let utilization: Double?
    let resetsAt: Date?
}

struct UsageReport {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var sevenDayOpus: UsageWindow?
    var sevenDaySonnet: UsageWindow?
    var extraUsageEnabled = false
    var extraUsageUtilization: Double?
    var fetchedAt = Date()

    /// The binding constraint — whichever window is closest to its limit.
    var maxUtilization: Double {
        max(fiveHour?.utilization ?? 0, sevenDay?.utilization ?? 0)
    }

    /// The window driving `maxUtilization`, for reset-time display.
    var bindingWindow: UsageWindow? {
        (fiveHour?.utilization ?? 0) >= (sevenDay?.utilization ?? 0) ? fiveHour : sevenDay
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
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.malformed
        }

        var report = UsageReport()
        report.fiveHour = window(root["five_hour"])
        report.sevenDay = window(root["seven_day"])
        report.sevenDayOpus = window(root["seven_day_opus"])
        report.sevenDaySonnet = window(root["seven_day_sonnet"])
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
}

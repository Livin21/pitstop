import Foundation

/// Reads the OpenAI Codex account and its usage.
///
/// Codex (both the CLI and the Codex.app GUI) signs into ChatGPT and stores its
/// OAuth tokens in `~/.codex/auth.json`. On a given Mac the app and CLI share
/// that file (`CODEX_HOME=~/.codex`), so they're the same account — PitStop
/// shows it as one read-only row.
///
/// Usage comes from `chatgpt.com/backend-api/codex/usage`, a cheap metadata GET
/// (no model turn) that returns the account email, plan, and rate-limit windows
/// — each a `used_percent` + reset time, which map straight onto PitStop's bars.
///
/// Read-only: PitStop never writes `auth.json`. The access token is used as-is
/// (Codex keeps it fresh on use); if it's gone stale the row shows that.
enum Codex {
    /// The Codex account identity (no secrets).
    struct Account: Equatable {
        var email: String
        var planLabel: String
    }

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
    }

    enum CodexError: LocalizedError {
        case sessionExpired
        case malformed
        var errorDescription: String? {
            switch self {
            case .sessionExpired: return "Codex token expired — run `codex` to refresh"
            case .malformed: return "Unexpected Codex usage response"
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

    /// Fetch the Codex account and its usage. Returns nil when Codex isn't
    /// installed or isn't signed in with a ChatGPT account; throws (expired /
    /// rate-limited / malformed) when it is but the fetch fails.
    static func poll() async throws -> (account: Account, usage: Usage)? {
        guard let creds = readAuth() else { return nil }
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
        return try parse(data)
    }

    // MARK: - Parsing

    private static func parse(_ data: Data) throws -> (Account, Usage) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = root["email"] as? String else {
            throw CodexError.malformed
        }
        let plan = (root["plan_type"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let account = Account(email: email, planLabel: plan ?? "")

        var windows: [Usage.Window] = []
        if let rl = root["rate_limit"] as? [String: Any] {
            for key in ["primary_window", "secondary_window"] {
                if let w = window(rl[key]) { windows.append(w) }
            }
        }
        return (account, Usage(windows: windows))
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

    // MARK: - Auth file

    private struct Creds { var accessToken: String; var accountId: String }

    /// Read the ChatGPT access token + account id from `~/.codex/auth.json`.
    /// Returns nil for API-key auth or when not signed in (no usable token).
    private static func readAuth() -> Creds? {
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let account = tokens["account_id"] as? String else {
            return nil
        }
        return Creds(accessToken: access, accountId: account)
    }
}

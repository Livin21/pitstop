import Foundation

/// Proactively starts ("warms") a Claude 5-hour session so its reset lands
/// inside the user's day instead of at its end (spec:
/// docs/superpowers/specs/2026-07-16-session-warming-design.md). Warming
/// never raises or evades a cap — it only chooses when the session clock
/// starts, and the 1-token request spends from the same quota.
enum SessionWarmer {
    /// Cooldown between warm attempts per account, so a failed request or a
    /// not-yet-refreshed usage report can't cause hammering.
    static let attemptCooldown: TimeInterval = 600

    /// True when a warm should be attempted: the account has a 5-hour limit
    /// (Ultra accounts have none, so there is no session to start), local
    /// time-of-day inside the start-inclusive, end-exclusive window
    /// (wrap-around supported; an empty window never warms), no running
    /// session (resetsAt nil or past), and the per-account cooldown has passed.
    static func shouldWarm(now: Date, windowStartMinutes: Int, windowEndMinutes: Int,
                           resetsAt: Date?, lastAttempt: Date?,
                           noFiveHourLimit: Bool = false,
                           calendar: Calendar = .current) -> Bool {
        guard !noFiveHourLimit else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let t = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let inWindow = windowStartMinutes <= windowEndMinutes
            ? t >= windowStartMinutes && t < windowEndMinutes
            : t >= windowStartMinutes || t < windowEndMinutes
        guard inWindow else { return false }
        if let resetsAt, resetsAt > now { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < attemptCooldown {
            return false
        }
        return true
    }

    static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    /// [verify] Cheapest model the OAuth messages path accepts.
    static let model = "claude-haiku-4-5-20251001"
    /// [verify] OAuth-authenticated messages calls require Claude Code's
    /// system prompt.
    static let systemPrompt = "You are Claude Code, Anthropic's official CLI for Claude."

    /// The 1-token session-starting request. Any 2xx counts as warmed;
    /// the response body is discarded.
    static func warmRequest(accessToken: String) -> URLRequest {
        var req = URLRequest(url: messagesURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1,
            "system": systemPrompt,
            "messages": [["role": "user", "content": "hi"]],
        ])
        return req
    }

    /// Send the warm request. Silent by design — failures just retry after
    /// the cooldown; nothing is surfaced to the row display.
    static func warm(accessToken: String) async -> Bool {
        guard let (_, resp) = try? await URLSession.shared.data(
            for: warmRequest(accessToken: accessToken)),
            let http = resp as? HTTPURLResponse else { return false }
        return (200 ..< 300).contains(http.statusCode)
    }
}

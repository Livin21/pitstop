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

    /// True when a warm should be attempted: local time-of-day inside the
    /// start-inclusive, end-exclusive window (wrap-around supported; an
    /// empty window never warms), no running session (resetsAt nil or
    /// past), and the per-account cooldown has passed.
    static func shouldWarm(now: Date, windowStartMinutes: Int, windowEndMinutes: Int,
                           resetsAt: Date?, lastAttempt: Date?,
                           calendar: Calendar = .current) -> Bool {
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
}

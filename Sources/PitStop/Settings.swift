import Foundation

/// A limit window's kind, for the auto-switch "Trigger on" checkboxes.
/// Every provider's windows classify into one of these; see the
/// `maxUtilization(kinds:)` methods on each usage type.
enum LimitKind: CaseIterable {
    /// Short account-wide windows: Claude's 5-hour, Codex's 5h.
    case session
    /// Long account-wide windows: Claude's weekly, Codex's 7d/30d.
    case weekly
    /// Per-model caps: Claude's scoped limits (Fable, …), all Gemini quotas.
    case perModel
}

/// What the menu bar number tracks.
enum MenuBarSource: String, CaseIterable {
    /// The Claude Code account you're currently logged into (default).
    case activeClaudeCode
    /// Whichever account — any provider — is closest to its limit.
    case mostUrgent

    var label: String {
        switch self {
        case .activeClaudeCode: return "Active Claude Code account"
        case .mostUrgent: return "Most-used account (any provider)"
        }
    }
}

/// Typed access to the user's preferences (UserDefaults). The settings window
/// binds the same keys via `@AppStorage`; AppDelegate reads them here and
/// reacts to changes via KVO on `observedKeys`.
enum Settings {
    static var menuBarSource: MenuBarSource {
        UserDefaults.standard.string(forKey: "menuBarSource")
            .flatMap(MenuBarSource.init) ?? .activeClaudeCode
    }

    /// Auto-switch the active Claude Code account to the emptiest alternative
    /// when it crosses the threshold. Off by default — it's a surprising action.
    static var autoSwitchEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoSwitchEnabled")
    }

    /// Utilization (%) at which auto-switch kicks in. Default 90.
    static var autoSwitchThreshold: Int {
        let v = UserDefaults.standard.integer(forKey: "autoSwitchThreshold")
        return v == 0 ? 90 : v
    }

    /// Which limit kinds may trigger an auto-switch and rank its targets.
    /// Absent keys read as enabled, so the default is all kinds — today's
    /// behavior — and unchecking is the opt-out.
    static var autoSwitchKinds: Set<LimitKind> {
        func enabled(_ key: String) -> Bool {
            UserDefaults.standard.object(forKey: key) == nil
                ? true : UserDefaults.standard.bool(forKey: key)
        }
        var kinds: Set<LimitKind> = []
        if enabled("autoSwitchOnSession") { kinds.insert(.session) }
        if enabled("autoSwitchOnWeekly") { kinds.insert(.weekly) }
        if enabled("autoSwitchOnPerModel") { kinds.insert(.perModel) }
        return kinds
    }

    /// Show a "≈ full HH:MM at this pace" projection on rows trending toward a
    /// limit. On by default; only renders when the trend is meaningful.
    static var showProjection: Bool {
        UserDefaults.standard.object(forKey: "showProjection") == nil
            ? true : UserDefaults.standard.bool(forKey: "showProjection")
    }

    /// Keys AppDelegate watches to refresh the UI when settings change.
    static let observedKeys = [
        "indicatorStyle", "indicatorMetric", "menuBarSource",
        "autoSwitchEnabled", "autoSwitchThreshold", "showProjection",
        "autoSwitchOnSession", "autoSwitchOnWeekly", "autoSwitchOnPerModel",
    ]
}

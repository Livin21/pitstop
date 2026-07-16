import AppKit

/// What the menu bar item shows.
enum IndicatorStyle: String, CaseIterable {
    case iconAndPercent, iconOnly, percentOnly

    static var current: IndicatorStyle {
        UserDefaults.standard.string(forKey: "indicatorStyle")
            .flatMap(IndicatorStyle.init) ?? .iconAndPercent
    }

    var label: String {
        switch self {
        case .iconAndPercent: return "Icon & Percent"
        case .iconOnly: return "Icon Only"
        case .percentOnly: return "Percent Only"
        }
    }
}

/// Which limit drives the menu bar number and color.
enum IndicatorMetric: String, CaseIterable {
    case binding, fiveHour, weekly

    static var current: IndicatorMetric {
        UserDefaults.standard.string(forKey: "indicatorMetric")
            .flatMap(IndicatorMetric.init) ?? .binding
    }

    var label: String {
        switch self {
        case .binding: return "Highest Limit"
        case .fiveHour: return "5-Hour Limit"
        case .weekly: return "Weekly Limit"
        }
    }

    /// nil = the pinned window is absent from the report (shows as "–",
    /// not a misleading 0%).
    func utilization(of report: UsageReport) -> Double? {
        switch self {
        case .binding:
            let hasData = report.fiveHour?.utilization != nil
                || report.sevenDay?.utilization != nil
                || report.scoped.contains { $0.window.utilization != nil }
            return hasData ? report.maxUtilization : nil
        case .fiveHour: return report.fiveHour?.utilization
        case .weekly: return report.sevenDay?.utilization
        }
    }
}

/// A usage provider — the menu groups accounts under one section per provider.
/// Add a case (and its title) to extend PitStop to another service.
enum Provider: CaseIterable {
    case claude, codex, gemini
    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }
    /// The provider's web usage dashboard, opened from the section-header link.
    var dashboardURL: URL? {
        switch self {
        case .claude: return URL(string: "https://claude.ai/new#settings/usage")
        case .codex: return URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage")
        case .gemini: return URL(string: "https://gemini.google.com/usage")
        }
    }
}

/// One row in the menu. Within a provider, accounts merge by email — the same
/// Claude account signed into both Claude Code and Claude Desktop is one shared
/// usage pool, so one row. Across providers they don't: a Claude and a Codex
/// account can share an email yet be different services, so per-account state
/// is keyed by `key` (provider-namespaced), not bare email.
struct MenuAccount {
    enum Source { case code, desktop, both, codex, geminiCli, geminiAntigravity, geminiBoth }
    var email: String
    var source: Source
    var planLabel: String
    var isActive: Bool

    var isCodex: Bool { source == .codex }
    var isGemini: Bool {
        switch source { case .geminiCli, .geminiAntigravity, .geminiBoth: return true; default: return false }
    }
    var provider: Provider {
        if isCodex { return .codex }
        if isGemini { return .gemini }
        return .claude
    }
    /// Switchable providers: Claude Code (owns the live credential keychain
    /// item) and Codex (owns ~/.codex/auth.json). Desktop is observe-only — its
    /// login lives in that app. The live account of each is filtered out by the
    /// `!isActive` guard at the call site (it's already current).
    var canSwitch: Bool {
        switch source {
        case .code, .both, .codex, .geminiCli, .geminiAntigravity, .geminiBoth: return true
        case .desktop: return false
        }
    }
    /// Storage key for usage/error/backoff dicts — namespaced by provider so a
    /// Claude and a Codex account with the same email don't collide.
    var key: String {
        if isCodex { return "codex:\(email)" }
        if isGemini { return "gemini:\(email)" }
        return email
    }
    /// Which surface within the provider — shown as a small tag, since the
    /// provider itself is now the section header. Codex has one surface (the
    /// CLI and app share a login), so it needs none.
    var surfaceTag: String? {
        switch source {
        case .code: return "Code"
        case .both: return "Code · Desktop"   // switchable, and the Desktop login
        case .desktop: return "Desktop"
        case .codex: return nil
        case .geminiCli: return "CLI"
        case .geminiAntigravity: return "Antigravity"
        case .geminiBoth: return "CLI · Antigravity"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let settingsWindow = SettingsWindowController()
    private var timer: Timer?
    /// One-shot retry scheduled for the earliest backoff expiry, so a
    /// rate-limited account doesn't wait out the rest of a 2-min tick.
    private var backoffTimer: Timer?

    private let store = ProfileStore()
    private var activeEmail: String?
    /// The account Claude Desktop is logged into, if any (read-only — PitStop
    /// can show its usage but can't switch it). Discovered on each refresh.
    private var desktopAccount: ClaudeDesktop.Account?
    /// Saved OpenAI Codex accounts (CLI + app share `~/.codex/auth.json`).
    /// Switchable like Claude Code, but the live store is that file.
    private let codexStore = CodexStore()
    /// The email currently live in `~/.codex/auth.json`.
    private var codexLiveEmail: String?
    /// Codex usage, keyed by the codex storage key ("codex:<email>").
    private var codexUsage: [String: Codex.Usage] = [:]
    /// Saved Gemini accounts — snapshots of the CLI and Antigravity live surfaces.
    private let geminiStore = GeminiStore()
    /// The email currently live in the Gemini CLI surface.
    private var geminiLiveCliEmail: String?
    /// The email currently live in the Gemini Antigravity surface.
    private var geminiLiveAntigravityEmail: String?
    /// Gemini usage, keyed by the gemini storage key ("gemini:<email>").
    private var geminiUsage: [String: Gemini.Usage] = [:]
    /// Resolved cloudaicompanionProject per email (cached to avoid re-fetching).
    private var geminiProject: [String: String] = [:]
    /// Recent (time, binding-utilization) samples per account key, for the
    /// time-to-limit projection. In-memory only; cleared on a window reset.
    private var usageHistory: [String: [(date: Date, util: Double)]] = [:]
    /// When PitStop last auto-switched each provider, to avoid flapping.
    private var lastAutoSwitch: [Provider: Date] = [:]
    /// Last successful report per account — kept on fetch failure so the
    /// display degrades to stale data instead of going blank.
    private var usage: [String: UsageReport] = [:]
    private var fetchError: [String: String] = [:]
    /// Keys whose error needs the user to act (re-auth / switch) rather than
    /// just waiting — so the row doesn't promise a "retrying in …" that can't
    /// actually recover on its own.
    private var needsAction: Set<String> = []
    /// Backoff: don't hit the endpoint for this account before this date.
    private var nextFetchAllowed: [String: Date] = [:]
    private var failureCount: [String: Int] = [:]
    private var lastRefresh: Date?
    private var lastTopLevelError: String?
    /// A newer GitHub release than the running build, if one was found.
    private var updateInfo: Updater.UpdateInfo?
    /// When the GitHub Releases check last ran (throttled to once a day).
    private var lastUpdateCheck: Date?
    private var refreshing = false
    /// An explicit Refresh Now arrived while a refresh was in flight.
    private var refreshQueued = false
    /// Tail of the credential-operation chain. Refresh cycles and account
    /// switches/saves read-modify-write the live credential stores across
    /// many suspension points (each keychain call is a subprocess); run
    /// concurrently, a switch landing mid-capture pairs one account's tokens
    /// with another account's identity. Chaining makes them mutually exclusive.
    private var credentialOps: Task<Void, Never>?
    /// True while an OAuth re-login is running (prevents overlapping logins).
    private var loginInFlight = false
    private let pasteWindow = LoginPasteWindowController()

    private var isMenuOpen = false
    /// The menu got in-place updates while open; rebuild on close to re-sort.
    private var menuNeedsRebuildOnClose = false
    /// The account rows currently in the menu, for in-place refresh
    /// (keyed by the account's provider-namespaced storage key).
    private var accountRows: [(key: String, view: AccountRowView)] = []
    private var updatedItem: NSMenuItem?

    /// 0 = below 80%, 1 = ≥80%, 2 = ≥95% — to notify once per crossing.
    private var notifiedBucket: [String: Int] = [:]

    private let refreshInterval: TimeInterval = 120
    /// Don't re-fetch on menu open if data is younger than this.
    private let menuRefreshDebounce: TimeInterval = 30

    /// `--screenshot` renders sample addresses in place of real emails
    /// everywhere the UI shows one, for README captures (docs/menu.png).
    /// Run: /Applications/PitStop.app/Contents/MacOS/PitStop --screenshot
    private let maskEmails = CommandLine.arguments.contains("--screenshot")

    /// Every distinct account email PitStop knows — saved Code profiles plus
    /// a Desktop-only account — for stable masking and iteration.
    private func allEmails() -> [String] {
        var emails = store.profiles.map(\.email)
        if let d = desktopAccount, !emails.contains(d.email) { emails.append(d.email) }
        for c in codexStore.profiles where !emails.contains(c.email) { emails.append(c.email) }
        for g in geminiStore.profiles where !emails.contains(g.email) { emails.append(g.email) }
        return emails
    }

    private func displayEmail(_ email: String) -> String {
        guard maskEmails else { return email }
        let masks = ["asha@work.com", "personal@example.com", "side@example.com"]
        let i = allEmails().sorted().firstIndex(of: email) ?? 0
        return i < masks.count ? masks[i] : "account\(i + 1)@example.com"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        updateStatusTitle()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        buildMenu()
        refreshAll()

        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        t.tolerance = 10
        // .common so the timer still fires while the menu is open.
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // React to changes made in the Settings window.
        for key in Settings.observedKeys {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: [], context: nil)
        }
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?,
                                           context: UnsafeMutableRawPointer?) {
        Task { @MainActor [weak self] in self?.applySettings() }
    }

    /// A preference changed — re-render the menu bar and (closed) menu.
    private func applySettings() {
        updateStatusTitle()
        if isMenuOpen { _ = refreshOpenMenuInPlace() } else { buildMenu() }
    }

    // MARK: - Refresh

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Menu shows cached data instantly; only re-fetch if it's gone stale.
        // An expired backoff bypasses the debounce — a retry is overdue
        // (e.g. right after wake, before any timer has fired).
        let retryDue = nextFetchAllowed.values.contains { $0 <= Date() }
        if !retryDue, let last = lastRefresh,
           Date().timeIntervalSince(last) < menuRefreshDebounce {
            return
        }
        refreshAll()
    }

    @objc func refreshNow(_ sender: Any?) {
        // Explicit refresh clears any backoff — the user asked for it.
        nextFetchAllowed.removeAll()
        geminiProject.removeAll()   // re-resolve — Code Assist may have been enabled since
        refreshAll()
    }

    /// Run `op` after every previously enqueued credential operation finishes.
    private func serializedCredentialOp(_ op: @escaping @MainActor () async -> Void) {
        let previous = credentialOps
        credentialOps = Task { @MainActor in
            await previous?.value
            await op()
        }
    }

    private func refreshAll() {
        guard !refreshing else { refreshQueued = true; return }
        refreshing = true
        serializedCredentialOp { [self] in
            defer {
                refreshing = false
                if refreshQueued {
                    refreshQueued = false
                    refreshAll()
                }
            }
            lastTopLevelError = nil

            // Keep the saved copy of the live account in sync.
            do {
                let capture = try await store.captureCurrent()
                if capture.changed, let email = capture.profile?.email {
                    credentialsRenewed(for: email)
                }
            } catch {
                lastTopLevelError = error.localizedDescription
            }
            store.load()
            activeEmail = ClaudeConfig.activeEmail()

            for profile in store.profiles where passedBackoffGate(profile.email) {
                let email = profile.email
                do {
                    let creds = try await freshCredentials(for: email,
                                                           isActive: email == activeEmail)
                    // Self-heal installs poisoned before capture-time
                    // verification existed: a row whose credentials belong to
                    // another account gets gated instead of double-reporting
                    // that account's usage. Active row excluded — its token is
                    // the live item's, not the saved copy the audit deletes
                    // (captureCurrent's verification polices the live pair,
                    // and a verified capture overwrites a foreign saved copy).
                    if email != activeEmail,
                       case .poisoned(let owner) = await store.auditIdentity(
                        email: email, accessToken: creds.accessToken) {
                        usage[email] = nil
                        recordFetchError(ProfileStore.ForeignCredentialsError(owner: owner),
                                         for: email)
                        continue
                    }
                    let report = try await UsageAPI.fetchUsage(accessToken: creds.accessToken)
                    recordFetchSuccess(report, for: email)
                } catch {
                    recordFetchError(error, for: email)
                }
            }

            await refreshDesktopAccount()
            await refreshCodexAccount()
            await refreshGeminiAccount()

            lastRefresh = Date()
            recordUsageSamples()
            pruneOrphanedState()
            updateStatusTitle()
            if !(isMenuOpen && refreshOpenMenuInPlace()) {
                buildMenu()
            }
            checkThresholds()
            evaluateAutoSwitch()
            scheduleBackoffRetry()
            checkForUpdatesIfDue()
        }
    }

    /// Check GitHub Releases at most once a day; reflect the result in the menu.
    private func checkForUpdatesIfDue() {
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 86400 { return }
        lastUpdateCheck = Date()
        Task { @MainActor in
            let info = await Updater.checkForUpdate()
            guard info != updateInfo else { return }
            updateInfo = info
            if isMenuOpen { menuNeedsRebuildOnClose = true } else { buildMenu() }
        }
    }

    /// True if `email` is clear to fetch. A future-dated backoff returns false
    /// (keep showing stale data); a passed gate is cleared so entries are
    /// always future-dated or absent — `menuNeedsUpdate`'s retryDue check
    /// relies on that.
    private func passedBackoffGate(_ email: String) -> Bool {
        if let notBefore = nextFetchAllowed[email] {
            if Date() < notBefore { return false }
            nextFetchAllowed[email] = nil
        }
        return true
    }

    /// The stored credentials for `key` were externally replaced (a re-login
    /// or the provider's own refresh). If the account was gated needs-action,
    /// the new credentials are exactly the fix — clear the gate so this cycle
    /// fetches instead of waiting out the hour. Rate-limit backoffs stay.
    private func credentialsRenewed(for key: String) {
        guard needsAction.contains(key) else { return }
        clearFetchError(for: key)
    }

    /// Clear the error/backoff state for a key after a successful fetch.
    private func clearFetchError(for key: String) {
        fetchError[key] = nil
        failureCount[key] = 0
        nextFetchAllowed[key] = nil
        needsAction.remove(key)
    }

    private func recordFetchSuccess(_ report: UsageReport, for email: String) {
        usage[email] = report
        clearFetchError(for: email)
    }

    /// Translate a fetch failure into the stale-display state for `email`,
    /// shared by the Code (OAuth) and Desktop (claude.ai) fetch paths.
    private func recordFetchError(_ error: Error, for email: String) {
        let fails = (failureCount[email] ?? 0) + 1
        failureCount[email] = fails
        switch error {
        case UsageAPI.APIError.rateLimited(let retryAfter):
            // Respect Retry-After; otherwise exponential backoff
            // 2 min → 4 min → … capped at 15 min. Retry timing is rendered
            // from nextFetchAllowed at display time so it never goes stale.
            let delay = retryAfter ?? min(120 * pow(2, Double(fails - 1)), 900)
            nextFetchAllowed[email] = Date().addingTimeInterval(delay)
            fetchError[email] = "Rate limited"
            needsAction.remove(email)
        case UsageAPI.APIError.unauthorized,
             ClaudeDesktop.DesktopError.sessionExpired,
             Codex.CodexError.sessionExpired,
             Gemini.GeminiError.sessionExpired,
             is ProfileStore.ForeignCredentialsError:
            // A rejected token/session won't heal on its own — don't hammer
            // the endpoint every cycle. Refresh Now (or a re-login noticed on
            // the next pass) clears this. It needs the user to act, so the row
            // shows the message without a misleading "retrying in …".
            nextFetchAllowed[email] = Date().addingTimeInterval(3600)
            fetchError[email] = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            needsAction.insert(email)
        default:
            fetchError[email] = error.localizedDescription
            needsAction.remove(email)
        }
    }

    /// Discover the Claude Desktop account and fetch its usage. Best-effort:
    /// a missing/not-signed-in Desktop just clears the account; a fetch error
    /// keeps the last-known identity and shows the error on its row.
    ///
    /// For an account that's *also* a saved Code profile, the Code (OAuth) path
    /// is the usual usage source — but if that fetch failed this cycle (e.g. a
    /// rejected token), fall back to the healthy Desktop session here instead of
    /// discarding it and leaving the Code error on the merged row.
    private func refreshDesktopAccount() async {
        let knownEmail = desktopAccount?.email
        // Normally skip while the email's backoff is active — except when a
        // same-email Code profile errored this cycle: that backoff is the Code
        // failure's, and Desktop is a separate session worth trying as a fallback
        // (its own state is shared on this key, so the shared backoff is Code's).
        let codeErrored = knownEmail.map { email in
            store.profiles.contains(where: { $0.email == email }) && fetchError[email] != nil
        } ?? false
        guard codeErrored || (knownEmail.map(passedBackoffGate) ?? true) else { return }
        do {
            guard let (account, report) = try await ClaudeDesktop.poll() else {
                desktopAccount = nil
                return
            }
            desktopAccount = account
            // Record Desktop usage when no Code profile covers this email; when
            // one does but its Code fetch failed this cycle, refresh the numbers
            // from the healthy Desktop session WITHOUT clearing the Code error,
            // backoff, or needs-action state — the Code credentials are still
            // broken, and clearing the gate here would retry the dead refresh
            // token every cycle and hide the re-login affordance.
            if !store.profiles.contains(where: { $0.email == account.email }) {
                recordFetchSuccess(report, for: account.email)
            } else if fetchError[account.email] != nil {
                usage[account.email] = report
            }
        } catch {
            // Keep the last-known identity so the row doesn't flicker out;
            // surface the error on it (unless a Code profile owns the email).
            if let email = knownEmail,
               !store.profiles.contains(where: { $0.email == email }) {
                recordFetchError(error, for: email)
            }
        }
    }

    /// Snapshot the live Codex account, then fetch usage for every saved Codex
    /// account — refreshing an inactive account's token if it has aged out
    /// (Codex keeps only the live one fresh). Best-effort, mirroring Claude.
    private func refreshCodexAccount() async {
        guard Codex.isPresent else { return }
        do {
            let capture = try await codexStore.captureCurrent()
            if capture.changed, let email = capture.profile?.email {
                credentialsRenewed(for: "codex:\(email)")
            }
        } catch {
            lastTopLevelError = error.localizedDescription
        }
        codexStore.load()
        codexLiveEmail = codexStore.liveEmail()

        for profile in codexStore.profiles {
            let key = "codex:\(profile.email)"
            guard passedBackoffGate(key) else { continue }
            let isLive = profile.email == codexLiveEmail
            do {
                codexUsage[key] = try await fetchCodexUsage(for: profile.email, isActive: isLive)
                clearFetchError(for: key)
            } catch {
                recordFetchError(error, for: key)
                // An inactive account only reaches the expired state when its
                // refresh token is itself dead — it needs a re-login. (The live
                // account's stale token is shown neutrally in rowModel; Codex
                // refreshes it itself.)
                if case Codex.CodexError.sessionExpired = error, !isLive {
                    fetchError[key] = "Codex session ended — sign in to Codex again"
                }
            }
        }
    }

    /// Fetch one Codex account's usage, refreshing its token on a 401 and
    /// retrying once. Only inactive accounts are refreshed — Codex owns the
    /// live one, so PitStop never rewrites the live `auth.json` here; the
    /// rotated tokens are persisted to the saved snapshot for the next fetch
    /// and any later switch. After a refresh the persisted token is fresh, so
    /// it won't re-refresh until it genuinely expires (~hourly), not every cycle.
    private func fetchCodexUsage(for email: String, isActive: Bool) async throws -> Codex.Usage {
        guard let blob = try await codexStore.blob(for: email, isActive: isActive),
              let creds = Codex.credentials(from: blob) else {
            throw Codex.CodexError.sessionExpired
        }
        do {
            return try await Codex.fetchUsage(creds)
        } catch Codex.CodexError.sessionExpired where !isActive {
            // Inactive token aged out — rotate it and retry once.
            guard let refreshToken = creds.refreshToken else {
                throw Codex.CodexError.sessionExpired
            }
            let refreshed = try await Codex.refresh(refreshToken: refreshToken)
            guard let patched = Codex.patching(blob, with: refreshed),
                  let fresh = Codex.credentials(from: patched) else {
                throw Codex.CodexError.malformed
            }
            try await codexStore.storeRefreshedBlob(patched, email: email)
            return try await Codex.fetchUsage(fresh)
        }
    }

    /// Snapshot the live Gemini surfaces, then fetch the shared Code Assist usage
    /// for each saved account (refreshing an inactive token if it has aged out).
    private func refreshGeminiAccount() async {
        let hasCli = FileManager.default.fileExists(atPath: GeminiStore.cliCredsURL.path)
        let hasAntigravity = await geminiStore.liveAntigravityBlob() != nil
        guard hasCli || hasAntigravity else { return }
        do {
            for email in try await geminiStore.captureCurrent() {
                credentialsRenewed(for: "gemini:\(email)")
            }
        } catch { lastTopLevelError = error.localizedDescription }
        geminiStore.load()
        geminiLiveCliEmail = geminiStore.liveCliEmail()
        geminiLiveAntigravityEmail = await geminiStore.liveAntigravityEmail()

        for profile in geminiStore.profiles {
            let key = "gemini:\(profile.email)"
            guard passedBackoffGate(key) else { continue }
            let isActive = profile.email == geminiLiveCliEmail || profile.email == geminiLiveAntigravityEmail
            do {
                let usage = try await fetchGeminiUsage(for: profile.email, isActive: isActive)
                geminiUsage[key] = usage
                clearFetchError(for: key)
            } catch {
                recordFetchError(error, for: key)
                if case Gemini.GeminiError.sessionExpired = error, !isActive {
                    fetchError[key] = "Session expired — sign in to Gemini again"
                }
            }
        }
    }

    /// Fetch one Gemini account's usage, refreshing its token in memory and
    /// (for inactive accounts) persisting the rotated access token.
    private func fetchGeminiUsage(for email: String, isActive: Bool) async throws -> Gemini.Usage {
        // Prefer the CLI surface; fall back to Antigravity.
        let surface: Gemini.Surface = geminiStore.profiles.first(where: { $0.email == email })?.onCli == true ? .cli : .antigravity
        guard let blob = try await geminiStore.blob(for: email, surface: surface, isActive: isActive),
              let creds = (surface == .cli ? Gemini.cliCreds(from: blob) : Gemini.antigravityCreds(from: blob)) else {
            throw Gemini.GeminiError.sessionExpired
        }
        var accessToken = creds.accessToken
        // Refresh in memory if expired (Google refresh tokens don't rotate).
        if creds.expiryMs <= Date().timeIntervalSince1970 * 1000, let rt = creds.refreshToken {
            let fresh = try await Gemini.refresh(refreshToken: rt, client: Gemini.client(for: surface))
            accessToken = fresh.accessToken
            if !isActive {
                let expiryISO = Gemini.iso8601.string(from: Date(timeIntervalSince1970: fresh.expiryMs / 1000))
                let idToken = fresh.idToken ?? creds.idToken
                let rebuilt: Data = surface == .cli
                    ? Gemini.patchCliBlob(blob, access: fresh.accessToken,
                                          idToken: idToken, expiryMs: fresh.expiryMs)
                      ?? GeminiStore.buildCliBlob(access: fresh.accessToken, refresh: rt,
                                                  idToken: idToken, expiryMs: fresh.expiryMs)
                    : Gemini.patchAntigravityBlob(blob, access: fresh.accessToken,
                                                  idToken: idToken, expiryISO: expiryISO)
                      ?? GeminiStore.buildAntigravityBlob(access: fresh.accessToken, refresh: rt,
                                                          idToken: idToken, expiryISO: expiryISO)
                try await geminiStore.storeRefreshedBlob(rebuilt, email: email, surface: surface)
            }
        }
        // Resolve + cache the cloudaicompanionProject.
        if geminiProject[email] == nil {
            let r = try await Gemini.loadProject(accessToken: accessToken)
            if let p = r.project {
                geminiProject[email] = p
            } else {
                geminiProject[email] = ""   // sentinel: signed in but no Code Assist project
            }
            geminiStore.setPlanLabel(r.planLabel, email: email)
        }
        let cachedProject = geminiProject[email]
        if cachedProject == "" { throw Gemini.GeminiError.noProject }
        guard let project = cachedProject else { throw Gemini.GeminiError.notSignedIn }
        return try await Gemini.fetchUsage(accessToken: accessToken, project: project)
    }

    /// Schedule a one-shot refresh for when the earliest active backoff
    /// expires, instead of letting the account idle until the next 2-min
    /// tick. Floored at 10 s so a tiny Retry-After can't turn into a hot
    /// retry loop.
    private func scheduleBackoffRetry() {
        backoffTimer?.invalidate()
        backoffTimer = nil
        guard let earliest = nextFetchAllowed.values.filter({ $0 > Date() }).min() else { return }
        let fireIn = max(earliest.timeIntervalSinceNow + 1, 10)
        guard fireIn < refreshInterval else { return }  // regular tick covers it
        let t = Timer(timeInterval: fireIn, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        RunLoop.main.add(t, forMode: .common)
        backoffTimer = t
    }

    /// Update the rows of the open menu without rebuilding it, so hover
    /// state and open submenus survive the periodic refresh. Row order is
    /// frozen until the menu closes (no shuffling under the cursor); a
    /// rebuild on close re-sorts. Returns false when the row set or row
    /// heights changed — the caller falls back to a full rebuild.
    private func refreshOpenMenuInPlace() -> Bool {
        let sorted = orderedAccounts()
        guard sorted.count == accountRows.count else { return false }
        let models = sorted.map(rowModel(for:))
        // Keyed by the account's storage key, not its display email (which may
        // be masked with --screenshot, or shared across providers).
        let current = Dictionary(uniqueKeysWithValues: accountRows.map { ($0.key, $0.view) })
        for (account, model) in zip(sorted, models) {
            guard let view = current[account.key],
                  AccountRowView.height(for: model) == view.frame.height else { return false }
        }
        for (account, model) in zip(sorted, models) {
            current[account.key]?.apply(model)
        }
        if let lastRefresh {
            updatedItem?.attributedTitle = detailText(
                "Updated \(Format.updated.string(from: lastRefresh)) · refreshes every 2 min")
        }
        menuNeedsRebuildOnClose = true
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        if menuNeedsRebuildOnClose {
            menuNeedsRebuildOnClose = false
            // Async so the clicked item (if any) delivers its action before
            // the menu is torn down.
            DispatchQueue.main.async { [weak self] in self?.buildMenu() }
        }
    }

    /// Returns non-expired credentials for a profile, refreshing via the
    /// OAuth refresh grant (and persisting the result) when needed.
    private func freshCredentials(for email: String, isActive: Bool) async throws -> OAuthCredentials {
        guard let blob = try await store.blob(for: email, isActive: isActive) else {
            throw ProfileStore.StoreError(message: "No stored credentials")
        }
        var creds = try CredentialBlob.parse(blob)
        guard creds.isExpired else { return creds }
        guard let refreshToken = creds.refreshToken else {
            throw UsageAPI.APIError.unauthorized
        }
        let fresh = try await UsageAPI.refresh(refreshToken: refreshToken)
        let patched = try CredentialBlob.patching(blob,
                                                  accessToken: fresh.accessToken,
                                                  refreshToken: fresh.refreshToken,
                                                  expiresAtMs: fresh.expiresAtMs)
        try await store.storeRefreshedBlob(patched, email: email, isActive: isActive)
        creds.accessToken = fresh.accessToken
        creds.refreshToken = fresh.refreshToken ?? creds.refreshToken
        creds.expiresAtMs = fresh.expiresAtMs
        return creds
    }

    // MARK: - Status item

    private let statusSymbol = NSImage(systemSymbolName: "flag.checkered",
                                       accessibilityDescription: "Claude Code usage")
        ?? NSImage(systemSymbolName: "gauge.with.needle",
                   accessibilityDescription: "Claude Code usage")

    /// What the menu bar item should display this tick.
    private struct MenuBarReading {
        var pct: Int?       // nil → "–" (no data)
        var isStale: Bool
        var tip: String
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let style = IndicatorStyle.current
        button.image = style == .percentOnly ? nil : statusSymbol
        // macOS repaints menu bar items in a single wallpaper-matched "ink"
        // color: explicitly colored text, tinted/non-template images, custom
        // button.font, and appearsDisabled all drop out of that pipeline and
        // get flattened to an unreadable mid-gray. Only plain-title text (the
        // ink adapts it) and emoji glyphs (which keep their color) survive —
        // so warnings are emoji dots and staleness dims via alphaValue.
        button.contentTintColor = nil
        let reading = menuBarReading()
        button.toolTip = reading.tip
        guard let pct = reading.pct else {
            button.alphaValue = 1
            button.title = style == .iconOnly ? "" : " –"
            return
        }
        let dot = reading.isStale ? "" : (pct >= 90 ? "\u{2009}🔴" : (pct >= 75 ? "\u{2009}🟠" : ""))
        button.alphaValue = reading.isStale ? 0.55 : 1
        button.title = (style == .iconOnly ? "" : " \(pct)%") + dot
    }

    /// Pick the account the menu bar tracks, per the `menuBarSource` setting.
    private func menuBarReading() -> MenuBarReading {
        switch Settings.menuBarSource {
        case .activeClaudeCode:
            guard let email = activeEmail, let report = usage[email] else {
                let tip = activeEmail.flatMap { fetchError[$0] } ?? "PitStop — no usage data yet"
                return MenuBarReading(pct: nil, isStale: false, tip: tip)
            }
            let util = IndicatorMetric.current.utilization(of: report)
            return MenuBarReading(pct: util.map { Int($0.rounded()) },
                                  isStale: fetchError[email] != nil,
                                  tip: statusTip(email: email, report: report))
        case .mostUrgent:
            // Highest binding utilization across every account that has data.
            var best: (name: String, util: Double, stale: Bool)?
            func consider(_ key: String, _ name: String, _ util: Double) {
                if best == nil || util > best!.util {
                    best = (name, util, fetchError[key] != nil)
                }
            }
            for (key, report) in usage { consider(key, displayEmail(key), report.maxUtilization) }
            for (key, cu) in codexUsage {
                let email = String(key.dropFirst("codex:".count))
                consider(key, "\(displayEmail(email)) (Codex)", cu.maxUtilization)
            }
            for (key, gu) in geminiUsage {
                let email = String(key.dropFirst("gemini:".count))
                consider(key, "\(displayEmail(email)) (Gemini)", gu.maxUtilization)
            }
            guard let best else {
                return MenuBarReading(pct: nil, isStale: false, tip: "PitStop — no usage data yet")
            }
            let pct = Int(best.util.rounded())
            return MenuBarReading(pct: pct, isStale: best.stale,
                                  tip: "Most used: \(best.name) — \(pct)%")
        }
    }

    private func statusTip(email: String, report: UsageReport) -> String {
        var tip = "\(displayEmail(email))\n5-hour \(Format.percent(report.fiveHour?.utilization))"
            + " · weekly \(Format.percent(report.sevenDay?.utilization))"
        for s in report.scoped {
            tip += " · \(s.label) \(Format.percent(s.window.utilization))"
        }
        if let err = fetchError[email] {
            tip += "\n⚠️ \(err) — showing data from \(Format.updated.string(from: report.fetchedAt))"
        }
        return tip
    }

    // MARK: - Menu

    /// All rows to show — saved Code profiles, a Desktop-only Claude account,
    /// and the Codex account. A Claude account on both Code and Desktop merges
    /// into one row tagged `.both`; Codex is always its own row (different
    /// provider, even when it shares an email).
    private func accountsForMenu() -> [MenuAccount] {
        var rows = store.profiles.map { profile -> MenuAccount in
            let onDesktop = desktopAccount?.email == profile.email
            return MenuAccount(email: profile.email,
                               source: onDesktop ? .both : .code,
                               planLabel: profile.planLabel,
                               isActive: profile.email == activeEmail)
        }
        if let d = desktopAccount,
           !store.profiles.contains(where: { $0.email == d.email }) {
            rows.append(MenuAccount(email: d.email, source: .desktop,
                                    planLabel: d.planLabel, isActive: false))
        }
        for c in codexStore.profiles {
            rows.append(MenuAccount(email: c.email, source: .codex,
                                    planLabel: c.planLabel,
                                    isActive: c.email == codexLiveEmail))
        }
        for p in geminiStore.profiles {
            let source = Self.geminiSource(onCli: p.onCli, onAntigravity: p.onAntigravity)
            let active = p.email == geminiLiveCliEmail || p.email == geminiLiveAntigravityEmail
            rows.append(MenuAccount(email: p.email, source: source, planLabel: p.planLabel, isActive: active))
        }
        return rows
    }

    /// The headroom (max window utilization) for an account, from whichever
    /// provider's usage store holds it. 999 = unknown, so it sorts last.
    private func headroom(_ account: MenuAccount) -> Double {
        if account.isCodex { return codexUsage[account.key]?.maxUtilization ?? 999 }
        if account.isGemini { return geminiUsage[account.key]?.maxUtilization ?? 999 }
        return usage[account.key]?.maxUtilization ?? 999
    }

    /// Accounts grouped into one section per provider, in `Provider.allCases`
    /// order; within a section, live account first, then by headroom (emptiest
    /// next). Empty providers are dropped.
    private func groupedAccounts() -> [(provider: Provider, accounts: [MenuAccount])] {
        let all = accountsForMenu()
        return Provider.allCases.compactMap { provider in
            let accounts = all
                .filter { $0.provider == provider }
                .sorted { a, b in
                    if a.isActive != b.isActive { return a.isActive }
                    return headroom(a) < headroom(b)
                }
            return accounts.isEmpty ? nil : (provider, accounts)
        }
    }

    /// The rows in display order, flattened across provider groups — for the
    /// in-place refresh, which must line up 1:1 with `accountRows`.
    private func orderedAccounts() -> [MenuAccount] {
        groupedAccounts().flatMap(\.accounts)
    }

    private func buildMenu() {
        menu.removeAllItems()
        accountRows = []
        updatedItem = nil

        let groups = groupedAccounts()
        if groups.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Usage"))
            addDisabled("No accounts found — log in with `claude` first")
        }
        // One section per provider; rows in each carry a surface tag (Code /
        // Desktop) since the provider name is now the header.
        for group in groups {
            if let url = group.provider.dashboardURL {
                let header = NSMenuItem()
                header.view = SectionHeaderView(title: group.provider.title) {
                    NSWorkspace.shared.open(url)
                }
                menu.addItem(header)
            } else {
                menu.addItem(NSMenuItem.sectionHeader(title: group.provider.title))
            }
            for account in group.accounts {
                let item = NSMenuItem()
                let view = AccountRowView(model: rowModel(for: account))
                item.view = view
                menu.addItem(item)
                accountRows.append((account.key, view))
            }
        }

        menu.addItem(.separator())

        let save = NSMenuItem(title: "Save Current Account",
                              action: #selector(saveCurrent(_:)), keyEquivalent: "s")
        save.target = self
        menu.addItem(save)

        // Removable = saved accounts that aren't the live one of their provider.
        // Titles carry a "· Codex" tag so a Claude and a Codex account sharing
        // an email are distinguishable; the represented object is the
        // provider-namespaced key the remove action routes on.
        var removable: [(title: String, key: String)] = store.profiles
            .filter { $0.email != activeEmail }
            .map { (displayEmail($0.email), $0.email) }
        removable += codexStore.profiles
            .filter { $0.email != codexLiveEmail }
            .map { ("\(displayEmail($0.email)) · Codex", "codex:\($0.email)") }
        removable += geminiStore.profiles
            .filter { $0.email != geminiLiveCliEmail && $0.email != geminiLiveAntigravityEmail }
            .map { ("\(displayEmail($0.email)) · Gemini", "gemini:\($0.email)") }
        if !removable.isEmpty {
            let removeRoot = NSMenuItem(title: "Remove Account", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            for entry in removable {
                let item = NSMenuItem(title: entry.title,
                                      action: #selector(removeAccount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.key
                sub.addItem(item)
            }
            removeRoot.submenu = sub
            menu.addItem(removeRoot)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now",
                                 action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        if let lastRefresh {
            updatedItem = addDetail("Updated \(Format.updated.string(from: lastRefresh)) · refreshes every 2 min")
        }
        if let lastTopLevelError {
            addDetail("⚠️ \(lastTopLevelError)")
        }

        menu.addItem(.separator())

        if let updateInfo {
            let title = updateInfo.canRebuild
                ? "↑ Update to v\(updateInfo.version) & Relaunch"
                : "↑ Update available — v\(updateInfo.version)"
            let item = NSMenuItem(title: title, action: #selector(updateAction(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        addDetail("PitStop v\(AppVersion.current)")

        // All preferences now live in the Settings window.
        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // Routed through quitApp rather than terminate: directly — macOS 26
        // auto-assigns an icon to well-known selectors, which adds an image
        // column to this group and orphans neighboring items.
        let quit = NSMenuItem(title: "Quit PitStop",
                              action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func openSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    @objc private func updateAction(_ sender: Any?) {
        guard let info = updateInfo else { return }
        guard info.canRebuild else {
            NSWorkspace.shared.open(info.url)   // no source checkout — open the release
            return
        }
        let alert = NSAlert()
        alert.messageText = "Update to v\(info.version)?"
        alert.informativeText = "PitStop will pull the latest source, rebuild, and relaunch. This takes a few seconds."
        alert.addButton(withTitle: "Update & Relaunch")
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: performSourceUpdate()
        case .alertSecondButtonReturn: NSWorkspace.shared.open(info.url)
        default: break
        }
    }

    /// Pull + rebuild + relaunch in place. Surfaces the failing step's output
    /// and stays running if anything goes wrong (no half-applied relaunch).
    private func performSourceUpdate() {
        Notifier.shared.post(title: "Updating PitStop…",
                             body: "Pulling and rebuilding from source — it'll relaunch when done.")
        Task { @MainActor in
            do {
                try await Updater.rebuildFromSource()
                Updater.relaunch()
            } catch {
                showError("Update failed", error)
            }
        }
    }

    /// A row offers Login when its token was rejected (needsAction), it's a
    /// switchable provider, and it isn't the live account. Inactive-only keeps
    /// the "never touch live" invariant absolute.
    func shouldOfferLogin(for account: MenuAccount) -> Bool {
        needsAction.contains(account.key) && account.canSwitch && !account.isActive
    }

    /// Test seam: set the needs-action set directly.
    func setNeedsActionForTest(_ keys: Set<String>) { needsAction = keys }

    /// Merge the two Gemini live surfaces into a single `MenuAccount.Source`.
    static func geminiSource(onCli: Bool, onAntigravity: Bool) -> MenuAccount.Source {
        if onCli && onAntigravity { return .geminiBoth }
        return onCli ? .geminiCli : .geminiAntigravity
    }

    /// Assemble the display model for one account row. Bars and extras differ
    /// by provider (Anthropic 5h/7d + Opus/Sonnet vs Codex's generic windows);
    /// the stale/error/loading status line is shared via the storage key.
    private func rowModel(for account: MenuAccount) -> AccountRowView.Model {
        let email = account.email
        let key = account.key
        let bars: [AccountRowView.BarRow]
        var extras: [String] = []
        let dataDate: Date?

        if account.isGemini {
            let gu = geminiUsage[key]
            let windows = (gu?.windows ?? []).sorted { $0.usedPercent > $1.usedPercent }
            if let binding = windows.first {
                bars = [.init(label: binding.label, utilization: binding.usedPercent,
                              resetText: Format.compactReset(binding.resetsAt))]
            } else {
                bars = []
            }
            if let extraStr = gu.flatMap(Gemini.extrasLine) { extras.append(extraStr) }
            dataDate = gu?.fetchedAt
        } else if account.isCodex {
            let cu = codexUsage[key]
            bars = (cu?.windows ?? []).map {
                .init(label: $0.label, utilization: $0.usedPercent,
                      resetText: Format.compactReset($0.resetsAt))
            }
            dataDate = cu?.fetchedAt
        } else {
            let report = usage[key]
            bars = [
                .init(label: "5h", utilization: report?.fiveHour?.utilization,
                      resetText: Format.compactReset(report?.fiveHour?.resetsAt)),
                .init(label: "7d", utilization: report?.sevenDay?.utilization,
                      resetText: Format.compactReset(report?.sevenDay?.resetsAt)),
            ] + (report?.scoped ?? []).map {
                .init(label: $0.label, utilization: $0.window.utilization,
                      resetText: Format.compactReset($0.window.resetsAt))
            }
            if let r = report, r.extraUsageEnabled, let v = r.extraUsageUtilization {
                extras.append("Extra \(Format.percent(v))")
            }
            dataDate = report?.fetchedAt
        }

        var status: String?
        var statusIsInfo = false
        var dimBars = false
        if account.isCodex, account.isActive, needsAction.contains(key) {
            // The live token on disk is stale and PitStop won't rotate it out
            // from under Codex — show the last-known numbers, dimmed, until
            // Codex saves a fresh token on its own.
            dimBars = dataDate != nil
            status = dataDate.map { "Last seen \(Format.shortClock($0))" } ?? "No usage data yet"
            statusIsInfo = true
        } else if let err = fetchError[key] {
            var text = err
            // Only promise a retry for backoff errors (rate limits) that will
            // recover on their own — not for ones needing the user to act.
            if let until = nextFetchAllowed[key], !needsAction.contains(key) {
                let remaining = until.timeIntervalSinceNow
                text += remaining > 1
                    ? " — retrying \(Format.relative(remaining))"
                    : " — retrying on next refresh"
            }
            // Data under 10 minutes old needs no staleness caveat, and a
            // transient hiccup with fresh data isn't worth an orange warning.
            let dataAge = dataDate.map { Date().timeIntervalSince($0) }
            if needsAction.contains(key) || dataAge == nil || dataAge! > 600 {
                status = dataDate.map {
                    "⚠︎ \(text) · showing \(Format.shortClock($0)) data"
                } ?? "⚠︎ \(text)"
            } else {
                status = text
                statusIsInfo = true
            }
        } else if dataDate == nil {
            status = "Loading…"
        }

        let projection = fetchError[key] == nil ? projectionText(forKey: key) : nil

        let canSwitch = account.canSwitch && !account.isActive
        let isCodex = account.isCodex
        let isGemini = account.isGemini
        let offerLogin = shouldOfferLogin(for: account)
        return AccountRowView.Model(
            email: displayEmail(email),
            planLabel: account.planLabel,
            isActive: account.isActive,
            sourceBadge: account.surfaceTag,
            bars: bars,
            barsDimmed: dimBars,
            modelsLine: extras.isEmpty ? nil : extras.joined(separator: " · "),
            projectionLine: projection,
            statusLine: status,
            statusIsInfo: statusIsInfo,
            onSwitch: (canSwitch && !offerLogin) ? { [weak self] in
                if isGemini { self?.performGeminiSwitch(to: email) }
                else if isCodex { self?.performCodexSwitch(to: email) }
                else { self?.performSwitch(to: email) }
            } : nil,
            onLogin: offerLogin ? { [weak self] in self?.performLogin(account) } : nil)
    }

    private func addDisabled(_ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func detailText(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                                 weight: .regular)])
    }

    @discardableResult
    private func addDetail(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = 1
        item.attributedTitle = detailText(text)
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    private func performSwitch(to email: String, auto: Bool = false, reason: String? = nil) {
        serializedCredentialOp { [self] in
            do {
                try await store.switchTo(email: email)
                activeEmail = email
                notifiedBucket[email] = nil
                Notifier.shared.post(
                    title: auto ? "Auto-switched to \(displayEmail(email))"
                                : "Switched to \(displayEmail(email))",
                    body: reason ?? "New Claude Code sessions use this account. Running sessions pick it up on their next token refresh.")
                refreshAll()
            } catch {
                showError("Couldn't switch account", error)
            }
        }
    }

    /// When enabled, flip each switchable provider's live account to the saved
    /// account with the most headroom once the live one crosses the threshold.
    /// Only windows of the user-enabled limit kinds participate — both for the
    /// trigger and for ranking targets (nil = no enabled window with data, so
    /// the account neither triggers nor is a target). Desktop is read-only,
    /// so it's left alone.
    private func evaluateAutoSwitch() {
        guard Settings.autoSwitchEnabled else { return }
        let kinds = Settings.autoSwitchKinds
        autoSwitch(provider: .claude, live: activeEmail,
                   candidates: store.profiles.map(\.email),
                   utilization: { fetchError[$0] == nil ? usage[$0]?.maxUtilization(kinds: kinds) : nil },
                   perform: { performSwitch(to: $0, auto: true, reason: $1) })
        autoSwitch(provider: .codex, live: codexLiveEmail,
                   candidates: codexStore.profiles.map(\.email),
                   utilization: {
                       let key = "codex:\($0)"
                       return fetchError[key] == nil ? codexUsage[key]?.maxUtilization(kinds: kinds) : nil
                   },
                   perform: { performCodexSwitch(to: $0, auto: true, reason: $1) })
        autoSwitch(provider: .gemini, live: geminiLiveCliEmail,
                   candidates: geminiStore.profiles.map(\.email),
                   utilization: {
                       let key = "gemini:\($0)"
                       return fetchError[key] == nil ? geminiUsage[key]?.maxUtilization(kinds: kinds) : nil
                   },
                   perform: { performGeminiSwitch(to: $0, auto: true, reason: $1) })
    }

    /// Switch `live` to the emptiest candidate below the threshold when it's
    /// over. `utilization` returns nil for accounts without trustworthy data
    /// (errored / stale), so PitStop never switches onto a broken account or
    /// acts on a transient fetch error. A per-provider cooldown stops flapping.
    private func autoSwitch(provider: Provider, live: String?, candidates: [String],
                            utilization: (String) -> Double?,
                            perform: (String, String) -> Void) {
        guard let live, let liveUtil = utilization(live) else { return }
        let threshold = Double(Settings.autoSwitchThreshold)
        guard liveUtil >= threshold else { return }
        if let last = lastAutoSwitch[provider], Date().timeIntervalSince(last) < 180 { return }
        guard let target = candidates
            .filter({ $0 != live })
            .compactMap({ e in utilization(e).map { (e, $0) } })
            .filter({ $0.1 < threshold })
            .min(by: { $0.1 < $1.1 }) else { return }   // nowhere better to go
        lastAutoSwitch[provider] = Date()
        perform(target.0,
                "\(displayEmail(live)) hit \(Int(liveUtil.rounded()))% — "
                + "moved to \(displayEmail(target.0)) (\(Int(target.1.rounded()))% used).")
    }

    // MARK: - Usage projection

    /// Sample each account's per-window utilization (5-hour + weekly for Claude,
    /// every rate-limit window for Codex), keyed "<account>#<window>". Pruned to
    /// ~30 min and cleared per window on a reset (a real drop). Tracking each
    /// window on its own — not the max of both — is what keeps the trend
    /// coherent: the 5-hour and weekly windows climb and reset on entirely
    /// different cadences, so a single blended series is meaningless.
    private func recordUsageSamples() {
        let now = Date()
        func record(_ key: String, _ util: Double) {
            var samples = usageHistory[key] ?? []
            if let last = samples.last, util < last.util - 2 { samples.removeAll() }  // window reset
            samples.append((date: now, util: util))
            samples.removeAll { now.timeIntervalSince($0.date) > 1800 }
            usageHistory[key] = samples
        }
        for key in Set(usage.keys).union(codexUsage.keys).union(geminiUsage.keys) where fetchError[key] == nil {
            for window in projectableWindows(forKey: key) {
                record("\(key)#\(window.label)", window.util)
            }
        }
    }

    /// The windows PitStop projects toward their limit, for an account key:
    /// Claude's 5-hour and weekly windows, or Codex's own rate-limit windows.
    /// One source of truth so sampling and display stay in lockstep.
    private func projectableWindows(forKey key: String)
        -> [(label: String, util: Double, resetsAt: Date?)] {
        if let cu = codexUsage[key] {
            return cu.windows.map { (label: $0.label, util: $0.usedPercent, resetsAt: $0.resetsAt) }
        }
        if let gu = geminiUsage[key] {
            return gu.windows.map { (label: $0.label, util: $0.usedPercent, resetsAt: $0.resetsAt) }
        }
        if let report = usage[key] {
            var windows = [("5h", report.fiveHour), ("7d", report.sevenDay)]
                .compactMap { label, window in
                    window?.utilization.map { (label: label, util: $0, resetsAt: window?.resetsAt) }
                }
            windows += report.scoped.compactMap { s in
                s.window.utilization.map { (label: s.label, util: $0, resetsAt: s.window.resetsAt) }
            }
            return windows
        }
        return []
    }

    /// The soonest "on pace to hit <window> limit" across an account's windows,
    /// or nil when none is trending toward its own limit before it resets.
    private func projectionText(forKey key: String) -> String? {
        guard Settings.showProjection else { return nil }
        var soonest: (label: String, date: Date)?
        for window in projectableWindows(forKey: key) {
            guard let date = projectedFull(samples: usageHistory["\(key)#\(window.label)"],
                                           current: window.util, resetsAt: window.resetsAt)
            else { continue }
            if soonest == nil || date < soonest!.date { soonest = (window.label, date) }
        }
        guard let soonest else { return nil }
        return "↗ on pace to hit \(windowName(soonest.label)) limit ~\(Format.shortClock(soonest.date))"
    }

    private func windowName(_ label: String) -> String {
        switch label {
        case "5h": return "5-hour"
        case "7d": return "weekly"
        case "30d": return "monthly"
        default: return label
        }
    }

    /// Projected time one window hits 100% at its recent pace, from a
    /// least-squares fit over its samples — only with enough data, a clear rise,
    /// and the limit landing before the window resets. nil otherwise.
    func projectedFull(samples: [(date: Date, util: Double)]?,
                       current: Double, resetsAt: Date?) -> Date? {
        guard current < 100, let samples, samples.count >= 4,
              let first = samples.first, let last = samples.last else { return nil }
        guard last.date.timeIntervalSince(first.date) >= 600 else { return nil }  // ≥ 10 min of trend
        guard let rate = slopePerSecond(samples), rate > 0.0005 else { return nil }  // rising > ~1.8 %/h
        let projected = Date().addingTimeInterval((100 - current) / rate)
        guard projected > Date() else { return nil }
        // A barely-used window projecting far into the future is noise, not a
        // warning — only surface once the window is meaningfully used or the
        // limit is genuinely close.
        guard current >= 25 || projected.timeIntervalSinceNow <= 3 * 3600 else { return nil }
        if let resetsAt, projected >= resetsAt { return nil }   // window resets before it fills
        return projected
    }

    /// Least-squares slope (utilization % per second) over the samples — robust
    /// to the endpoint noise a first-vs-last slope suffers. nil if flat/degenerate.
    private func slopePerSecond(_ samples: [(date: Date, util: Double)]) -> Double? {
        let t0 = samples[0].date
        let xs = samples.map { $0.date.timeIntervalSince(t0) }
        let ys = samples.map(\.util)
        let n = Double(samples.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in samples.indices {
            num += (xs[i] - meanX) * (ys[i] - meanY)
            den += (xs[i] - meanX) * (xs[i] - meanX)
        }
        return den > 0 ? num / den : nil
    }

    private func performLogin(_ account: MenuAccount) {
        guard !loginInFlight else { return }
        loginInFlight = true
        let adapter: LoginAdapter
        if account.isGemini {
            // Re-auth the surface PitStop polls with (CLI if present, else Antigravity).
            let onCli = geminiStore.profiles.first(where: { $0.email == account.email })?.onCli ?? true
            adapter = onCli ? GeminiCliLoginAdapter() : GeminiAntigravityLoginAdapter()
        } else if account.isCodex {
            adapter = CodexLoginAdapter()
        } else {
            adapter = ClaudeLoginAdapter()
        }
        let email = account.email
        let ui = OAuthLoginCoordinator.UI(
            openURL: { url in NSWorkspace.shared.open(url) },
            promptPaste: { [weak self] in await self?.pasteWindow.prompt() ?? nil },
            loopbackTimeout: 120)
        Task { @MainActor in
            defer { loginInFlight = false }
            do {
                try await OAuthLoginCoordinator().run(adapter: adapter, expectedEmail: email, ui: ui)
                // The rejected token left a 1-hour backoff + needsAction on this
                // account; clear it so the refresh below actually re-fetches with
                // the fresh credentials and the row heals immediately (instead of
                // staying "rejected" until the backoff expires).
                clearFetchError(for: account.key)
                if account.isGemini { geminiProject[account.email] = nil }
                Notifier.shared.post(title: "Signed in to \(displayEmail(email))",
                                     body: "Fresh credentials saved. This account is switchable again.")
                refreshAll()
            } catch LoginError.cancelled {
                // user backed out of the paste window — no message
            } catch is CancellationError {
                // task cancelled — no message
            } catch {
                showError("Couldn't sign in", error)
            }
        }
    }

    /// Switch the live Codex account by swapping `~/.codex/auth.json`.
    private func performCodexSwitch(to email: String, auto: Bool = false, reason: String? = nil) {
        serializedCredentialOp { [self] in
            do {
                try await codexStore.switchTo(email: email)
                codexLiveEmail = email
                Notifier.shared.post(
                    title: auto ? "Auto-switched Codex to \(displayEmail(email))"
                                : "Switched Codex to \(displayEmail(email))",
                    body: reason ?? "New `codex` sessions use this account. Quit and reopen the Codex app to pick it up.")
                refreshAll()
            } catch {
                showError("Couldn't switch Codex account", error)
            }
        }
    }

    /// Switch the live Gemini account by swapping BOTH surfaces (CLI file +
    /// Antigravity keychain) to `email`.
    private func performGeminiSwitch(to email: String, auto: Bool = false, reason: String? = nil) {
        serializedCredentialOp { [self] in
            do {
                try await geminiStore.switchTo(email: email)
                geminiLiveCliEmail = geminiStore.liveCliEmail()
                geminiLiveAntigravityEmail = await geminiStore.liveAntigravityEmail()
                Notifier.shared.post(
                    title: auto ? "Auto-switched Gemini to \(displayEmail(email))"
                                : "Switched Gemini to \(displayEmail(email))",
                    body: reason ?? "Quit & reopen Gemini CLI / Antigravity to pick it up. (Rotating accounts may violate Antigravity's terms.)")
                refreshAll()
            } catch { showError("Couldn't switch Gemini account", error) }
        }
    }

    @objc private func saveCurrent(_ sender: Any?) {
        serializedCredentialOp { [self] in
            do {
                if let profile = try await store.captureCurrent().profile {
                    Notifier.shared.post(title: "Saved \(displayEmail(profile.email))",
                                         body: "This account can now be switched to from PitStop.")
                } else {
                    showError("Nothing to save",
                              ProfileStore.StoreError(message: "No Claude Code login found. Run `claude` and log in first."))
                }
                refreshAll()
            } catch {
                showError("Couldn't save account", error)
            }
        }
    }

    /// Drop per-account state whose account no longer exists. Without this, a
    /// signed-out Desktop account keeps feeding the most-urgent menu bar
    /// reading, and an account removed mid-refresh gets resurrected by the
    /// in-flight cycle's recordFetch* calls.
    private func pruneOrphanedState() {
        var valid = Set(store.profiles.map(\.email))
        if let d = desktopAccount { valid.insert(d.email) }
        for c in codexStore.profiles { valid.insert("codex:\(c.email)") }
        for g in geminiStore.profiles { valid.insert("gemini:\(g.email)") }
        usage = usage.filter { valid.contains($0.key) }
        codexUsage = codexUsage.filter { valid.contains($0.key) }
        geminiUsage = geminiUsage.filter { valid.contains($0.key) }
        fetchError = fetchError.filter { valid.contains($0.key) }
        nextFetchAllowed = nextFetchAllowed.filter { valid.contains($0.key) }
        failureCount = failureCount.filter { valid.contains($0.key) }
        needsAction = needsAction.filter { valid.contains($0) }
        notifiedBucket = notifiedBucket.filter { valid.contains($0.key) }
        geminiProject = geminiProject.filter { valid.contains("gemini:\($0.key)") }
        usageHistory = usageHistory.filter { entry in
            valid.contains(where: { entry.key.hasPrefix("\($0)#") })
        }
    }

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        Task {
            do {
                if key.hasPrefix("gemini:") {
                    let email = String(key.dropFirst("gemini:".count))
                    try await geminiStore.remove(email: email)
                    geminiUsage[key] = nil
                    geminiProject[email] = nil
                } else if key.hasPrefix("codex:") {
                    let email = String(key.dropFirst("codex:".count))
                    try await codexStore.remove(email: email)
                    codexUsage[key] = nil
                } else {
                    try await store.remove(email: key)
                    usage[key] = nil
                }
                fetchError[key] = nil
                nextFetchAllowed[key] = nil
                failureCount[key] = nil
                needsAction.remove(key)
                notifiedBucket[key] = nil
                usageHistory = usageHistory.filter { !$0.key.hasPrefix("\(key)#") }
                buildMenu()
            } catch {
                showError("Couldn't remove account", error)
            }
        }
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Threshold notifications

    private func checkThresholds() {
        guard let email = activeEmail, let report = usage[email],
              fetchError[email] == nil else { return }
        let pct = report.maxUtilization
        let bucket = pct >= 95 ? 2 : (pct >= 80 ? 1 : 0)
        let last = notifiedBucket[email] ?? 0
        if bucket > last {
            let reset = report.bindingWindow?.resetsAt.map { Format.reset($0) } ?? ""
            // Point at the saved account with the most headroom.
            let best = store.profiles
                .filter { $0.email != email }
                .compactMap { p -> (String, Double)? in
                    guard let r = usage[p.email], fetchError[p.email] == nil else { return nil }
                    return (p.email, r.maxUtilization)
                }
                .min { $0.1 < $1.1 }
            let hint: String
            if let best, best.1 < 80 {
                hint = "Best pit: \(displayEmail(best.0)) (\(Int(best.1.rounded()))% used) — switch from the menu."
            } else if best != nil {
                hint = "All saved accounts are running hot — check the menu."
            } else {
                hint = "Add a second account in PitStop to keep working."
            }
            Notifier.shared.post(
                title: "Claude Code usage at \(Int(pct.rounded()))%",
                body: "\(displayEmail(email)) — \(reset). \(hint)")
        }
        notifiedBucket[email] = bucket
    }
}

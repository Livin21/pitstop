import AppKit
import ServiceManagement

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
            return report.fiveHour?.utilization == nil && report.sevenDay?.utilization == nil
                ? nil : report.maxUtilization
        case .fiveHour: return report.fiveHour?.utilization
        case .weekly: return report.sevenDay?.utilization
        }
    }
}

/// One row in the menu. Accounts are keyed by email — the same account signed
/// into both Claude Code and Claude Desktop is one shared usage pool, so it's
/// one row. `source` records where PitStop found it and whether it can switch
/// into it (Code accounts only; Desktop is observe-only).
struct MenuAccount {
    enum Source { case code, desktop, both }
    var email: String
    var source: Source
    var planLabel: String
    var isActive: Bool
    var profile: Profile?       // present for .code / .both

    var canSwitch: Bool { profile != nil }
    var onDesktop: Bool { source != .code }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    /// One-shot retry scheduled for the earliest backoff expiry, so a
    /// rate-limited account doesn't wait out the rest of a 2-min tick.
    private var backoffTimer: Timer?

    private let store = ProfileStore()
    private var activeEmail: String?
    /// The account Claude Desktop is logged into, if any (read-only — PitStop
    /// can show its usage but can't switch it). Discovered on each refresh.
    private var desktopAccount: ClaudeDesktop.Account?
    /// Last successful report per account — kept on fetch failure so the
    /// display degrades to stale data instead of going blank.
    private var usage: [String: UsageReport] = [:]
    private var fetchError: [String: String] = [:]
    /// Backoff: don't hit the endpoint for this account before this date.
    private var nextFetchAllowed: [String: Date] = [:]
    private var failureCount: [String: Int] = [:]
    private var lastRefresh: Date?
    private var lastTopLevelError: String?
    private var refreshing = false
    /// An explicit Refresh Now arrived while a refresh was in flight.
    private var refreshQueued = false

    private var isMenuOpen = false
    /// The menu got in-place updates while open; rebuild on close to re-sort.
    private var menuNeedsRebuildOnClose = false
    /// The account rows currently in the menu, for in-place refresh.
    private var accountRows: [(email: String, view: AccountRowView)] = []
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
        if refreshing {
            refreshQueued = true
            return
        }
        refreshAll()
    }

    private func refreshAll() {
        guard !refreshing else { return }
        refreshing = true
        Task { @MainActor in
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
                try await store.captureCurrent()
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
                    let report = try await UsageAPI.fetchUsage(accessToken: creds.accessToken)
                    recordFetchSuccess(report, for: email)
                } catch {
                    recordFetchError(error, for: email)
                }
            }

            await refreshDesktopAccount()

            lastRefresh = Date()
            updateStatusTitle()
            if !(isMenuOpen && refreshOpenMenuInPlace()) {
                buildMenu()
            }
            checkThresholds()
            scheduleBackoffRetry()
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

    private func recordFetchSuccess(_ report: UsageReport, for email: String) {
        usage[email] = report
        fetchError[email] = nil
        failureCount[email] = 0
        nextFetchAllowed[email] = nil
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
        case UsageAPI.APIError.unauthorized, ClaudeDesktop.DesktopError.sessionExpired:
            // A rejected token/session won't heal on its own — don't hammer
            // the endpoint every cycle. Refresh Now (or a re-login noticed on
            // the next pass) clears this.
            nextFetchAllowed[email] = Date().addingTimeInterval(3600)
            fetchError[email] = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        default:
            fetchError[email] = error.localizedDescription
        }
    }

    /// Discover the Claude Desktop account and fetch its usage. Best-effort:
    /// a missing/not-signed-in Desktop just clears the account; a fetch error
    /// keeps the last-known identity and shows the error on its row. Skipped
    /// entirely if PitStop already tracks that email as a Code profile (same
    /// account, same shared usage — the Code path already fetched it).
    private func refreshDesktopAccount() async {
        let knownEmail = desktopAccount?.email
        guard knownEmail.map(passedBackoffGate) ?? true else { return }
        do {
            guard let (account, report) = try await ClaudeDesktop.poll() else {
                desktopAccount = nil
                return
            }
            desktopAccount = account
            if !store.profiles.contains(where: { $0.email == account.email }) {
                recordFetchSuccess(report, for: account.email)
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
        let sorted = sortedAccounts()
        guard sorted.count == accountRows.count else { return false }
        let models = sorted.map(rowModel(for:))
        // Keyed by account email, not model.email — the latter may be a
        // masked display address (--screenshot).
        let current = Dictionary(uniqueKeysWithValues: accountRows.map { ($0.email, $0.view) })
        for (account, model) in zip(sorted, models) {
            guard let view = current[account.email],
                  AccountRowView.height(for: model) == view.frame.height else { return false }
        }
        for (account, model) in zip(sorted, models) {
            current[account.email]?.apply(model)
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
        let report = activeEmail.flatMap { usage[$0] }
        guard let email = activeEmail, let report,
              let utilization = IndicatorMetric.current.utilization(of: report) else {
            button.alphaValue = 1
            button.title = style == .iconOnly ? "" : " –"
            if let email = activeEmail, let report {
                button.toolTip = statusTip(email: email, report: report)
            } else {
                button.toolTip = activeEmail.flatMap { fetchError[$0] }
                    ?? "PitStop — no usage data yet"
            }
            return
        }
        let pct = Int(utilization.rounded())
        let isStale = fetchError[email] != nil
        let dot = isStale ? "" : (pct >= 90 ? "\u{2009}🔴" : (pct >= 75 ? "\u{2009}🟠" : ""))
        button.alphaValue = isStale ? 0.55 : 1
        button.title = (style == .iconOnly ? "" : " \(pct)%") + dot
        button.toolTip = statusTip(email: email, report: report)
    }

    private func statusTip(email: String, report: UsageReport) -> String {
        var tip = "\(displayEmail(email))\n5-hour \(Format.percent(report.fiveHour?.utilization))"
            + " · weekly \(Format.percent(report.sevenDay?.utilization))"
        if let err = fetchError[email] {
            tip += "\n⚠️ \(err) — showing data from \(Format.updated.string(from: report.fetchedAt))"
        }
        return tip
    }

    // MARK: - Menu

    /// All rows to show — saved Code profiles plus a Desktop-only account.
    /// An account on both surfaces merges into one Code row tagged `.both`.
    private func accountsForMenu() -> [MenuAccount] {
        var rows = store.profiles.map { profile -> MenuAccount in
            let onDesktop = desktopAccount?.email == profile.email
            return MenuAccount(email: profile.email,
                               source: onDesktop ? .both : .code,
                               planLabel: profile.planLabel,
                               isActive: profile.email == activeEmail,
                               profile: profile)
        }
        if let d = desktopAccount,
           !store.profiles.contains(where: { $0.email == d.email }) {
            rows.append(MenuAccount(email: d.email, source: .desktop,
                                    planLabel: d.planLabel, isActive: false, profile: nil))
        }
        return rows
    }

    /// Active account first, then by headroom (emptiest next).
    private func sortedAccounts() -> [MenuAccount] {
        accountsForMenu().sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return (usage[a.email]?.maxUtilization ?? 999)
                < (usage[b.email]?.maxUtilization ?? 999)
        }
    }

    private func buildMenu() {
        menu.removeAllItems()
        accountRows = []
        updatedItem = nil

        let accounts = sortedAccounts()
        // "Claude Code Usage" unless a Desktop account is in the mix.
        menu.addItem(NSMenuItem.sectionHeader(
            title: desktopAccount == nil ? "Claude Code Usage" : "Claude Usage"))

        if accounts.isEmpty {
            addDisabled("No accounts found — log in with `claude` first")
        }

        for account in accounts {
            let item = NSMenuItem()
            let view = AccountRowView(model: rowModel(for: account))
            item.view = view
            menu.addItem(item)
            accountRows.append((account.email, view))
        }

        menu.addItem(.separator())

        let save = NSMenuItem(title: "Save Current Account",
                              action: #selector(saveCurrent(_:)), keyEquivalent: "s")
        save.target = self
        menu.addItem(save)

        let removable = store.profiles.filter { $0.email != activeEmail }
        if !removable.isEmpty {
            let removeRoot = NSMenuItem(title: "Remove Account", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            for profile in removable {
                let item = NSMenuItem(title: displayEmail(profile.email),
                                      action: #selector(removeAccount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile.email
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

        let display = NSMenuItem(title: "Menu Bar Display", action: nil, keyEquivalent: "")
        let displaySub = NSMenu()
        displaySub.autoenablesItems = false
        for style in IndicatorStyle.allCases {
            let item = NSMenuItem(title: style.label,
                                  action: #selector(setIndicatorStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = style == .current ? .on : .off
            displaySub.addItem(item)
        }
        displaySub.addItem(.separator())
        for metric in IndicatorMetric.allCases {
            let item = NSMenuItem(title: metric.label,
                                  action: #selector(setIndicatorMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = metric.rawValue
            item.state = metric == .current ? .on : .off
            displaySub.addItem(item)
        }
        display.submenu = displaySub
        menu.addItem(display)

        if Bundle.main.bundlePath.hasSuffix(".app") {
            let login = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }

        // Routed through quitApp rather than terminate: directly — macOS 26
        // auto-assigns an icon to well-known selectors, which adds an image
        // column to this group and orphans the Launch at Login checkmark.
        let quit = NSMenuItem(title: "Quit PitStop",
                              action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Assemble the display model for one account row.
    private func rowModel(for account: MenuAccount) -> AccountRowView.Model {
        let email = account.email
        let report = usage[email]
        let bars: [AccountRowView.BarRow] = [
            .init(label: "5h", utilization: report?.fiveHour?.utilization,
                  resetText: Format.compactReset(report?.fiveHour?.resetsAt)),
            .init(label: "7d", utilization: report?.sevenDay?.utilization,
                  resetText: Format.compactReset(report?.sevenDay?.resetsAt)),
        ]

        var extras: [String] = []
        if let v = report?.sevenDayOpus?.utilization, v > 0 {
            extras.append("Opus wk \(Format.percent(v))")
        }
        if let v = report?.sevenDaySonnet?.utilization, v > 0 {
            extras.append("Sonnet wk \(Format.percent(v))")
        }
        if let r = report, r.extraUsageEnabled {
            extras.append("Extra \(Format.percent(r.extraUsageUtilization))")
        }

        var status: String?
        if let err = fetchError[email] {
            var text = err
            if let until = nextFetchAllowed[email] {
                let remaining = until.timeIntervalSinceNow
                text += remaining > 1
                    ? " — retrying \(Format.relative(remaining))"
                    : " — retrying on next refresh"
            }
            status = report.map {
                "⚠︎ \(text) · showing \(Format.updated.string(from: $0.fetchedAt)) data"
            } ?? "⚠︎ \(text)"
        } else if report == nil {
            status = "Loading…"
        }

        // Only Code accounts can be switched into; Desktop is observe-only.
        let canSwitch = account.canSwitch && !account.isActive
        return AccountRowView.Model(
            email: displayEmail(email),
            planLabel: account.planLabel,
            isActive: account.isActive,
            sourceBadge: account.onDesktop ? "Desktop" : nil,
            bars: bars,
            modelsLine: extras.isEmpty ? nil : extras.joined(separator: " · "),
            statusLine: status,
            onSwitch: canSwitch ? { [weak self] in self?.performSwitch(to: email) } : nil)
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

    private func performSwitch(to email: String) {
        Task {
            do {
                try await store.switchTo(email: email)
                activeEmail = email
                notifiedBucket[email] = nil
                Notifier.shared.post(
                    title: "Switched to \(displayEmail(email))",
                    body: "New Claude Code sessions use this account. Running sessions pick it up on their next token refresh.")
                refreshAll()
            } catch {
                showError("Couldn't switch account", error)
            }
        }
    }

    @objc private func saveCurrent(_ sender: Any?) {
        Task {
            do {
                if let profile = try await store.captureCurrent() {
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

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let email = sender.representedObject as? String else { return }
        Task {
            do {
                try await store.remove(email: email)
                usage[email] = nil
                fetchError[email] = nil
                nextFetchAllowed[email] = nil
                failureCount[email] = nil
                buildMenu()
            } catch {
                showError("Couldn't remove account", error)
            }
        }
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    @objc private func setIndicatorStyle(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "indicatorStyle")
        updateStatusTitle()
        buildMenu()
    }

    @objc private func setIndicatorMetric(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "indicatorMetric")
        updateStatusTitle()
        buildMenu()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Couldn't change login item", error)
        }
        buildMenu()
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

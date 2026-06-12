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

    private func displayEmail(_ email: String) -> String {
        guard maskEmails else { return email }
        let masks = ["asha@work.com", "personal@example.com", "side@example.com"]
        let i = store.profiles.map(\.email).sorted().firstIndex(of: email) ?? 0
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

            for profile in store.profiles {
                let email = profile.email
                if let notBefore = nextFetchAllowed[email] {
                    if Date() < notBefore {
                        continue // still backing off; keep showing stale data
                    }
                    // Gate passed — clear it now so entries are always
                    // future-dated or absent (menuNeedsUpdate's retryDue
                    // check relies on that); the attempt below sets a new
                    // one if needed.
                    nextFetchAllowed[email] = nil
                }
                do {
                    let creds = try await freshCredentials(for: email,
                                                           isActive: email == activeEmail)
                    let report = try await UsageAPI.fetchUsage(accessToken: creds.accessToken)
                    usage[email] = report
                    fetchError[email] = nil
                    failureCount[email] = 0
                    nextFetchAllowed[email] = nil
                } catch UsageAPI.APIError.rateLimited(let retryAfter) {
                    let fails = (failureCount[email] ?? 0) + 1
                    failureCount[email] = fails
                    // Respect Retry-After; otherwise exponential backoff
                    // 2 min → 4 min → … capped at 15 min.
                    let delay = retryAfter
                        ?? min(120 * pow(2, Double(fails - 1)), 900)
                    // Retry timing is rendered from nextFetchAllowed at
                    // display time, so it doesn't go stale in the menu.
                    nextFetchAllowed[email] = Date().addingTimeInterval(delay)
                    fetchError[email] = "Rate limited"
                } catch UsageAPI.APIError.unauthorized {
                    failureCount[email] = (failureCount[email] ?? 0) + 1
                    fetchError[email] = UsageAPI.APIError.unauthorized.localizedDescription
                    // A rejected token won't heal on its own — don't hammer
                    // the OAuth endpoint every cycle. Refresh Now (or a
                    // re-login noticed by captureCurrent) clears this.
                    nextFetchAllowed[email] = Date().addingTimeInterval(3600)
                } catch {
                    failureCount[email] = (failureCount[email] ?? 0) + 1
                    fetchError[email] = error.localizedDescription
                }
            }
            lastRefresh = Date()
            updateStatusTitle()
            if !(isMenuOpen && refreshOpenMenuInPlace()) {
                buildMenu()
            }
            checkThresholds()
            scheduleBackoffRetry()
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
        let sorted = sortedProfiles()
        guard sorted.count == accountRows.count else { return false }
        let models = sorted.map(rowModel(for:))
        // Keyed by profile email, not model.email — the latter may be a
        // masked display address (--screenshot).
        let current = Dictionary(uniqueKeysWithValues: accountRows.map { ($0.email, $0.view) })
        for (profile, model) in zip(sorted, models) {
            guard let view = current[profile.email],
                  AccountRowView.height(for: model) == view.frame.height else { return false }
        }
        for (profile, model) in zip(sorted, models) {
            current[profile.email]?.apply(model)
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
        let report = activeEmail.flatMap { usage[$0] }
        guard let email = activeEmail, let report,
              let utilization = IndicatorMetric.current.utilization(of: report) else {
            button.contentTintColor = nil
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
        let color: NSColor = isStale ? .secondaryLabelColor
            : (pct >= 90 ? .systemRed : (pct >= 75 ? .systemOrange : .labelColor))
        // In icon-only mode the tint is the only at-a-glance signal; leave
        // the icon untinted while healthy so it matches its neighbors.
        button.contentTintColor = color == .labelColor ? nil : color
        button.attributedTitle = NSAttributedString(
            string: style == .iconOnly ? "" : " \(pct)%",
            attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            ])
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

    /// Active account first, then by headroom (emptiest next).
    private func sortedProfiles() -> [Profile] {
        store.profiles.sorted { a, b in
            let aActive = a.email == activeEmail
            let bActive = b.email == activeEmail
            if aActive != bActive { return aActive }
            return (usage[a.email]?.maxUtilization ?? 999)
                < (usage[b.email]?.maxUtilization ?? 999)
        }
    }

    private func buildMenu() {
        menu.removeAllItems()
        accountRows = []
        updatedItem = nil

        menu.addItem(NSMenuItem.sectionHeader(title: "Claude Code Usage"))

        if store.profiles.isEmpty {
            addDisabled("No accounts found — log in with `claude` first")
        }

        for profile in sortedProfiles() {
            let item = NSMenuItem()
            let view = AccountRowView(model: rowModel(for: profile))
            item.view = view
            menu.addItem(item)
            accountRows.append((profile.email, view))
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
    private func rowModel(for profile: Profile) -> AccountRowView.Model {
        let email = profile.email
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

        let isActive = email == activeEmail
        return AccountRowView.Model(
            email: displayEmail(email),
            planLabel: profile.planLabel,
            isActive: isActive,
            bars: bars,
            modelsLine: extras.isEmpty ? nil : extras.joined(separator: " · "),
            statusLine: status,
            onSwitch: isActive ? nil : { [weak self] in self?.performSwitch(to: email) })
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

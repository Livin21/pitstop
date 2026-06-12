import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?

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

    /// 0 = below 80%, 1 = ≥80%, 2 = ≥95% — to notify once per crossing.
    private var notifiedBucket: [String: Int] = [:]

    private let refreshInterval: TimeInterval = 120
    /// Don't re-fetch on menu open if data is younger than this.
    private let menuRefreshDebounce: TimeInterval = 30

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let symbol = NSImage(systemSymbolName: "flag.checkered",
                                 accessibilityDescription: "Claude Code usage")
                ?? NSImage(systemSymbolName: "gauge.with.needle",
                           accessibilityDescription: "Claude Code usage")
            button.image = symbol
            button.imagePosition = .imageLeading
            button.title = " …"
        }
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
        if let last = lastRefresh, Date().timeIntervalSince(last) < menuRefreshDebounce {
            return
        }
        refreshAll()
    }

    @objc func refreshNow(_ sender: Any?) {
        // Explicit refresh clears any backoff — the user asked for it.
        nextFetchAllowed.removeAll()
        refreshAll()
    }

    private func refreshAll() {
        guard !refreshing else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false }
            lastTopLevelError = nil

            // Keep the saved copy of the live account in sync.
            do {
                try store.captureCurrent()
            } catch {
                lastTopLevelError = error.localizedDescription
            }
            store.load()
            activeEmail = ClaudeConfig.activeEmail()

            for profile in store.profiles {
                let email = profile.email
                if let notBefore = nextFetchAllowed[email], Date() < notBefore {
                    continue // still backing off; keep showing stale data
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
                    nextFetchAllowed[email] = Date().addingTimeInterval(delay)
                    fetchError[email] = "Rate limited — retrying \(Format.relative(delay))"
                } catch {
                    failureCount[email] = (failureCount[email] ?? 0) + 1
                    fetchError[email] = error.localizedDescription
                }
            }
            lastRefresh = Date()
            updateStatusTitle()
            buildMenu()
            checkThresholds()
        }
    }

    /// Returns non-expired credentials for a profile, refreshing via the
    /// OAuth refresh grant (and persisting the result) when needed.
    private func freshCredentials(for email: String, isActive: Bool) async throws -> OAuthCredentials {
        guard let blob = try store.blob(for: email, isActive: isActive) else {
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
        try store.storeRefreshedBlob(patched, email: email, isActive: isActive)
        creds.accessToken = fresh.accessToken
        creds.refreshToken = fresh.refreshToken ?? creds.refreshToken
        creds.expiresAtMs = fresh.expiresAtMs
        return creds
    }

    // MARK: - Status item

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        guard let email = activeEmail, let report = usage[email] else {
            button.title = " –"
            button.toolTip = activeEmail.flatMap { fetchError[$0] }
                ?? "PitStop — no usage data yet"
            return
        }
        let pct = Int(report.maxUtilization.rounded())
        let isStale = fetchError[email] != nil
        let color: NSColor = isStale ? .secondaryLabelColor
            : (pct >= 90 ? .systemRed : (pct >= 75 ? .systemOrange : .labelColor))
        button.attributedTitle = NSAttributedString(
            string: " \(pct)%",
            attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            ])
        var tip = "\(email)\n5-hour \(Format.percent(report.fiveHour?.utilization))"
            + " · weekly \(Format.percent(report.sevenDay?.utilization))"
        if let err = fetchError[email] {
            tip += "\n⚠️ \(err) — showing data from \(Format.updated.string(from: report.fetchedAt))"
        }
        button.toolTip = tip
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.removeAllItems()

        menu.addItem(NSMenuItem.sectionHeader(title: "Claude Code Usage"))

        if store.profiles.isEmpty {
            addDisabled("No accounts found — log in with `claude` first")
        }

        // Active account first, then by headroom (emptiest next).
        let sorted = store.profiles.sorted { a, b in
            let aActive = a.email == activeEmail
            let bActive = b.email == activeEmail
            if aActive != bActive { return aActive }
            return (usage[a.email]?.maxUtilization ?? 999)
                < (usage[b.email]?.maxUtilization ?? 999)
        }

        for profile in sorted {
            let item = NSMenuItem()
            item.view = AccountRowView(model: rowModel(for: profile))
            menu.addItem(item)
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
                let item = NSMenuItem(title: profile.email,
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
            addDetail("Updated \(Format.updated.string(from: lastRefresh)) · refreshes every 2 min")
        }
        if let lastTopLevelError {
            addDetail("⚠️ \(lastTopLevelError)")
        }

        menu.addItem(.separator())

        if Bundle.main.bundlePath.hasSuffix(".app") {
            let login = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }

        let quit = NSMenuItem(title: "Quit PitStop",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
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
            status = report.map {
                "⚠︎ \(err) · showing \(Format.updated.string(from: $0.fetchedAt)) data"
            } ?? "⚠︎ \(err)"
        } else if report == nil {
            status = "Loading…"
        }

        let isActive = email == activeEmail
        return AccountRowView.Model(
            email: email,
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

    private func addDetail(_ text: String) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = 1
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                                 weight: .regular)])
        menu.addItem(item)
    }

    // MARK: - Actions

    private func performSwitch(to email: String) {
        do {
            try store.switchTo(email: email)
            activeEmail = email
            notifiedBucket[email] = nil
            Notifier.shared.post(
                title: "Switched to \(email)",
                body: "New Claude Code sessions use this account. Running sessions pick it up on their next token refresh.")
            refreshAll()
        } catch {
            showError("Couldn't switch account", error)
        }
    }

    @objc private func saveCurrent(_ sender: Any?) {
        do {
            if let profile = try store.captureCurrent() {
                Notifier.shared.post(title: "Saved \(profile.email)",
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

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let email = sender.representedObject as? String else { return }
        do {
            try store.remove(email: email)
            usage[email] = nil
            fetchError[email] = nil
            nextFetchAllowed[email] = nil
            failureCount[email] = nil
            buildMenu()
        } catch {
            showError("Couldn't remove account", error)
        }
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
                hint = "Best pit: \(best.0) (\(Int(best.1.rounded()))% used) — switch from the menu."
            } else if best != nil {
                hint = "All saved accounts are running hot — check the menu."
            } else {
                hint = "Add a second account in PitStop to keep working."
            }
            Notifier.shared.post(
                title: "Claude Code usage at \(Int(pct.rounded()))%",
                body: "\(email) — \(reset). \(hint)")
        }
        notifiedBucket[email] = bucket
    }
}

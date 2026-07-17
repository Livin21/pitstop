import AppKit

// `pitstop --check` — headless diagnostic: prints saved accounts and live
// usage to stdout without starting the menu bar app. Useful for debugging
// keychain access and the usage endpoint from a terminal.
if CommandLine.arguments.contains("--check") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        let store = ProfileStore()
        do {
            try await store.captureCurrent()
        } catch {
            print("capture failed: \(error.localizedDescription)")
        }
        store.load()
        let active = ClaudeConfig.activeIdentity()
        let activeDescription = active.map { "\($0.email) [\($0.organizationUUID)]" } ?? "<none>"
        print("active account: \(activeDescription)")
        for profile in store.profiles {
            let isActive = profile.identity == active
            print("\n\(isActive ? "●" : "○") \(profile.email)  [\(profile.planLabel)]")
            do {
                guard let blob = try await store.blob(for: profile, isActive: isActive) else {
                    print("   no stored credentials")
                    continue
                }
                var creds = try CredentialBlob.parse(blob)
                if creds.isExpired, let rt = creds.refreshToken {
                    print("   token expired — refreshing…")
                    let fresh = try await UsageAPI.refresh(refreshToken: rt)
                    let patched = try CredentialBlob.patching(
                        blob, accessToken: fresh.accessToken,
                        refreshToken: fresh.refreshToken, expiresAtMs: fresh.expiresAtMs)
                    try await store.storeRefreshedBlob(patched, profile: profile, isActive: isActive)
                    creds.accessToken = fresh.accessToken
                }
                let report = try await UsageAPI.fetchUsage(accessToken: creds.accessToken)
                print("   5-hour  \(Format.percent(report.fiveHour?.utilization))  \(Format.reset(report.fiveHour?.resetsAt))")
                print("   weekly  \(Format.percent(report.sevenDay?.utilization))  \(Format.reset(report.sevenDay?.resetsAt))")
            } catch {
                print("   error: \(error.localizedDescription)")
            }
        }

        // Claude Desktop (observe-only — its claude.ai session).
        do {
            if let (acct, report) = try await ClaudeDesktop.poll() {
                let dup = store.profiles.contains { $0.key == acct.key }
                    ? "  (also a saved Code account)" : ""
                print("\n▣ \(acct.email)  [\(acct.planLabel)]  · Desktop\(dup)")
                print("   5-hour  \(Format.percent(report.fiveHour?.utilization))  \(Format.reset(report.fiveHour?.resetsAt))")
                print("   weekly  \(Format.percent(report.sevenDay?.utilization))  \(Format.reset(report.sevenDay?.resetsAt))")
            } else if ClaudeDesktop.isPresent {
                print("\nClaude Desktop: installed but not signed in")
            }
        } catch {
            print("\nClaude Desktop: \(error.localizedDescription)")
        }

        // Codex (CLI + app share ~/.codex/auth.json).
        if Codex.isPresent {
            let codex = CodexStore()
            do { try await codex.captureCurrent() } catch {
                print("\nCodex capture failed: \(error.localizedDescription)")
            }
            codex.load()
            let codexLive = codex.liveEmail()
            if codex.profiles.isEmpty {
                print("\nCodex: installed but not signed in with a ChatGPT account")
            }
            for profile in codex.profiles {
                let isLive = profile.email == codexLive
                print("\n\(isLive ? "▣" : "▢") \(profile.email)  [\(profile.planLabel)]  · Codex")
                do {
                    guard let blob = try await codex.blob(for: profile.email, isActive: isLive),
                          let creds = Codex.credentials(from: blob) else {
                        print("   no usable credentials"); continue
                    }
                    var usage: Codex.Usage
                    do {
                        usage = try await Codex.fetchUsage(creds)
                    } catch Codex.CodexError.sessionExpired where !isLive {
                        guard let rt = creds.refreshToken else { throw Codex.CodexError.sessionExpired }
                        print("   token expired — refreshing…")
                        let refreshed = try await Codex.refresh(refreshToken: rt)
                        guard let patched = Codex.patching(blob, with: refreshed),
                              let fresh = Codex.credentials(from: patched) else {
                            throw Codex.CodexError.malformed
                        }
                        try await codex.storeRefreshedBlob(patched, email: profile.email)
                        usage = try await Codex.fetchUsage(fresh)
                    }
                    if usage.windows.isEmpty { print("   (no usage windows reported)") }
                    for w in usage.windows {
                        print("   \(w.label.isEmpty ? "window" : w.label)  \(Format.percent(w.usedPercent))  \(Format.reset(w.resetsAt))")
                    }
                } catch {
                    print("   error: \(error.localizedDescription)")
                }
            }
        }
    }
    semaphore.wait()
    exit(0)
}

// `pitstop --preview` — render sample account rows to /tmp/pitstop-preview.png
// for design iteration without opening the real menu.
if CommandLine.arguments.contains("--preview") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let calendar = Calendar.current
        let tonight = calendar.date(byAdding: .hour, value: 3, to: Date())!
        let nextWeek = calendar.date(byAdding: .day, value: 5, to: Date())!
        let models: [AccountRowView.Model] = [
            .init(email: "asha@acme.dev",
                  planLabel: "Acme AI · Team · 5x", isActive: true,
                  bars: [.init(label: "5h", utilization: 64, resetText: Format.compactReset(tonight)),
                         .init(label: "7d", utilization: 23, resetText: Format.compactReset(nextWeek)),
                         .init(label: "Fable", utilization: 13, resetText: Format.compactReset(nextWeek))],
                  modelsLine: nil,
                  projectionLine: "↗ on pace to hit limit ~4:10 PM",
                  statusLine: nil, onSwitch: nil),
            .init(email: "personal@example.com",
                  planLabel: "Max · 5x", isActive: false,
                  bars: [.init(label: "5h", utilization: 96, resetText: Format.compactReset(tonight)),
                         .init(label: "7d", utilization: 36, resetText: Format.compactReset(nextWeek))],
                  modelsLine: nil, statusLine: nil, onSwitch: {}),
            .init(email: "side@example.com",
                  planLabel: "Max · 20x", isActive: false,
                  bars: [.init(label: "5h", utilization: 0, resetText: ""),
                         .init(label: "7d", utilization: 100, resetText: Format.compactReset(nextWeek))],
                  modelsLine: "Extra 4%",
                  statusLine: "⚠︎ Rate limited — retrying in 4m · showing 6:01 PM data",
                  onSwitch: {}),
            .init(email: "expired@example.com",
                  planLabel: "Max · 5x", isActive: false,
                  bars: [.init(label: "5h", utilization: 0, resetText: ""),
                         .init(label: "7d", utilization: 0, resetText: "")],
                  modelsLine: nil,
                  statusLine: "⚠︎ Token rejected — re-login needed · showing 10:37 PM data",
                  onSwitch: nil, onLogin: {}),
            .init(email: "anna.desktop@example.com",
                  planLabel: "Max · 20x", isActive: false, sourceBadge: "Code · Desktop",
                  bars: [.init(label: "5h", utilization: 12, resetText: Format.compactReset(tonight)),
                         .init(label: "7d", utilization: 41, resetText: Format.compactReset(nextWeek))],
                  modelsLine: nil, statusLine: nil, onSwitch: {}),
            .init(email: "codex@example.com",
                  planLabel: "Go", isActive: false,
                  bars: [.init(label: "30d", utilization: 20,
                               resetText: Format.compactReset(nextWeek))],
                  modelsLine: nil, statusLine: nil, onSwitch: {}),
            .init(email: "codex-live@example.com",
                  planLabel: "Free", isActive: true,
                  bars: [.init(label: "5h", utilization: 34, resetText: Format.compactReset(tonight))],
                  barsDimmed: true,
                  modelsLine: nil,
                  statusLine: "Last seen 2:31 AM",
                  statusIsInfo: true, onSwitch: nil),
            .init(email: "gemini@example.com",
                  planLabel: "AI Pro", isActive: false,
                  bars: [.init(label: "2.5-flash-lite", utilization: 41,
                               resetText: Format.compactReset(tonight))],
                  modelsLine: "3-pro 12%", statusLine: nil, onSwitch: {}),
        ]
        // Middle row rendered in its hover state to preview the Switch pill.
        let rows = models.enumerated().map { i, m in
            AccountRowView(model: m, hover: i == 1)
        }
        // A section header (hover state) to preview the dashboard link icon.
        let views: [NSView] = [SectionHeaderView(title: "Claude", hover: true, onOpen: {})] + rows
        let totalHeight = views.reduce(0) { $0 + $1.frame.height }
        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: AccountRowView.rowWidth,
                                             height: totalHeight))
        container.appearance = NSAppearance(named: .darkAqua)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        var y: CGFloat = 0
        for v in views.reversed() {   // container is unflipped: stack bottom-up
            v.setFrameOrigin(NSPoint(x: 0, y: y))
            container.addSubview(v)
            y += v.frame.height
        }
        let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds)!
        container.cacheDisplay(in: container.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "/tmp/pitstop-preview.png"))
        print("Wrote /tmp/pitstop-preview.png")
    }
    exit(0)
}

// Refuse to run alongside another PitStop (e.g. installed app + `swift run`
// binary): two instances would fight over the live credential files. flock
// releases automatically if the process dies, so a stale lock can't wedge
// future launches. The fd intentionally stays open for the app's lifetime.
try? FileManager.default.createDirectory(at: ProfileStore.directory,
                                         withIntermediateDirectories: true)
let lockFD = open(ProfileStore.directory.appendingPathComponent("pitstop.lock").path,
                  O_CREAT | O_RDWR, 0o600)
if lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    NSLog("PitStop: another instance is already running — exiting.")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

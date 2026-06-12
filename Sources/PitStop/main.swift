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
        let active = ClaudeConfig.activeEmail() ?? "<none>"
        print("active account: \(active)")
        for profile in store.profiles {
            let isActive = profile.email == active
            print("\n\(isActive ? "●" : "○") \(profile.email)  [\(profile.planLabel)]")
            do {
                guard let blob = try await store.blob(for: profile.email, isActive: isActive) else {
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
                    try await store.storeRefreshedBlob(patched, email: profile.email, isActive: isActive)
                    creds.accessToken = fresh.accessToken
                }
                let report = try await UsageAPI.fetchUsage(accessToken: creds.accessToken)
                print("   5-hour  \(Format.percent(report.fiveHour?.utilization))  \(Format.reset(report.fiveHour?.resetsAt))")
                print("   weekly  \(Format.percent(report.sevenDay?.utilization))  \(Format.reset(report.sevenDay?.resetsAt))")
            } catch {
                print("   error: \(error.localizedDescription)")
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
                  bars: [.init(label: "5h", utilization: 20, resetText: Format.compactReset(tonight)),
                         .init(label: "7d", utilization: 23, resetText: Format.compactReset(nextWeek))],
                  modelsLine: nil, statusLine: nil, onSwitch: nil),
            .init(email: "personal@example.com",
                  planLabel: "Max · 5x", isActive: false,
                  bars: [.init(label: "5h", utilization: 96, resetText: Format.compactReset(tonight)),
                         .init(label: "7d", utilization: 36, resetText: Format.compactReset(nextWeek))],
                  modelsLine: nil, statusLine: nil, onSwitch: {}),
            .init(email: "side@example.com",
                  planLabel: "Max · 20x", isActive: false,
                  bars: [.init(label: "5h", utilization: 0, resetText: ""),
                         .init(label: "7d", utilization: 100, resetText: Format.compactReset(nextWeek))],
                  modelsLine: "Sonnet wk 10%",
                  statusLine: "⚠︎ Rate limited — retrying in 4m · showing 6:01 PM data",
                  onSwitch: {}),
        ]
        // Middle row rendered in its hover state to preview the Switch pill.
        let views = models.enumerated().map { i, m in
            AccountRowView(model: m, hover: i == 1)
        }
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

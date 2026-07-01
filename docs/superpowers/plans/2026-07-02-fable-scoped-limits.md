# Scoped Weekly Limits (Fable) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parse Claude's new `limits` array and render per-model scoped weekly limits (Fable) as their own bar rows, counting fully toward the binding utilization.

**Architecture:** Additive model/parser change first (`ScopedWindow`, `UsageReport.scoped`, binding math), then the display switch (bars, extras cleanup, removal of the dead `sevenDayOpus`/`sevenDaySonnet` fields). One parser serves Code and Desktop rows.

**Tech Stack:** Swift 5 / Foundation JSON, XCTest.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-02-fable-scoped-limits-design.md` (user-approved decisions: own bar row; counts fully toward binding).
- Branch `fable-limits` off `master`; one commit per task; `swift build && swift test` green after each task.
- Legacy `five_hour`/`seven_day` fields stay the preferred source for the two main windows; `limits[]` `session`/`weekly_all` entries are the fallback.
- Unknown `limits[].kind` values must be ignored.
- `ISO8601DateFormatter` handles the API's 6-digit fractional `resets_at` (verified empirically) — reuse the existing `isoFrac ?? iso` parsing.

---

### Task 0: Branch

- [ ] `git checkout -b fable-limits`

---

### Task 1: Model + parser

**Files:**
- Modify: `Sources/PitStop/UsageAPI.swift` (UsageReport struct, `parse`, add `limitWindow` helpers)
- Modify: `Sources/PitStop/AppDelegate.swift:40-48` (`IndicatorMetric.utilization(of:)` nil-check)
- Test: create `Tests/PitStopTests/UsageAPIParseTests.swift`

**Interfaces:**
- Produces: `struct ScopedWindow { let label: String; let window: UsageWindow }`, `UsageReport.scoped: [ScopedWindow]`, `maxUtilization`/`bindingWindow` spanning 5h + 7d + scoped. (`sevenDayOpus`/`sevenDaySonnet` stay in place until Task 2 so the build never breaks.)

- [ ] **Step 1: Write failing tests** — `Tests/PitStopTests/UsageAPIParseTests.swift`:

```swift
import XCTest
@testable import PitStop

final class UsageAPIParseTests: XCTestCase {
    func testParsesScopedWeeklyLimit() throws {
        let data = Data(#"""
        {
          "five_hour": {"utilization": 64.0, "resets_at": "2026-07-02T00:50:00.818202+00:00"},
          "seven_day": {"utilization": 7.0, "resets_at": "2026-07-05T00:00:00+00:00"},
          "limits": [
            {"kind": "session", "group": "session", "percent": 64, "resets_at": "2026-07-02T00:50:00.818202+00:00"},
            {"kind": "weekly_all", "group": "weekly", "percent": 7, "resets_at": "2026-07-05T00:00:00+00:00"},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 13,
             "resets_at": "2026-07-05T00:00:00+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
          ]
        }
        """#.utf8)
        let report = try UsageAPI.parse(data)
        XCTAssertEqual(report.scoped.count, 1)
        XCTAssertEqual(report.scoped.first?.label, "Fable")
        XCTAssertEqual(report.scoped.first?.window.utilization, 13)
        XCTAssertNotNil(report.scoped.first?.window.resetsAt)
        XCTAssertEqual(report.fiveHour?.utilization, 64)      // legacy fields preferred
        XCTAssertNotNil(report.fiveHour?.resetsAt)            // 6-digit fraction parses
    }

    func testScopedLabelFallsBack() throws {
        let data = Data(#"{"limits": [{"kind": "weekly_scoped", "percent": 5}]}"#.utf8)
        XCTAssertEqual(try UsageAPI.parse(data).scoped.first?.label, "Scoped")
    }

    func testFallsBackToLimitsForMainWindows() throws {
        let data = Data(#"""
        {"limits": [
          {"kind": "session", "percent": 42, "resets_at": "2026-07-02T00:50:00+00:00"},
          {"kind": "weekly_all", "percent": 24}
        ]}
        """#.utf8)
        let report = try UsageAPI.parse(data)
        XCTAssertEqual(report.fiveHour?.utilization, 42)
        XCTAssertNotNil(report.fiveHour?.resetsAt)
        XCTAssertEqual(report.sevenDay?.utilization, 24)
    }

    func testUnknownLimitKindsIgnored() throws {
        let data = Data(#"{"limits": [{"kind": "hourly_lunar", "percent": 99}], "five_hour": {"utilization": 1}}"#.utf8)
        let report = try UsageAPI.parse(data)
        XCTAssertTrue(report.scoped.isEmpty)
        XCTAssertEqual(report.maxUtilization, 1)
    }

    func testBindingIncludesScoped() throws {
        let data = Data(#"""
        {"five_hour": {"utilization": 10}, "seven_day": {"utilization": 20},
         "limits": [{"kind": "weekly_scoped", "percent": 95,
                     "resets_at": "2026-07-05T00:00:00+00:00",
                     "scope": {"model": {"display_name": "Fable"}}}]}
        """#.utf8)
        let report = try UsageAPI.parse(data)
        XCTAssertEqual(report.maxUtilization, 95)
        XCTAssertNotNil(report.bindingWindow?.resetsAt)   // Fable's reset drives notifications
    }
}
```

- [ ] **Step 2:** `swift test --filter UsageAPIParseTests` → FAIL (no `scoped` member).
- [ ] **Step 3: Implement.** In `UsageAPI.swift`, above `UsageReport`:

```swift
/// A per-model weekly limit ("Fable", …) from the limits array's
/// weekly_scoped entries. An independent cap: hitting it blocks only that
/// model, but per user preference it still counts toward the binding number.
struct ScopedWindow {
    let label: String
    let window: UsageWindow
}
```

In `UsageReport`, add `var scoped: [ScopedWindow] = []` after `sevenDaySonnet`, and replace `maxUtilization`/`bindingWindow`:

```swift
    /// The binding constraint — whichever window is closest to its limit.
    var maxUtilization: Double { bindingWindow?.utilization ?? 0 }

    /// The window driving `maxUtilization`, for reset-time display.
    /// First-wins on ties, so 5h beats 7d beats scoped at equal utilization.
    var bindingWindow: UsageWindow? {
        var best: UsageWindow?
        for w in [fiveHour, sevenDay].compactMap({ $0 }) + scoped.map(\.window)
        where best == nil || (w.utilization ?? 0) > (best?.utilization ?? 0) {
            best = w
        }
        return best
    }
```

In `parse`, after `report.sevenDaySonnet = …`:

```swift
        let limits = (root["limits"] as? [[String: Any]]) ?? []
        if report.fiveHour == nil { report.fiveHour = limitWindow(limits, kind: "session") }
        if report.sevenDay == nil { report.sevenDay = limitWindow(limits, kind: "weekly_all") }
        report.scoped = limits
            .filter { $0["kind"] as? String == "weekly_scoped" }
            .compactMap { entry in
                guard let w = limitWindow(entry) else { return nil }
                let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
                return ScopedWindow(label: model?["display_name"] as? String ?? "Scoped", window: w)
            }
```

Below the existing `window(_:)` helper:

```swift
    /// A UsageWindow from a `limits[]` entry (percent + resets_at).
    private static func limitWindow(_ entry: [String: Any]) -> UsageWindow? {
        guard let pct = (entry["percent"] as? NSNumber)?.doubleValue else { return nil }
        var date: Date?
        if let s = entry["resets_at"] as? String {
            date = isoFrac.date(from: s) ?? iso.date(from: s)
        }
        return UsageWindow(utilization: pct, resetsAt: date)
    }

    private static func limitWindow(_ limits: [[String: Any]], kind: String) -> UsageWindow? {
        limits.first { $0["kind"] as? String == kind }.flatMap(limitWindow)
    }
```

In `AppDelegate.swift`, `IndicatorMetric.utilization(of:)` `.binding` case:

```swift
        case .binding:
            let hasData = report.fiveHour?.utilization != nil
                || report.sevenDay?.utilization != nil
                || report.scoped.contains { $0.window.utilization != nil }
            return hasData ? report.maxUtilization : nil
```

- [ ] **Step 4:** `swift test` → all green.
- [ ] **Step 5:** `git add -A && git commit -m "Parse scoped weekly limits (Fable) from the usage limits array"`

---

### Task 2: Display + dead-field cleanup

**Files:**
- Modify: `Sources/PitStop/UsageAPI.swift` (remove `sevenDayOpus`/`sevenDaySonnet` + their parse lines)
- Modify: `Sources/PitStop/AppDelegate.swift` (`rowModel` Claude branch, `projectableWindows`, `statusTip`)
- Modify: `Sources/PitStop/main.swift` (`--preview` sample row)

**Interfaces:**
- Consumes: `UsageReport.scoped: [ScopedWindow]` from Task 1.

- [ ] **Step 1: Remove dead fields.** In `UsageReport`, delete `var sevenDayOpus: UsageWindow?` and `var sevenDaySonnet: UsageWindow?`; in `parse`, delete `report.sevenDayOpus = window(root["seven_day_opus"])` and `report.sevenDaySonnet = window(root["seven_day_sonnet"])` (both permanently null in the API).
- [ ] **Step 2: Row bars.** In `AppDelegate.rowModel`, Claude branch — replace the bars/extras block:

```swift
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
            if let r = report, r.extraUsageEnabled {
                extras.append("Extra \(Format.percent(r.extraUsageUtilization))")
            }
            dataDate = report?.fetchedAt
        }
```

(The `Opus wk` / `Sonnet wk` extras lines are gone — deleted with the fields.)

- [ ] **Step 3: Projections.** In `projectableWindows(forKey:)`, Claude branch:

```swift
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
```

- [ ] **Step 4: Tooltip.** In `statusTip(email:report:)`, after the 5-hour/weekly line:

```swift
        for s in report.scoped {
            tip += " · \(s.label) \(Format.percent(s.window.utilization))"
        }
```

- [ ] **Step 5: Preview sample.** In `main.swift` `--preview`, add a Fable bar to the first sample row (`asha@acme.dev`):

```swift
                  bars: [.init(label: "5h", utilization: 64, resetText: Format.compactReset(tonight)),
                         .init(label: "7d", utilization: 23, resetText: Format.compactReset(nextWeek)),
                         .init(label: "Fable", utilization: 13, resetText: Format.compactReset(nextWeek))],
```

- [ ] **Step 6:** `swift test` → green; `swift run -q PitStop --preview` and eyeball `/tmp/pitstop-preview.png` (three bars on the first row, "Fable" label right-aligned next to its bar).
- [ ] **Step 7:** `git add -A && git commit -m "Render scoped weekly limits as their own bars; drop dead Opus/Sonnet fields"`

---

## Final verification

- [ ] `swift build && swift test` — full suite green.
- [ ] `swift run PitStop --check` against the live account: the Claude section should work unchanged (the new parsing is exercised on the real payload during the app's normal refresh; `--check` prints 5h/weekly).
- [ ] Merge per finishing-a-development-branch; remind user to E2E-test the installed app (their workflow) — the visible change: a "Fable" bar on Claude rows once Fable has usage, and the menu bar % reacting to it.

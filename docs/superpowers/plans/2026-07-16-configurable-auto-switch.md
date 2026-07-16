# Configurable Auto-Switch Triggers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user choose which limit-window kinds (5-hour, weekly, per-model) may trigger an auto-switch — and rank its targets — via three checkboxes in Settings.

**Architecture:** A `LimitKind` enum lives in Settings.swift; each provider's usage type (`UsageReport`, `Codex.Usage`, `Gemini.Usage`) classifies its own windows and gains a `maxUtilization(kinds:) -> Double?` filtered view. `evaluateAutoSwitch` passes `Settings.autoSwitchKinds` (three UserDefaults bools, absent = enabled) into the existing utilization closures. Display code (`maxUtilization`, bars, notifications, projections) is untouched.

**Tech Stack:** Swift 6 toolchain / language mode v5, SwiftUI (settings window), XCTest, no dependencies.

**Spec:** `docs/superpowers/specs/2026-07-16-configurable-auto-switch-design.md`

## Global Constraints

- Platform floor: `.macOS("26.0")` (Package.swift) — do not change.
- No new package dependencies.
- UserDefaults keys, exactly: `autoSwitchOnSession`, `autoSwitchOnWeekly`, `autoSwitchOnPerModel`. Absent key reads as **enabled** (default all-on preserves today's behavior).
- Classification, verbatim from spec: Claude `fiveHour` → session, `sevenDay` → weekly, `scoped[]` → perModel; Codex label `"5h"` → session, `"7d"`/`"30d"`/anything else → weekly; Gemini every window → perModel.
- Filtering is symmetric: the same enabled kinds gate the trigger and rank targets. No enabled window with a number → `nil` → account neither triggers nor is a target.
- Scope: auto-switch only. The parameterless `maxUtilization` (menu bar, most-urgent, notifications, projections) must not change.
- Test command: `swift test --filter <ClassName>` from the repo root; full suite `swift test`.
- Commit after every task; do NOT push — the user E2E-tests the installed app first.

---

### Task 1: `LimitKind` + `Settings.autoSwitchKinds`

**Files:**
- Modify: `Sources/PitStop/Settings.swift`
- Test: `Tests/PitStopTests/AutoSwitchKindsTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `enum LimitKind: CaseIterable { case session, weekly, perModel }` and `Settings.autoSwitchKinds: Set<LimitKind>` (both in `Sources/PitStop/Settings.swift`). Tasks 2–5 use both. Also appends the three key strings to `Settings.observedKeys`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PitStopTests/AutoSwitchKindsTests.swift`:

```swift
import XCTest
@testable import PitStop

final class AutoSwitchKindsTests: XCTestCase {
    private let keys = ["autoSwitchOnSession", "autoSwitchOnWeekly", "autoSwitchOnPerModel"]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testAbsentKeysMeanAllKinds() {
        XCTAssertEqual(Settings.autoSwitchKinds, Set(LimitKind.allCases))
    }

    func testFalseKeyRemovesItsKind() {
        UserDefaults.standard.set(false, forKey: "autoSwitchOnPerModel")
        XCTAssertEqual(Settings.autoSwitchKinds, [.session, .weekly])
    }

    func testAllFalseIsEmpty() {
        keys.forEach { UserDefaults.standard.set(false, forKey: $0) }
        XCTAssertTrue(Settings.autoSwitchKinds.isEmpty)
    }

    func testExplicitTrueStillCounts() {
        UserDefaults.standard.set(true, forKey: "autoSwitchOnSession")
        UserDefaults.standard.set(false, forKey: "autoSwitchOnWeekly")
        XCTAssertEqual(Settings.autoSwitchKinds, [.session, .perModel])
    }

    func testObservedKeysIncludeTriggerKeys() {
        keys.forEach { XCTAssertTrue(Settings.observedKeys.contains($0)) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AutoSwitchKindsTests`
Expected: build FAILS with `cannot find 'LimitKind' in scope` / `type 'Settings' has no member 'autoSwitchKinds'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/PitStop/Settings.swift`, add above `enum Settings`:

```swift
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
```

Inside `enum Settings`, after `autoSwitchThreshold`:

```swift
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
```

Replace the `observedKeys` array:

```swift
    /// Keys AppDelegate watches to refresh the UI when settings change.
    static let observedKeys = [
        "indicatorStyle", "indicatorMetric", "menuBarSource",
        "autoSwitchEnabled", "autoSwitchThreshold", "showProjection",
        "autoSwitchOnSession", "autoSwitchOnWeekly", "autoSwitchOnPerModel",
    ]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AutoSwitchKindsTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/Settings.swift Tests/PitStopTests/AutoSwitchKindsTests.swift
git commit -m "Add LimitKind and Settings.autoSwitchKinds trigger preference"
```

---

### Task 2: `UsageReport.maxUtilization(kinds:)` (Claude)

**Files:**
- Modify: `Sources/PitStop/UsageAPI.swift` (the `UsageReport` struct, lines ~16-37)
- Test: `Tests/PitStopTests/LimitKindFilterTests.swift` (create)

**Interfaces:**
- Consumes: `LimitKind` from Task 1.
- Produces: `UsageReport.maxUtilization(kinds: Set<LimitKind>) -> Double?`. Task 5 calls it. The existing parameterless `maxUtilization` computed property stays untouched.

- [ ] **Step 1: Write the failing test**

Create `Tests/PitStopTests/LimitKindFilterTests.swift`:

```swift
import XCTest
@testable import PitStop

/// maxUtilization(kinds:) — auto-switch's filtered view of each provider's
/// usage. nil means "no enabled window reports a number": never a trigger,
/// never a target.
final class LimitKindFilterTests: XCTestCase {
    // MARK: Claude (UsageReport)

    private func claudeReport(fiveHour: Double? = nil, sevenDay: Double? = nil,
                              scoped: [(String, Double)] = []) -> UsageReport {
        var r = UsageReport()
        if let fiveHour { r.fiveHour = UsageWindow(utilization: fiveHour, resetsAt: nil) }
        if let sevenDay { r.sevenDay = UsageWindow(utilization: sevenDay, resetsAt: nil) }
        r.scoped = scoped.map {
            ScopedWindow(label: $0.0, window: UsageWindow(utilization: $0.1, resetsAt: nil))
        }
        return r
    }

    func testClaudeFullSetMatchesBindingMax() {
        let r = claudeReport(fiveHour: 10, sevenDay: 20, scoped: [("Fable", 95)])
        XCTAssertEqual(r.maxUtilization(kinds: Set(LimitKind.allCases)), 95)
        XCTAssertEqual(r.maxUtilization(kinds: Set(LimitKind.allCases)), r.maxUtilization)
    }

    func testClaudeDisabledPerModelIgnoresHotFable() {
        let r = claudeReport(fiveHour: 10, sevenDay: 20, scoped: [("Fable", 95)])
        XCTAssertEqual(r.maxUtilization(kinds: [.session, .weekly]), 20)
    }

    func testClaudeSessionOnly() {
        let r = claudeReport(fiveHour: 64, sevenDay: 80, scoped: [("Fable", 95)])
        XCTAssertEqual(r.maxUtilization(kinds: [.session]), 64)
    }

    func testClaudeNoEnabledWindowWithDataIsNil() {
        let r = claudeReport(scoped: [("Fable", 95)])
        XCTAssertNil(r.maxUtilization(kinds: [.session, .weekly]))
    }

    func testClaudeWindowWithoutNumberDoesNotCount() {
        var r = claudeReport(sevenDay: 20)
        r.fiveHour = UsageWindow(utilization: nil, resetsAt: nil)
        XCTAssertEqual(r.maxUtilization(kinds: [.session, .weekly]), 20)
        XCTAssertNil(r.maxUtilization(kinds: [.session]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LimitKindFilterTests`
Expected: build FAILS with `value of type 'UsageReport' has no member 'maxUtilization(kinds:)'` (the parameterless property exists; the method doesn't).

- [ ] **Step 3: Write minimal implementation**

In `Sources/PitStop/UsageAPI.swift`, inside `struct UsageReport` after the `bindingWindow` property:

```swift
    /// Auto-switch's filtered view: the max utilization over windows of the
    /// enabled kinds that report a number, or nil when none does — callers
    /// treat nil as "no trustworthy data" (never a trigger, never a target).
    func maxUtilization(kinds: Set<LimitKind>) -> Double? {
        var values: [Double] = []
        if kinds.contains(.session), let u = fiveHour?.utilization { values.append(u) }
        if kinds.contains(.weekly), let u = sevenDay?.utilization { values.append(u) }
        if kinds.contains(.perModel) { values += scoped.compactMap(\.window.utilization) }
        return values.max()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LimitKindFilterTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/UsageAPI.swift Tests/PitStopTests/LimitKindFilterTests.swift
git commit -m "Add kind-filtered maxUtilization to UsageReport"
```

---

### Task 3: `Codex.Usage.maxUtilization(kinds:)`

**Files:**
- Modify: `Sources/PitStop/Codex.swift` (the `Usage` struct, lines ~34-44)
- Test: `Tests/PitStopTests/LimitKindFilterTests.swift` (extend — created in Task 2)

**Interfaces:**
- Consumes: `LimitKind` from Task 1; `Codex.Usage`/`Codex.Usage.Window` as they exist (`label: String`, `usedPercent: Double`, `resetsAt: Date?`).
- Produces: `Codex.Usage.maxUtilization(kinds: Set<LimitKind>) -> Double?`. Task 5 calls it.

- [ ] **Step 1: Write the failing test**

Append inside `final class LimitKindFilterTests` in `Tests/PitStopTests/LimitKindFilterTests.swift`:

```swift
    // MARK: Codex

    private func codexUsage(_ windows: [(String, Double)]) -> Codex.Usage {
        Codex.Usage(windows: windows.map {
            .init(label: $0.0, usedPercent: $0.1, resetsAt: nil)
        })
    }

    func testCodexFiveHourIsSession() {
        let u = codexUsage([("5h", 91), ("7d", 40)])
        XCTAssertEqual(u.maxUtilization(kinds: [.session]), 91)
        XCTAssertEqual(u.maxUtilization(kinds: [.weekly]), 40)
    }

    func testCodexThirtyDayCountsAsWeekly() {
        let u = codexUsage([("30d", 77)])
        XCTAssertEqual(u.maxUtilization(kinds: [.weekly]), 77)
        XCTAssertNil(u.maxUtilization(kinds: [.session]))
    }

    func testCodexUnknownLabelFallsToWeekly() {
        let u = codexUsage([("90d", 55)])
        XCTAssertEqual(u.maxUtilization(kinds: [.weekly]), 55)
        XCTAssertNil(u.maxUtilization(kinds: [.session, .perModel]))
    }

    func testCodexPerModelNeverMatches() {
        let u = codexUsage([("5h", 91), ("7d", 40)])
        XCTAssertNil(u.maxUtilization(kinds: [.perModel]))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LimitKindFilterTests`
Expected: build FAILS with `value of type 'Codex.Usage' has no member 'maxUtilization(kinds:)'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/PitStop/Codex.swift`, inside `struct Usage` after the `maxUtilization` property:

```swift
        /// Auto-switch's filtered view. Codex windows are account-wide
        /// duration windows: "5h" is the session kind; "7d"/"30d" — and
        /// anything unrecognized — count as weekly, the safer long-window
        /// bucket. nil when no enabled window exists.
        func maxUtilization(kinds: Set<LimitKind>) -> Double? {
            windows.filter { kinds.contains($0.label == "5h" ? .session : .weekly) }
                .map(\.usedPercent).max()
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LimitKindFilterTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/Codex.swift Tests/PitStopTests/LimitKindFilterTests.swift
git commit -m "Add kind-filtered maxUtilization to Codex.Usage"
```

---

### Task 4: `Gemini.Usage.maxUtilization(kinds:)`

**Files:**
- Modify: `Sources/PitStop/Gemini.swift` (the `Usage` struct, lines ~166-171)
- Test: `Tests/PitStopTests/LimitKindFilterTests.swift` (extend — created in Task 2)

**Interfaces:**
- Consumes: `LimitKind` from Task 1; `Gemini.Usage`/`Gemini.Usage.Window` as they exist (`label: String`, `usedPercent: Double`, `resetsAt: Date?`).
- Produces: `Gemini.Usage.maxUtilization(kinds: Set<LimitKind>) -> Double?`. Task 5 calls it.

- [ ] **Step 1: Write the failing test**

Append inside `final class LimitKindFilterTests` in `Tests/PitStopTests/LimitKindFilterTests.swift`:

```swift
    // MARK: Gemini

    func testGeminiWindowsArePerModel() {
        let u = Gemini.Usage(windows: [.init(label: "2.5 Pro", usedPercent: 88, resetsAt: nil)])
        XCTAssertEqual(u.maxUtilization(kinds: [.perModel]), 88)
        XCTAssertNil(u.maxUtilization(kinds: [.session, .weekly]))
    }

    func testGeminiNoWindowsIsNil() {
        XCTAssertNil(Gemini.Usage(windows: []).maxUtilization(kinds: Set(LimitKind.allCases)))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LimitKindFilterTests`
Expected: build FAILS with `value of type 'Gemini.Usage' has no member 'maxUtilization(kinds:)'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/PitStop/Gemini.swift`, inside `struct Usage` after the `maxUtilization` property:

```swift
        /// Auto-switch's filtered view. Every Gemini window is a per-model
        /// daily quota, so only the perModel kind exposes them — with it
        /// unchecked, Gemini auto-switch never triggers and Gemini accounts
        /// are never targets.
        func maxUtilization(kinds: Set<LimitKind>) -> Double? {
            kinds.contains(.perModel) ? windows.map(\.usedPercent).max() : nil
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LimitKindFilterTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/Gemini.swift Tests/PitStopTests/LimitKindFilterTests.swift
git commit -m "Add kind-filtered maxUtilization to Gemini.Usage"
```

---

### Task 5: Wire kinds into `evaluateAutoSwitch`

**Files:**
- Modify: `Sources/PitStop/AppDelegate.swift:1173-1196` (`evaluateAutoSwitch`)

**Interfaces:**
- Consumes: `Settings.autoSwitchKinds` (Task 1); `maxUtilization(kinds:)` on all three usage types (Tasks 2–4).
- Produces: behavior only — the `autoSwitch` helper and `performSwitch`/`performCodexSwitch`/`performGeminiSwitch` signatures are unchanged.

- [ ] **Step 1: Replace the utilization closures**

`evaluateAutoSwitch` currently reads (AppDelegate.swift:1173-1196):

```swift
    /// When enabled, flip each switchable provider's live account to the saved
    /// account with the most headroom once the live one crosses the threshold.
    /// Desktop is read-only, so it's left alone.
    private func evaluateAutoSwitch() {
        guard Settings.autoSwitchEnabled else { return }
        autoSwitch(provider: .claude, live: activeEmail,
                   candidates: store.profiles.map(\.email),
                   utilization: { fetchError[$0] == nil ? usage[$0]?.maxUtilization : nil },
                   perform: { performSwitch(to: $0, auto: true, reason: $1) })
        autoSwitch(provider: .codex, live: codexLiveEmail,
                   candidates: codexStore.profiles.map(\.email),
                   utilization: {
                       let key = "codex:\($0)"
                       return fetchError[key] == nil ? codexUsage[key]?.maxUtilization : nil
                   },
                   perform: { performCodexSwitch(to: $0, auto: true, reason: $1) })
        autoSwitch(provider: .gemini, live: geminiLiveCliEmail,
                   candidates: geminiStore.profiles.map(\.email),
                   utilization: {
                       let key = "gemini:\($0)"
                       return fetchError[key] == nil ? geminiUsage[key]?.maxUtilization : nil
                   },
                   perform: { performGeminiSwitch(to: $0, auto: true, reason: $1) })
    }
```

Replace with:

```swift
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
```

(Optional chaining flattens: `usage[$0]?.maxUtilization(kinds: kinds)` is `Double?`, matching the closure's return type.)

- [ ] **Step 2: Build and run the full suite**

Run: `swift build && swift test`
Expected: build succeeds; all tests PASS (no behavior change while all kinds are enabled — the filtered max over the full set equals the binding max whenever any window has data; an account with windows but no numbers now reads as nil instead of 0, which only makes auto-switch more conservative).

- [ ] **Step 3: Commit**

```bash
git add Sources/PitStop/AppDelegate.swift
git commit -m "Gate auto-switch trigger and target ranking by enabled limit kinds"
```

---

### Task 6: Settings window checkboxes

**Files:**
- Modify: `Sources/PitStop/SettingsWindow.swift:13-39` (`SettingsView` properties + Auto-switch section)

**Interfaces:**
- Consumes: the UserDefaults keys from Task 1 (`autoSwitchOnSession`, `autoSwitchOnWeekly`, `autoSwitchOnPerModel`) via `@AppStorage` — same-key binding is how the settings window and `Settings` already share state.
- Produces: UI only.

- [ ] **Step 1: Add the three @AppStorage properties**

In `SettingsView`, after the `threshold` property (line 14):

```swift
    @AppStorage("autoSwitchOnSession") private var triggerSession = true
    @AppStorage("autoSwitchOnWeekly") private var triggerWeekly = true
    @AppStorage("autoSwitchOnPerModel") private var triggerPerModel = true
```

- [ ] **Step 2: Add the toggles and extend the caption**

Replace the Auto-switch section (currently lines 32-39):

```swift
            Section("Auto-switch") {
                Toggle("Auto-switch when an account runs low", isOn: $autoSwitch)
                if autoSwitch {
                    Stepper("Switch at \(threshold)% used", value: $threshold, in: 50 ... 99, step: 5)
                    Toggle("Trigger on the 5-hour limit", isOn: $triggerSession)
                    Toggle("Trigger on weekly limits (7d / 30d)", isOn: $triggerWeekly)
                    Toggle("Trigger on per-model limits (Fable, Gemini quotas)", isOn: $triggerPerModel)
                }
                Text("Flips the live account of each switchable provider — Claude Code, Codex, and Gemini (CLI + Antigravity) — to the one with the most headroom, and notifies you. Claude Desktop is read-only, so it's left alone. Gemini's limits are all per-model, so unchecking per-model limits turns Gemini auto-switch off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

(Plain form-row toggles instead of the mockup's indented "Trigger on:" group — native grouped-Form idiom, matching every other row in this window. Visual check happens in Task 8.)

- [ ] **Step 3: Build and run the full suite**

Run: `swift build && swift test`
Expected: build succeeds; all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/PitStop/SettingsWindow.swift
git commit -m "Add auto-switch trigger checkboxes to Settings"
```

---

### Task 7: README + CHANGELOG

**Files:**
- Modify: `README.md:103-107` (Auto-switch bullet)
- Modify: `CHANGELOG.md` (`[Unreleased]` section, line 7)

**Interfaces:**
- Consumes: nothing — prose only.
- Produces: nothing later tasks rely on.

- [ ] **Step 1: Update the README auto-switch bullet**

Replace lines 103-107:

```markdown
- **Auto-switch** (off by default) flips a switchable provider's live account
  — Claude Code, Codex, or Gemini — to the saved account with the most
  headroom once the live one crosses a configurable threshold, and notifies
  you. Checkboxes pick which limit kinds count — 5-hour, weekly, per-model
  (Fable, Gemini quotas) — for both the trigger and the target ranking. It
  only moves onto accounts with trustworthy fresh data, and a per-provider
  cooldown prevents flapping; Desktop is read-only and left alone.
```

(Also fixes the stale "Claude Code or Codex" — Gemini has been switchable since the Gemini provider landed.)

- [ ] **Step 2: Add the CHANGELOG entry**

Under `## [Unreleased]`:

```markdown
## [Unreleased]
### Added
- **Choose which limits trigger auto-switch.** Settings gains trigger
  checkboxes — 5-hour, weekly (7d/30d), and per-model (Fable, Gemini
  quotas). Disabled kinds are ignored symmetrically: they neither pull the
  trigger nor count when ranking the account to switch to. All kinds stay
  enabled by default. Gemini's limits are all per-model, so unchecking
  per-model turns Gemini auto-switch off.
```

- [ ] **Step 3: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "Document configurable auto-switch triggers"
```

---

### Task 8: E2E verification in the built app

**Files:** none (verification only). Follow the project's verify skill: `.claude/skills/verify/SKILL.md`.

- [ ] **Step 1: Build the release app**

Run: `./scripts/make-app.sh`
Expected: release build succeeds, app lands in `/Applications/PitStop.app`.

- [ ] **Step 2: Headless data-layer check**

Run: `.build/release/PitStop --check`
Expected: accounts and live usage print to stdout with no errors — confirms the usage/report plumbing still works end to end.

- [ ] **Step 3: Settings window visual check**

Launch the app, open Settings (⌘,), enable "Auto-switch when an account runs low".
Expected: the stepper plus the three trigger toggles appear, all on; the caption ends with the Gemini per-model sentence; toggling any checkbox persists across a settings-window close/reopen (backed by UserDefaults).

- [ ] **Step 4: Defaults sanity check**

Run: `defaults read com.livinmathew.PitStop 2>/dev/null | grep -i autoSwitchOn || true`
(If the bundle id differs, find it with `defaults domains | tr ',' '\n' | grep -i pitstop`.)
Expected: keys appear only after a checkbox has been toggled off/on; absent keys are the all-enabled default.

- [ ] **Step 5: Hand off for user E2E**

Do NOT push. Report completion to the user — per project practice they E2E-test the installed app before any push/release. The spec's live scenario is theirs to confirm: with per-model unchecked and a genuinely hot Fable window, no auto-switch fires; a hot 5-hour window still switches. (The filtering logic itself is covered by `LimitKindFilterTests`; there is no supported way to simulate hot usage windows headlessly.)

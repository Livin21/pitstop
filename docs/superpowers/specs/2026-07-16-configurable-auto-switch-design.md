# Configurable Auto-Switch Triggers — Design

**Date:** 2026-07-16
**Status:** Approved

## Problem

Auto-switch fires when the live account's binding utilization — the max across
**all** its limit windows — crosses the threshold. Since the scoped-limits
change (2026-07-02 spec), that includes per-model weekly limits like Fable. So
a hot Fable bar switches you off an account whose 5-hour and weekly windows are
nearly empty, even though only that one model is capped. There is no way to
configure which limit windows participate in the auto-switch decision.

## Decisions (user-approved)

1. **Per-window-kind checkboxes**, not a preset picker or a single
   ignore-Fable toggle: independent "Trigger on" toggles for 5-hour, weekly,
   and per-model limits under the existing Auto-switch settings.
2. **Symmetric filtering:** the enabled kinds govern both the trigger (when to
   leave the live account) and the target ranking (where to go). A candidate
   whose only hot window is a disabled kind counts as wide open.
3. **Best-effort mapping across all providers**, not Claude-only: the same
   three checkboxes gate Codex and Gemini windows via classification.
4. **Defaults all on** — existing users keep today's behavior.
5. **Auto-switch only:** menu bar %, most-urgent pick, 80/95% notifications,
   and projections keep using the unfiltered binding max.

## Data model

New `LimitKind` enum, in Settings.swift (it's a preference vocabulary, and
Settings is the one file all three providers already import):

```swift
enum LimitKind: CaseIterable { case session, weekly, perModel }
```

Classification per provider, next to each usage type:

| Provider | Window            | Kind      |
|----------|-------------------|-----------|
| Claude   | `fiveHour`        | session   |
| Claude   | `sevenDay`        | weekly    |
| Claude   | `scoped[]` (Fable, …) | perModel |
| Codex    | label `"5h"`      | session   |
| Codex    | label `"7d"`, `"30d"`, anything else | weekly |
| Gemini   | every window (per-model daily quotas) | perModel |

Unrecognized Codex labels fall into `weekly` — the safer, less trigger-happy
bucket for long windows.

Each usage type (`UsageReport`, `Codex.Usage`, `Gemini.Usage`) gains:

```swift
func maxUtilization(kinds: Set<LimitKind>) -> Double?
```

— the max utilization over windows of the enabled kinds **that report a
number**, or `nil` when no enabled window has data. The existing parameterless
`maxUtilization` (display/binding) is untouched.

## Settings

Three new UserDefaults bools, default `true` (absent key reads as enabled):

- `autoSwitchOnSession`
- `autoSwitchOnWeekly`
- `autoSwitchOnPerModel`

Exposed as `Settings.autoSwitchKinds: Set<LimitKind>`. All three keys are
added to `Settings.observedKeys` so toggling re-evaluates the menu/auto-switch
immediately.

## Auto-switch semantics

In `evaluateAutoSwitch`, each provider's `utilization` closure returns
`maxUtilization(kinds: Settings.autoSwitchKinds)` (still `nil` on fetch
errors, as today). The `autoSwitch` helper itself is unchanged — its existing
nil-guards give the right behavior:

- Live account with no enabled-kind data → never triggers.
- Candidate with no enabled-kind data → never picked as a target.

Consequences (by design, documented in the UI caption):

- Unchecking **Per-model** disables Gemini auto-switch entirely (all Gemini
  windows are per-model).
- Unchecking all three disables auto-switch for every provider.

## UI (SettingsWindow)

Inside the existing `if autoSwitch` block, after the threshold stepper:

```
Trigger on:
☑ 5-hour limit
☑ Weekly limits (7d / 30d)
☑ Per-model limits (Fable, Gemini quotas)
```

The existing auto-switch caption gains one sentence: "Gemini's limits are all
per-model, so unchecking per-model limits turns Gemini auto-switch off."

## Testing

- `maxUtilization(kinds:)` unit tests for all three usage types:
  - filtering picks the max among enabled kinds only
  - disabled hot window doesn't leak into the result
  - no enabled window with data → `nil`
  - full set behaves like today's binding max
- Codex label classification, including an unknown label landing in `weekly`.
- `Settings.autoSwitchKinds` maps the three bools (and absent keys → enabled).
- E2E in the installed app before merge (verify skill): toggle per-model off,
  simulate a hot Fable window, confirm no switch; hot 5-hour window still
  switches.

## Out of scope

- Per-provider checkbox sections (one global set of three, best-effort mapped)
- Per-window thresholds (single threshold stays)
- Any change to menu bar metric, most-urgent, notifications, projections
- Per-account opt-outs from auto-switch

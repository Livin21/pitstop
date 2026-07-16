# Changelog

All notable changes to PitStop are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); release notes also
appear on [GitHub Releases](https://github.com/Livin21/pitstop/releases).

## [Unreleased]
### Added
- **Choose which limits trigger auto-switch.** Settings gains trigger
  checkboxes — 5-hour, weekly (7d/30d), and per-model (Fable, Gemini
  quotas). Disabled kinds are ignored symmetrically: they neither pull the
  trigger nor count when ranking the account to switch to. All kinds stay
  enabled by default. Gemini's limits are all per-model, so unchecking
  per-model turns Gemini auto-switch off.
- **Session warming.** Opt-in: during configured hours (default 6 AM–6 PM),
  PitStop starts a 5-hour session on every saved Claude account whenever
  none is running, so limit resets land inside your day instead of at its
  end. One ~1-token request per account per session; caps are unaffected —
  it only chooses when the session clock starts.

### Fixed
- **Blank panel after a relaunch that hit a rate limit.** Usage data lived
  only in memory, so a launch whose very first fetch got a 429 had nothing
  to show — every row collapsed to "Rate limited" with no bars for up to
  15 minutes. The display state (usage bars, fetch errors, retry backoffs,
  Desktop identity) now persists to `~/.config/pitstop/usage-cache.json`
  after each refresh and is restored on launch, so a rate-limited start
  degrades to the existing stale-data treatment ("⚠︎ Rate limited · showing
  12:40 data") instead of a blank panel. Restored state ages out after a
  day, and a relaunch no longer re-fetches accounts that were mid-backoff —
  the relaunch itself stops feeding the rate limiter.

## [0.4.2] - 2026-07-06
### Fixed
- **Two Claude accounts could report the same usage.** Saving an account
  pairs credentials from the keychain with an identity from `~/.claude.json`
  — two stores Claude Code writes at different moments. A read that landed
  mid-switch (an external `claude /login`, or PitStop's own switch racing a
  refresh) filed one account's tokens under the other's email, and both rows
  then fetched the same account forever. Captures now confirm the token's
  owner with the identity endpoint before filing (refreshing an expired token
  first), account switches and refresh cycles are serialized so their
  keychain/config reads can't interleave, and a once-per-launch audit deletes
  already-poisoned saved credentials and gates the row with "Was showing
  <owner>'s usage — sign in again" instead of double-reporting.

## [0.4.1] - 2026-07-02
### Changed
- Transient fetch errors (e.g. a rate limit) with data under 10 minutes old
  now render as a muted info line without the "showing … data" caveat — the
  orange ⚠︎ is reserved for needs-action errors and genuinely stale data.
  Stale-data timestamps no longer include seconds.
- The "on pace to hit limit" projection only appears once a window is ≥25%
  used or the projected limit is within 3 hours, so a barely-used window
  can't cry wolf.
- The live Codex row waiting on a fresh token shows its last-known usage
  bars dimmed with a "Last seen …" stamp, instead of a sentence about
  PitStop's token mechanics and no bars.

### Fixed
- Dangling "Extra –" on rows where extra usage is enabled but reports no
  utilization yet.
- Long bar labels (Gemini model names like "2.5-flash-lite") no longer spill
  into the leading margin — labels get a real gutter and the row's bars
  shift right with a fixed right edge, keeping the % and reset columns
  aligned across rows.

## [0.4.0] - 2026-07-02
### Added
- **Per-model scoped weekly limits** (e.g. **Fable**), parsed from the usage
  API's new `limits` array and shown as their own labelled bar on Claude rows.
  They count toward the binding number, so the menu bar %, most-urgent
  tracking, auto-switch, threshold notifications, and projections all react.
  One parser covers both Claude Code and Claude Desktop rows, and future
  scoped limits appear automatically.
- Keychain reads recover credentials stranded in the `#staging` item after a
  crash mid-write.
- Single-instance lock: a second PitStop (e.g. a dev binary) exits at launch
  instead of fighting over the live credential files.

### Fixed
- **Gemini switching corrupted `~/.gemini/oauth_creds.json`.** Snapshots are
  now normalized before keychain storage (multi-line secrets read back
  hex-encoded), already-corrupted entries heal on read, and Antigravity-only
  switches update the active Google email so tokens can't be filed under the
  wrong account.
- Codex switches preserve an API-key-only `auth.json` instead of destroying
  it; a half-failed Claude switch rolls the live keychain item back.
- An external re-login (`claude` / `codex` / Gemini) heals a "re-login
  needed" row within one refresh cycle instead of waiting out the 1-hour
  backoff; the Desktop usage fallback no longer clears the Code account's
  error state (which retried a dead refresh token every 2 minutes and hid the
  Login button).
- OAuth logins survive stray browser connections (preconnects, favicon
  fetches) that previously consumed the single-use code and reported a
  spurious "timed out"; clicking **Deny** on the consent page now reads as a
  cancel instead of success; a non-JSON 200 from the token host is no longer
  retried against the second host with the same code; the paste window's
  close button no longer crashes the app.
- Ghost usage from removed or signed-out accounts no longer drives the
  most-urgent menu bar reading; refreshes requested while one is in flight
  run afterward instead of being dropped.
- The rebuild-from-source updater can no longer deadlock on long build output.
- Antigravity token expiry timestamps with fractional seconds parse correctly
  (previously refreshed against Google every cycle); the Gemini "no Code
  Assist project" state clears on refresh / re-login instead of sticking
  until relaunch.
- Live credential file writes preserve dotfile symlinks; sub-minute reset
  countdowns show "<1m" instead of "0m"; bar colors match the displayed
  (rounded) percentage; notification banners appear while PitStop is the
  active app; the launch-at-login toggle stays in sync with System Settings;
  menu row views no longer leak on rebuild.

### Changed
- The auto-switch setting copy now discloses it covers Gemini
  (CLI + Antigravity), which it always did.

### Removed
- The "Opus wk / Sonnet wk" extras line — the API retired those fields;
  per-model scoped limits replace them.

## [0.3.1] - 2026-07-01
### Added
- External-link icon (↗) on each provider section header (Claude, Codex, Gemini)
  that opens the provider's usage dashboard in the browser.

## [0.3.0] - 2026-07-01
### Added
- **In-app re-login.** Expired accounts show a coral **Login** button that
  re-authenticates in the browser without disturbing a running Claude Code /
  Codex session — fresh credentials are written only to the saved profile, never
  the live account. Claude uses an automatic localhost callback with a
  code-paste fallback; Codex is fully automatic.
- **Google Gemini provider (Gemini CLI + Antigravity).** One "Gemini" row per
  Google account (tagged `CLI · Antigravity`) with live per-model Code Assist
  usage and reset times, one-click switching of both surfaces together,
  auto-switch, and in-app re-login.

## [0.2.1] - 2026-06-17
### Changed
- Per-window usage projection now uses a robust least-squares slope instead of a
  blended max, so the "on pace to hit limit" estimate is steadier.

## [0.2.0] - 2026-06-17
First versioned release.
### Added
- Multi-provider menu grouped by provider: **Claude Code**, **Claude Desktop**
  (observe-only), and **OpenAI Codex**.
- One-click **account switching** and opt-in **auto-switch** when the live
  account crosses a threshold.
- Usage projection ("on pace to hit limit …") and a **Settings** window.
- In-app versioning and a daily GitHub-release update check with one-click
  rebuild-from-source ("Update & Relaunch").
### Fixed
- Fall back to Desktop usage when a merged account's Claude Code fetch fails.

[Unreleased]: https://github.com/Livin21/pitstop/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/Livin21/pitstop/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Livin21/pitstop/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/Livin21/pitstop/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/Livin21/pitstop/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/Livin21/pitstop/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Livin21/pitstop/releases/tag/v0.2.0

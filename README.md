<p align="center">
  <img src="docs/icon.png" width="128" alt="PitStop icon">
</p>

# PitStop

macOS menu bar app that shows your Claude Code account's **usage limits** and
lets you **switch between Claude accounts** with one click — so when one
account hits its 5-hour or weekly rate limit, you flip to another and your
work keeps going.

<p align="center">
  <img src="docs/menu.png" width="465" alt="PitStop menu: two accounts with color-coded usage bars">
</p>

The coral dot marks the active account; hovering an inactive row flips its
plan chip into a coral **Switch** pill — click to switch. Rows are sorted
active-first, then by headroom (the emptiest account next — the one you'd
switch to). The menu bar shows the active account's binding limit,
color-coded.

## Quickstart

Using an AI agent? Copy this prompt into Claude Code (or any agent that can
run shell commands) on the target Mac:

```text
Install and set up PitStop (https://github.com/Livin21/pitstop), a macOS
menu bar app that shows Claude Code usage limits and switches between
Claude accounts, on this Mac.

1. Verify requirements: macOS 26+, Xcode Command Line Tools
   (xcode-select --install), and Claude Code installed and logged in.
   Stop and tell me if any are missing.
2. Clone the repo and run ./scripts/make-app.sh — it builds and installs
   /Applications/PitStop.app. Then `open /Applications/PitStop.app`.
3. You cannot interact with macOS security dialogs — walk me through
   them instead: when PitStop first reads the Claude Code credentials,
   macOS may ask for my login keychain password. I'll enter it and click
   "Always Allow" (plain "Allow" makes the prompt come back). The grant
   is one-time; it survives rebuilds.
4. Verify: a checkered-flag icon appears in the menu bar showing my
   usage percentage, and `.build/release/PitStop --check` prints my
   account with live usage numbers.
5. Tell me how to add a second account: run /login in Claude Code and
   sign in with the other account — PitStop saves it within 2 minutes
   (or via "Save Current Account" in the menu). I'll also click "Allow"
   on the notification prompt the first time it warns about usage.
```

Or set it up manually:

1. Requirements: **macOS 26+**, Xcode Command Line Tools, and Claude Code
   logged in at least once.
2. Build and install:
   ```sh
   git clone https://github.com/Livin21/pitstop && cd pitstop
   ./scripts/make-app.sh
   open /Applications/PitStop.app
   ```
3. When macOS asks for your login keychain password, enter it and click
   **Always Allow** — one-time; see [Caveats](#caveats).
4. Add more accounts per [Adding a second account](#adding-a-second-account).

## How it works

- **Usage** comes from Anthropic's OAuth usage endpoint
  (`api.anthropic.com/api/oauth/usage`), called with the same OAuth token
  Claude Code uses. Refreshes every 2 min (debounced on menu open), with
  exponential backoff honoring `Retry-After` when Anthropic rate-limits,
  retrying as soon as the backoff window expires; the last good numbers
  stay visible (dimmed, "as of …") during outages.
- **Menu bar number** is the active account's binding constraint —
  `max(5-hour, weekly)` utilization, with a warning dot from 75 % (🟠)
  and 90 % (🔴). (Dots rather than colored text: macOS repaints menu
  bar items in a single wallpaper-matched ink, and emoji are the only
  glyphs that keep their color.) The **Menu Bar Display** submenu
  customizes it: icon & percent / icon only / percent only, and which
  limit drives the number (highest / 5-hour / weekly).
- **Notifications** fire when the active account crosses 80 % and 95 %,
  with the reset time, so you can switch before sessions stall.
- **Accounts** are snapshots of the Claude Code credential blob:
  - secrets live in the **keychain** (service `PitStop-profile`, one item
    per account email) — never written to disk;
  - non-secret identity (email, org, plan) lives in
    `~/.config/pitstop/profiles.json`.
- **All keychain access goes through `/usr/bin/security`** — the same CLI
  Claude Code shells out to. One "Always Allow" grant (enter the keychain
  password when prompted) covers both apps and survives PitStop rebuilds,
  since the requester is the stable Apple-signed `security` binary rather
  than the re-signed app bundle. Trade-off: writes pass the blob via argv
  (briefly visible in the process list) — same exposure Claude Code has.
- **Switching** writes the chosen account's blob back into the live
  `Claude Code-credentials` keychain item and restores its `oauthAccount`
  identity in `~/.claude.json`. The whole blob is swapped, so per-account MCP
  OAuth tokens (e.g. Atlassian) move with it.
- **Stale tokens** of saved (inactive) accounts are refreshed automatically
  via the standard OAuth refresh grant against Claude Code's public client,
  and the refreshed tokens are stored back. The *active* account is never
  refreshed by PitStop — Claude Code keeps it fresh itself (PitStop only
  steps in as a fallback if it finds the live token already expired).

## Adding a second account

1. PitStop auto-saves whatever account Claude Code is logged into.
2. In Claude Code, run `/login` and sign in with the **other** account.
3. PitStop notices the new account on its next refresh and saves it too
   (or click **Save Current Account**).
4. Both accounts now appear in the menu — click either to switch.

## What switching means for running sessions

Claude Code holds its access token in memory. After a switch:

- **New sessions** use the new account immediately.
- **Running sessions** keep working on the old account's token until it
  expires (tokens are short-lived), then re-read the keychain and continue on
  the new account. No restarts needed.

## Development

`./scripts/make-app.sh` builds release and installs
`/Applications/PitStop.app`. Useful flags on the bare binary:

- `--check` — print accounts and live usage to stdout, no GUI.
- `--preview` — render sample account rows to `/tmp/pitstop-preview.png`
  for iterating on the row design.
- `--screenshot` — run the app with sample addresses in place of real
  emails, for README captures.

The app icon (usage gauge with a coral needle nearing the red zone, over a
checkered pit-lane strip) is drawn programmatically — regenerate
`Resources/AppIcon.icns` after design tweaks with:

```sh
swift scripts/make-icon.swift
```

### Caveats

- Keychain prompts are **one-time per item**: when `security` first touches
  an item it isn't yet allowed on, macOS asks for the login keychain
  password — enter it and click **Always Allow** (plain "Allow" grants once
  and the prompt returns). Because access rides the Apple-signed `security`
  CLI, rebuilds of PitStop do **not** re-trigger prompts.
- `~/.claude.json` is rewritten on switch (only the `oauthAccount` key is
  changed, but the file is re-serialized). Claude Code rewrites this file
  constantly itself; a concurrent write race is theoretically possible but
  the window is milliseconds.
- The usage endpoint and refresh flow are the same unofficial OAuth surface
  Claude Code itself uses; if Anthropic changes them, update `UsageAPI.swift`.

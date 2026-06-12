# PitStop

macOS menu bar app that shows your Claude Code account's **usage limits** and
lets you **switch between Claude accounts** with one click — so when one
account hits its 5-hour or weekly rate limit, you flip to another and your
work keeps going.

```
┌────────────────────────────────────────────────────┐
│  ⚑ 23%                                             │  ← menu bar: binding limit, color-coded
├────────────────────────────────────────────────────┤
│  Claude Code Usage                                 │
│  ● asha@work.com                  [Acme AI·Team·5x]│  ← active: coral dot
│     5h ██░░░░░░░░ 20%   9:49 PM · 3h 34m           │  ← colored bars:
│     7d ██░░░░░░░░ 23%   Thu 10:29 AM · 5d 16h      │    green/orange/red
│  personal@gmail.com                       [Switch] │  ← hover: coral pill,
│     5h █████████░ 96%   7:40 PM · 1h 24m           │    click to switch
│     7d ████░░░░░░ 36%   Sun 5:30 AM · 1d 11h       │
│  ────────────────────────────────────────────────  │
│  Save Current Account                        ⌘S    │
│  Remove Account                              ▸     │
│  Refresh Now                                 ⌘R    │
│      Updated 6:15 PM · refreshes every 2 min       │
│  Launch at Login                                   │
│  Quit PitStop                                ⌘Q    │
└────────────────────────────────────────────────────┘
```

Rows are sorted active-first, then by headroom (the emptiest account next —
the one you'd switch to). Iterate on the row design with
`.build/debug/PitStop --preview` → `/tmp/pitstop-preview.png`.

## How it works

- **Usage** comes from Anthropic's OAuth usage endpoint
  (`api.anthropic.com/api/oauth/usage`), called with the same OAuth token
  Claude Code uses. Refreshes every 2 min (debounced on menu open), with
  exponential backoff honoring `Retry-After` when Anthropic rate-limits;
  the last good numbers stay visible (dimmed, "as of …") during outages.
- **Menu bar number** is the active account's binding constraint —
  `max(5-hour, weekly)` utilization. Orange ≥ 75 %, red ≥ 90 %.
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

## Build / install

```sh
./scripts/make-app.sh        # builds release + installs /Applications/PitStop.app
```

Dev loop: `swift build && .build/debug/PitStop --check` prints accounts and
live usage to stdout without starting the GUI.

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

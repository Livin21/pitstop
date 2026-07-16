# Contributing to PitStop

Thanks for your interest! PitStop is a small, single-maintainer macOS menu bar
app — contributions are welcome, but please keep them focused.

## Before you start

- For anything non-trivial, **open an issue first** to check it's a direction
  the project wants. It saves you work if the idea is out of scope.
- Naturally welcome: bug fixes, a new provider, small UX polish.

## Building

Requirements: **macOS 26+** and the Swift toolchain (Xcode Command Line Tools,
`xcode-select --install`).

```sh
git clone https://github.com/Livin21/pitstop && cd pitstop
swift build                 # debug build
./scripts/make-app.sh       # release build → /Applications/PitStop.app
```

Useful flags on the binary (great for testing without the GUI):

- `--check` — print accounts and live usage to stdout. The best way to
  exercise the data layer.
- `--preview` — render sample account rows to `/tmp/pitstop-preview.png`.
- `--screenshot` — run with masked sample emails, for docs captures.

Run the test suite with `swift test` — XCTest, one file per topic under
`Tests/PitStopTests/`. Logic changes should come with tests (parsing,
filtering, and decision layers are covered that way); UI and data-layer
changes are still verified by building, running `--check`, and exercising
the menu. (An ad-hoc-signed rebuild keeps its keychain grant, since access
rides the Apple-signed `/usr/bin/security`.)

## Code style

- Match the surrounding code — the same naming, and the same density of
  *why*-focused comments. Explain the non-obvious macOS / keychain / OAuth
  reasoning, not the obvious mechanics.
- Keep it pure AppKit plus the small SwiftUI settings window. The app
  intentionally has **no third-party dependencies** — don't add one without a
  strong reason.
- Per-account state is keyed by a provider-namespaced key (e.g. `codex:<email>`)
  so accounts sharing an email across providers don't collide. Preserve that.

## Adding a provider

The app is provider-generic. Roughly: add a `Provider` case and title, a
`<Name>.swift` that fetches usage (plus a `<Name>Store.swift` if it's
switchable), then wire it into `accountsForMenu` / `refreshAll` / the menu-bar
reading and namespace its keys. `Codex.swift` and `CodexStore.swift` are the
template to copy; `Gemini.swift` / `GeminiStore.swift` show the same pattern
stretched over a two-surface provider (CLI + Antigravity).

## Security

PitStop handles live credentials. Never log a secret, write one to disk, or
send one anywhere other than the documented endpoints. See
[SECURITY.md](SECURITY.md), and report security issues **privately** rather
than in a PR or public issue.

## Pull requests

- One focused change per PR. Describe **what** changed, **why**, and **how you
  tested it**.
- Don't commit real account emails or credentials — the repo uses masked
  sample data, and the menu screenshots are taken with `--screenshot`. Keep it
  that way.
- By contributing, you agree your work is licensed under the repository's
  [MIT License](LICENSE).

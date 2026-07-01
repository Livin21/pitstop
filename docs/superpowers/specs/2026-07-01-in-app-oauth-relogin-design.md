# In-App OAuth Re-Login — Design

**Date:** 2026-07-01
**Status:** Approved design, ready for implementation planning
**Component:** PitStop (macOS menu-bar app, Swift/AppKit)

## Problem

When a saved account's token is rejected, PitStop surfaces an error on that
account's row — `Token rejected — re-login needed` (Claude Code) or
`Codex session ended — sign in to Codex again` (Codex) — but offers no way to
act on it. The user must leave PitStop, run `claude` / `codex login` in a
terminal, and then `Save Current Account`. This design adds an in-app **Login**
button on expired rows that re-authenticates the account **without disturbing
any Claude Code / Codex session already running**.

## Goals

- A coral **Login** pill on any expired (`needsAction`) row for the two
  switchable providers (Claude Code and Codex).
- Clicking it runs a native OAuth 2.0 PKCE `authorization_code` flow and writes
  the fresh tokens so the row heals on the next refresh.
- **Running sessions are never affected** — guaranteed structurally, not by
  timing.
- The re-authenticated identity **must match the row**; a mismatch changes
  nothing and tells the user.

## Non-Goals

- No general "sign in to a new account" entry point (only expired-row healing).
  Adding new accounts still goes through the CLI + `Save Current Account`.
- No re-login for the **active/live** account of a provider (see Scope). The
  live account's token is kept fresh by the CLI itself and is out of scope for
  v1; keeping the feature to inactive accounts makes the "never touch live"
  invariant absolute.
- No change to Claude **Desktop** (observe-only; its login lives in that app).

## Requirements (decisions made during brainstorming)

1. **Mechanism:** native PKCE OAuth in-app; write fresh tokens **only** to the
   saved-profile keychain slot. (Not: delegating to the CLI, not: manual token
   paste as the primary mechanism.)
2. **Providers:** both Claude Code and Codex.
3. **Identity:** require the browser-authenticated identity to match the clicked
   row; reject + message on mismatch; write nothing.
4. **UI:** an always-visible coral **Login** pill on expired rows (reusing the
   plan/Switch chip slot).
5. **Scope:** expired-row login only (no general sign-in entry).
6. **Claude redirect:** attempt automatic localhost loopback capture first; fall
   back to manual code-paste if the automatic path does not complete. (Codex is
   always fully automatic via loopback.)

## The core invariant

> The re-login writes fresh tokens **only** into the saved-profile keychain slot
> (`PitStop-profile`, account = email, for Claude; `PitStop-codex`,
> account = email, for Codex). It never writes `Claude Code-credentials`,
> `~/.claude.json`, or `~/.codex/auth.json`.

Those live-store artifacts are mutated only by `ProfileStore.switchTo` /
`CodexStore.switchTo`. A running `claude`/`codex` reads the live store, so a
profile-only write cannot affect it. Because the feature is scoped to inactive
accounts, the account being re-logged-in is by definition not the live one.

## Architecture

Small, focused units; the provider-varying parts are isolated behind an adapter.

```
AccountRowView (Login pill)  ──click──▶  AppDelegate.performLogin(account)
                                              │
                                              ▼
                                   OAuthLoginCoordinator
              ┌───────────────────────────────┼────────────────────────────┐
              ▼                                ▼                             ▼
        PKCE (S256)                     LoopbackServer               LoginAdapter
   verifier/challenge/state        NWListener on 127.0.0.1      (ClaudeLoginAdapter |
                                    captures ?code&state          CodexLoginAdapter)
                                              │
                                              ▼
                             token exchange ▶ identity check ▶ patch saved blob
                                       ▶ Keychain.upsert(profile slot)
```

### New units

- **`OAuthLoginCoordinator`** — orchestrates one login attempt end to end:
  generate PKCE, build the authorize URL from the adapter, open the browser,
  await a code (from the loopback server or a pasted string), exchange it,
  verify identity against the target row, and hand the fresh tokens to the
  adapter to shape + persist into the profile slot. Provider-agnostic.
- **`LoopbackServer`** — a minimal one-shot HTTP listener
  (`Network.framework` `NWListener`) bound to `127.0.0.1`. Accepts the first
  `GET /<path>?code=…&state=…`, returns a small "you can close this tab and
  return to PitStop" HTML page, and yields `(code, state)`. Configurable port
  (Codex needs a fixed port; Claude uses this too). Times out (~3 min) and is
  cancellable. Runs off the main actor.
- **`LoginAdapter`** protocol — the provider-varying surface:
  - `authorizeEndpoint`, `tokenEndpoint`, `clientID`, `scopes`, extra authorize
    params, redirect strategy (loopback port policy / paste-mode redirect URI),
    token-exchange encoding (JSON vs form; whether `state` goes in the body).
  - `identity(fromTokenResponse:accessToken:) async -> LoginIdentity` — how to
    extract the authenticated email / account id.
  - `persist(freshTokens:matching:oldBlob:) async throws` — patch the saved
    blob and write it to the provider's profile slot.
  - Implementations: `ClaudeLoginAdapter`, `CodexLoginAdapter`.

### Reused existing code

- `Keychain.upsert(service:account:data:)` — crash-safe, prompt-free write to a
  profile slot (staged add + delete + add). Used verbatim.
- `CredentialBlob.patching(_:accessToken:refreshToken:expiresAtMs:)` — patches
  only the Claude `claudeAiOauth` token fields, preserving everything else.
- `Codex.patching(_:with:)` + `Codex.normalizedBlob` +
  `CodexStore.storeRefreshedBlob` — the Codex equivalent (compact/sorted-keys).
- `Codex.credentials(from:)` / `Codex.decodeJWTClaims` — Codex identity from the
  `id_token` JWT.
- `UsageAPI.clientID`, `Codex.clientID` — the two public client IDs.

## Grounded provider parameters

Verified against the open-source `openai/codex` `codex-rs/login` crate (Codex,
HIGH confidence), and a Claude-Code-v2.1.87-tracking OAuth reimplementation +
official docs + PitStop's own working code (Claude, MEDIUM confidence — items
tagged **[verify]** must be confirmed empirically).

| | **Claude Code** | **Codex** |
|---|---|---|
| Authorize URL | `https://claude.ai/oauth/authorize` | `https://auth.openai.com/oauth/authorize` |
| Token URL | `https://platform.claude.com/v1/oauth/token` **[verify]**; fall back to `https://console.anthropic.com/v1/oauth/token` (PitStop's working refresh host) | `https://auth.openai.com/oauth/token` (also serves refresh + api-key mint) |
| client_id | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` | `app_EMoamEEZ73f0CkXaXp7hrann` |
| Scopes (space-joined) | `org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload` **[verify — set drifts by build]** | `openid profile email offline_access api.connectors.read api.connectors.invoke` (older builds: 4-scope `openid profile email offline_access`) |
| PKCE | S256; verifier = base64url-nopad(random, **32 or 64 bytes — don't hardcode**); state = independent random | S256; verifier = base64url-nopad(64 bytes); state = base64url-nopad(32 bytes) |
| Extra authorize params | `code=true` (paste-mode only) | `id_token_add_organizations=true`, `codex_cli_simplified_flow=true`, `originator=codex_cli_rs` |
| Loopback | attempt `http://localhost:<port>/callback` **[verify acceptance]**; paste-mode redirect `https://platform.claude.com/oauth/code/callback` | fixed `http://localhost:1455/auth/callback`, fallback `1457` (registered ports) |
| Token exchange | POST **JSON**; body: `grant_type=authorization_code`, `code`, `state`, `client_id`, `redirect_uri`, `code_verifier` | POST **form-urlencoded**; body: `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `code_verifier` (no `state`) |
| Token response | `access_token` (`sk-ant-oat01-…`), `refresh_token` (`sk-ant-ort01-…`), `expires_in`; `expiresAt(ms)=(now+expires_in)*1000` | `id_token`, `access_token`, `refresh_token`; expiry from `id_token.exp` |
| Second step | none (uses OAuth token directly; `anthropic-beta: oauth-2025-04-20`) | optional, **non-fatal** api-key mint (token-exchange → `OPENAI_API_KEY`; may be `null`) |
| Identity source | `GET https://api.anthropic.com/api/oauth/profile` (Bearer) **[verify]**; fallback: token-response `account` object or confirm dialog | decode `id_token` JWT: `email` + `https://api.openai.com/auth`→`chatgpt_account_id` |

## Flows

### Codex — fully automatic
1. Bind `LoopbackServer` to `127.0.0.1:1455` (fallback `1457`; if both busy →
   error "a Codex login may be in progress — finish or cancel it and retry").
2. Build authorize URL (redirect `http://localhost:<port>/auth/callback`), open
   the browser.
3. User signs in → OpenAI redirects to the loopback → capture `(code, state)`;
   verify `state`.
4. Exchange (form-urlencoded) → `{id_token, access_token, refresh_token}`.
5. Identity: decode `id_token` → `chatgpt_account_id` + email; require match with
   the row (else reject).
6. Optionally run the api-key mint (non-fatal).
7. `Codex.patching(oldBlob, with: Refreshed(...))` (updates
   `tokens.{access_token,refresh_token,id_token}` + `last_refresh=now`,
   preserves `auth_mode`/`OPENAI_API_KEY`/`account_id`; re-derive `account_id`
   from the new `id_token` if it changed) → `CodexStore.storeRefreshedBlob`
   (compact/sorted-keys, `PitStop-codex` slot).

### Claude — loopback first, paste fallback
1. **Attempt A (auto):** bind `LoopbackServer` to `127.0.0.1:<port>`; build the
   authorize URL with `redirect_uri=http://localhost:<port>/callback` (no
   `code=true`); open the browser; await the loopback with a timeout (~90s). The
   progress UI also shows a **"Browser showing a code instead? Use paste
   sign-in"** control so the user isn't forced to wait out the timeout when
   claude.ai rejected the localhost redirect.
2. If the loopback captures `(code, state)` → continue at step 4 (Attempt A's
   `redirect_uri`).
3. **Attempt B (fallback):** triggered by the paste control or by Attempt A's
   timeout. Because the two attempts need different `redirect_uri`s, Attempt B
   **re-opens the browser** with the paste-mode authorize URL (`code=true`,
   `redirect_uri=https://platform.claude.com/oauth/code/callback`) and reveals a
   text field. The user copies the code claude.ai shows and pastes it. Parse
   `code`/`state` from the pasted value (accept a full redirect URL, a
   `CODE#STATE` string, or `code=…&state=…`). **The token-exchange `redirect_uri`
   must byte-match whichever authorize URL produced the code** (localhost for A,
   hosted callback for B) — so the coordinator tracks which attempt yielded the
   code and uses that `redirect_uri` in the exchange.
4. Verify `state`. Exchange (POST JSON, `state` in body) →
   `{access_token, refresh_token, expires_in}`.
5. Identity: `GET api.anthropic.com/api/oauth/profile` with the fresh access
   token; require the email to match the row (else reject). **[verify endpoint]**
6. `CredentialBlob.patching(oldBlob, accessToken:, refreshToken:,
   expiresAtMs:(now+expires_in)*1000)` (preserves `subscriptionType`/
   `rateLimitTier`/other sections) → `Keychain.upsert("PitStop-profile", email)`.
   `Profile.oauthAccount` and plan metadata are unchanged (same account).

## Identity matching

The OAuth identity is used **only to verify the match** — not to repopulate the
profile (a re-login is the same account, so the stored identity/plan is kept).

- **Codex:** primary key `chatgpt_account_id` (stable), email secondary.
- **Claude:** normalized email from the profile endpoint.
- On mismatch: write nothing; show *"You signed in as `X`, but this row is `Y` —
  switch accounts in your browser and retry."*
- If Claude identity can't be obtained at all (endpoint unavailable), degrade to
  an explicit confirm dialog naming the target account rather than silently
  skipping the check.

## UI changes

- **`AccountRowView.Model`** gains a login affordance. Simplest: add
  `onLogin: (() -> Void)?`; when set, the chip renders an **always-visible**
  coral `Login` pill (in place of the plan chip / hover-Switch), and a row click
  triggers `onLogin`. Keep the existing `onSwitch` behavior for healthy rows.
- **`AppDelegate.rowModel(for:)`**: when `needsAction.contains(key)` and the
  account is inactive and switchable, wire `onLogin` (→ `performLogin(account)`)
  instead of `onSwitch`. A row healed by the Desktop fallback (`.both`) is not in
  `needsAction`, so it shows no pill — acceptable for v1 (noted as an edge case).
- **`AppDelegate.performLogin(_:)`** (new): runs the coordinator with the right
  adapter, shows lightweight progress ("Waiting for browser…" / paste field on
  Claude fallback), posts a success/failure notification or error sheet, then
  `refreshAll()` so the row heals (pill → normal chip).
- A small **paste sheet/window** for the Claude fallback (a label + text field +
  Submit/Cancel). Reuse `SettingsWindowController` patterns.

## Error handling & edge cases

- **State mismatch / bad code:** abort with a clear message; write nothing.
- **User closes the browser / timeout:** the coordinator cancels cleanly
  (loopback closed, no partial writes).
- **Codex port busy:** try 1455 → 1457 → error (don't fight a live login).
- **Concurrent logins:** disallow a second login while one is in flight.
- **Success feedback loop:** the next `refreshAll` fetches usage with the new
  tokens, `clearFetchError` removes the row from `needsAction`, and the pill
  reverts — no extra UI plumbing needed.
- **Active-account expiry:** out of scope (Non-Goals); no pill on the live row.

## Testing

- **Unit (no network):**
  - PKCE: verifier charset/length, `challenge == base64url(SHA256(verifier))`,
    S256 method.
  - Authorize-URL assembly per adapter (params, encoding, extra params, redirect).
  - Callback parsing: loopback query and all three Claude paste formats.
  - Blob patching round-trips: Claude patch → `CredentialBlob.parse` sees new
    tokens + preserved `subscriptionType`/`rateLimitTier`; Codex patch →
    `Codex.credentials` sees new tokens, blob stays compact (no newlines),
    `last_refresh`/`account_id` correct.
  - Identity match/mismatch decisions.
- **Manual (documented in the plan):** full round-trip per provider —
  re-login an inactive account → confirm the row heals → `switchTo` it → run
  `claude` / `codex` and confirm it works; confirm a *different* running session
  is untouched throughout.

## Risks / to-verify during implementation

1. **[Claude] localhost redirect acceptance** — whether the `9d1c250a` client
   accepts an arbitrary `http://localhost:<port>` redirect. If rejected, Attempt
   A fails fast and we rely on the paste fallback (proven). Probe early.
2. **[Claude] token endpoint host** — `platform.claude.com` vs
   `console.anthropic.com`; `redirect_uri` must byte-match authorize. Try
   platform, fall back to console.
3. **[Claude] identity source** — confirm `GET /api/oauth/profile` returns the
   email; else use a token-response `account` object or the confirm-dialog
   degrade.
4. **[Claude] token response** almost certainly omits
   `subscriptionType`/`rateLimitTier` — preserve them via patching (the design
   already does).
5. **[Codex] port contention** with Codex.app / an in-progress `codex login`.
6. **[Codex] JWT freshness** — set `last_refresh=now` and ensure the new
   `id_token.exp` is in the future so a later `switchTo` isn't seen as expired.
7. **[Codex] `OPENAI_API_KEY`** — always present (key or `null`); decide mint vs
   preserve. Confirm a restored blob with a stale/`null` key still yields a
   working `codex` (it should prefer the ChatGPT tokens).
8. **Scope/version drift** — the installed CLI version dictates exact
   scopes/ports; validate end-to-end by round-trip rather than by matching a
   fixed constant.
9. **Keychain argv exposure** — the profile write uses
   `security add-generic-password` (secret via argv), the same exposure PitStop
   already accepts; no new risk.

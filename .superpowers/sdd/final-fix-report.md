# Gemini Provider Code-Review Fixes — Final Report

Date: 2026-07-01

## Summary

All 6 fixes applied. Build: clean. Tests: 46/46 passed (0 failures).

---

## Fix 1 — Wire Gemini into usage-projection pipeline

**File:** `Sources/PitStop/AppDelegate.swift`

### 1a — recordUsageSamples
Line ~1148: Changed the iteration set from:
```swift
for key in Set(usage.keys).union(codexUsage.keys) where fetchError[key] == nil {
```
to:
```swift
for key in Set(usage.keys).union(codexUsage.keys).union(geminiUsage.keys) where fetchError[key] == nil {
```
Gemini account keys are now included in the history-sampling loop.

### 1b — projectableWindows(forKey:)
Lines ~1160-1170: Added a Gemini branch between the Codex and Claude branches:
```swift
if let gu = geminiUsage[key] {
    return gu.windows.map { (label: $0.label, util: $0.usedPercent, resetsAt: $0.resetsAt) }
}
```
Gemini windows are now projected and displayed in the "on pace to hit limit" trend line.

---

## Fix 2 — Patch credential blobs on refresh instead of rebuilding from scratch

**Files:** `Sources/PitStop/Gemini.swift`, `Sources/PitStop/AppDelegate.swift`, `Tests/PitStopTests/GeminiPatchTests.swift`

### Gemini.swift — new static methods (lines ~107-132)
- `static func patchCliBlob(_ old: Data, access: String, idToken: String?, expiryMs: Double) -> Data?` — parses the CLI JSON object, sets `access_token`, `expiry_date`, and `id_token` if non-nil; preserves all other keys; re-serializes with `.sortedKeys`. Returns nil if old isn't a JSON object.
- `static func patchAntigravityBlob(_ old: Data, access: String, idToken: String?, expiryISO: String) -> Data?` — decodes the `go-keyring-base64:` string, updates `token.access_token`, `token.expiry`, and `token.id_token` if non-nil; preserves all other keys; re-serializes and re-wraps via `encodeGoKeyring`. Returns nil if it can't decode/parse.

### AppDelegate.swift — fetchGeminiUsage (lines ~541-549)
Replaced `buildCliBlob`/`buildAntigravityBlob` calls with `patchCliBlob`/`patchAntigravityBlob`, each with a fallback to the build* function if patch returns nil.

### GeminiPatchTests.swift
6 new tests:
- `testPatchCliBlobUpdatesTokenAndPreservesUnknownKeys` — verifies access_token, expiry_date updated; `extra_unknown_field` preserved; round-trips via `Gemini.cliCreds`.
- `testPatchCliBlobUpdatesIdTokenWhenProvided` — verifies id_token update and email round-trip.
- `testPatchCliBlobReturnsNilForInvalidInput` — nil for non-JSON.
- `testPatchAntigravityBlobUpdatesTokenAndPreservesUnknownKeys` — verifies token fields updated; `inner_unknown` and `auth_method` preserved; result has `go-keyring-base64:` prefix; round-trips via `Gemini.antigravityCreds`.
- `testPatchAntigravityBlobUpdatesIdTokenWhenProvided` — verifies id_token update and email round-trip.
- `testPatchAntigravityBlobReturnsNilForInvalidInput` — nil for non-keyring input.

All 6 patch tests pass.

---

## Fix 3 — allEmails() omits Gemini profiles

**File:** `Sources/PitStop/AppDelegate.swift`, line ~205

Added one line after the Codex loop:
```swift
for g in geminiStore.profiles where !emails.contains(g.email) { emails.append(g.email) }
```
Gemini account emails are now included in `displayEmail` masking and stable ordering.

---

## Fix 4 — Remove stray OpenAI claim lookup in Gemini.decodeJWTEmail

**File:** `Sources/PitStop/Gemini.swift`, lines ~85-88

Deleted the Codex copy-paste fallback:
```swift
// REMOVED:
if let p = claims["https://api.openai.com/profile"] as? [String: Any],
   let e = p["email"] as? String { return e }
```
Only the top-level `email` claim is read, which is correct for Google ID tokens.

---

## Fix 5 — Cache the "no Code Assist project" case

**Files:** `Sources/PitStop/Gemini.swift`, `Sources/PitStop/AppDelegate.swift`

### Gemini.swift — GeminiError enum
Added `case noProject` with `errorDescription` = `"Signed in, but no Gemini Code Assist project"`.

### AppDelegate.swift — fetchGeminiUsage (lines ~551-567)
- When `loadProject` returns a nil project, stores `geminiProject[email] = ""` as a sentinel.
- On subsequent calls, when the cached project is the empty sentinel, throws `Gemini.GeminiError.noProject` immediately (no network call).
- `noProject` falls through to the `default` arm of `recordFetchError`, which removes the key from `needsAction` (no Login pill) and sets `fetchError[key]` for informational display only.

---

## Fix 6 — Antigravity live-write account-resolution edge

**Files:** `Sources/PitStop/Keychain.swift`, `Sources/PitStop/GeminiStore.swift`

### Keychain.swift — new overload (lines ~121-131)
Added `static func upsertLive(service: String, account: String, data: Data) async throws` that runs `add-generic-password -U -s service -a account -w value` directly with the caller-supplied account, skipping the metadata read that the no-account overload needs.

### GeminiStore.swift — switchTo (line ~162)
Changed:
```swift
try await Keychain.upsertLive(service: Self.liveKeychainService, data: ag)
```
to:
```swift
try await Keychain.upsertLive(service: Self.liveKeychainService, account: Self.liveKeychainAccount, data: ag)
```
The Antigravity live item is always written with the fixed `"antigravity"` account attribute, preventing a metadata read that could resolve the wrong account under race conditions.

---

## Test & Build Results

```
Build complete! (5.27s)

Test Suite 'All tests' passed at 2026-07-01 19:57:00.344.
     Executed 46 tests, with 0 failures (0 unexpected) in 0.387 (0.392) seconds
```

- GeminiPatchTests: 6/6 passed (Fix 2 coverage)
- All pre-existing tests: 40/40 passed
- Total: 46/46 passed, 0 failures

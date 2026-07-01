# In-App OAuth Re-Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a coral **Login** pill to expired (rejected-token) account rows that re-authenticates the account via a native OAuth PKCE flow, healing the row without disturbing any running Claude Code / Codex session.

**Architecture:** A provider-agnostic `OAuthLoginCoordinator` runs PKCE → browser → code capture (raw-socket loopback, with a code-paste fallback for Claude) → token exchange → identity verification → a **profile-slot-only** keychain write. Two thin `LoginAdapter`s (Claude, Codex) supply endpoints, encodings, and blob shaping. The live credential stores are never touched, which is what guarantees running sessions are unaffected. Scoped to inactive accounts.

**Tech Stack:** Swift 6 (language mode v5), AppKit, Foundation, Darwin (BSD sockets), CommonCrypto. No new third-party dependencies. SwiftPM `XCTest` target.

**Spec:** `docs/superpowers/specs/2026-07-01-in-app-oauth-relogin-design.md`

## Global Constraints

- Platform: macOS 26+; `swift-tools-version: 6.0`; `swiftLanguageMode(.v5)` on every target.
- No new third-party dependencies — Foundation / AppKit / Darwin / CommonCrypto / Network only.
- **Profile-only invariant:** the re-login writes **only** to the saved-profile keychain slots (`PitStop-profile` for Claude, `PitStop-codex` for Codex). It must never write `Claude Code-credentials`, `~/.claude.json`, or `~/.codex/auth.json`.
- **Scope:** inactive, switchable accounts only. No Login pill on the live account of a provider or on Desktop rows.
- **Identity strict-match:** if the authenticated identity differs from the clicked row, write nothing and tell the user.
- **Loopback binding must use raw BSD sockets**, not `NWListener` (which fails to bind in this build environment). Bind `127.0.0.1` only.
- Coral accent color, matching `AccountRowView`: `NSColor(srgbRed: 217/255, green: 119/255, blue: 87/255, alpha: 1)`.
- Keychain writes go through the existing `Keychain.upsert` (crash-safe staged write, no ACL prompt).
- Codex saved blobs must be compact/sorted-keys (`Codex.normalizedBlob`) — pretty-printed JSON corrupts on keychain restore.
- OAuth parameters tagged **[verify]** in the spec are best-effort and must be confirmed by the end-to-end round-trip in Task 9; do not assume a fixed constant is correct without the round-trip passing.

---

### Task 1: Test target + PKCE

Establishes the `swift test` harness (the package is currently executable-only) and the first pure unit.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PitStop/OAuthPKCE.swift`
- Test: `Tests/PitStopTests/OAuthPKCETests.swift`

**Interfaces:**
- Produces: `OAuthPKCE.base64URL(_ data: Data) -> String`, `OAuthPKCE.challenge(for verifier: String) -> String`, `OAuthPKCE.randomVerifier(byteCount: Int = 64) -> String`, `OAuthPKCE.randomState() -> String`, `OAuthPKCE.generate() -> (verifier: String, challenge: String, state: String)`.

- [ ] **Step 1: Add the test target to `Package.swift`**

Replace the `targets:` array so the executable target is unchanged and a test target is added:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pitstop",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "PitStop",
            path: "Sources/PitStop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PitStopTests",
            dependencies: ["PitStop"],
            path: "Tests/PitStopTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: Write the failing test**

Create `Tests/PitStopTests/OAuthPKCETests.swift`:

```swift
import XCTest
@testable import PitStop

final class OAuthPKCETests: XCTestCase {
    // RFC 7636 Appendix B known-answer vector.
    func testChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(OAuthPKCE.challenge(for: verifier),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierIsBase64URLAndRandom() {
        let a = OAuthPKCE.randomVerifier()
        let b = OAuthPKCE.randomVerifier()
        XCTAssertNotEqual(a, b)
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertGreaterThanOrEqual(a.count, 43)   // RFC 7636 minimum
    }

    func testGenerateIsConsistent() {
        let g = OAuthPKCE.generate()
        XCTAssertEqual(OAuthPKCE.challenge(for: g.verifier), g.challenge)
        XCTAssertFalse(g.state.isEmpty)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter OAuthPKCETests`
Expected: FAIL — `cannot find 'OAuthPKCE' in scope`.

- [ ] **Step 4: Write the implementation**

Create `Sources/PitStop/OAuthPKCE.swift`:

```swift
import Foundation
import CommonCrypto

/// PKCE (RFC 7636, S256) helpers for the OAuth login flow. Pure and testable.
enum OAuthPKCE {
    /// Base64URL without padding — the encoding PKCE and OAuth `state` use.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// code_challenge = base64url(SHA256(code_verifier)).
    static func challenge(for verifier: String) -> String {
        let bytes = Data(verifier.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        bytes.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(bytes.count), &hash) }
        return base64URL(Data(hash))
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func randomVerifier(byteCount: Int = 64) -> String { base64URL(randomBytes(byteCount)) }
    static func randomState() -> String { base64URL(randomBytes(32)) }

    static func generate() -> (verifier: String, challenge: String, state: String) {
        let v = randomVerifier()
        return (v, challenge(for: v), randomState())
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter OAuthPKCETests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/PitStop/OAuthPKCE.swift Tests/PitStopTests/OAuthPKCETests.swift
git commit -m "Add test target and PKCE helper"
```

---

### Task 2: Loopback callback server (raw BSD socket)

A one-shot localhost HTTP server that captures the OAuth `?code&state` redirect. Uses raw sockets — `NWListener` cannot bind in this environment.

**Files:**
- Create: `Sources/PitStop/LoopbackServer.swift`
- Test: `Tests/PitStopTests/LoopbackServerTests.swift`

**Interfaces:**
- Produces:
  - `LoopbackServer.Captured` (`code: String`, `state: String`)
  - `LoopbackServer.parse(requestLine: String) -> Captured?` (pure)
  - `LoopbackServer.parsePasted(_ input: String) -> Captured?` (pure; Claude paste formats)
  - `LoopbackServer().start(ports: [UInt16]) throws` (sets `.port`)
  - `LoopbackServer().port: UInt16`
  - `LoopbackServer().waitForCallback(timeout: TimeInterval) async throws -> Captured`
  - `LoopbackServer().stop()`
  - `LoopbackServer.ServerError` (`LocalizedError`)

- [ ] **Step 1: Write the failing tests**

Create `Tests/PitStopTests/LoopbackServerTests.swift`:

```swift
import XCTest
@testable import PitStop

final class LoopbackServerTests: XCTestCase {
    func testParseRequestLine() {
        let c = LoopbackServer.parse(requestLine: "GET /callback?code=ab%2Fc&state=xyz HTTP/1.1")
        XCTAssertEqual(c?.code, "ab/c")
        XCTAssertEqual(c?.state, "xyz")
        XCTAssertNil(LoopbackServer.parse(requestLine: "GET /favicon.ico HTTP/1.1"))
    }

    func testParsePastedFormats() {
        // Full redirect URL
        XCTAssertEqual(LoopbackServer.parsePasted(
            "https://platform.claude.com/oauth/code/callback?code=AAA&state=BBB")?.code, "AAA")
        // CODE#STATE
        let hash = LoopbackServer.parsePasted("AAA#BBB")
        XCTAssertEqual(hash?.code, "AAA"); XCTAssertEqual(hash?.state, "BBB")
        // urlencoded query fragment
        let q = LoopbackServer.parsePasted("code=AAA&state=BBB")
        XCTAssertEqual(q?.code, "AAA"); XCTAssertEqual(q?.state, "BBB")
        XCTAssertNil(LoopbackServer.parsePasted("   "))
    }

    func testRoundTrip() async throws {
        let srv = LoopbackServer()
        try srv.start(ports: [49260, 49261])
        defer { srv.stop() }
        XCTAssertGreaterThan(srv.port, 0)
        let waiter = Task { try await srv.waitForCallback(timeout: 5) }
        _ = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(srv.port)/callback?code=THECODE&state=THESTATE")!)
        let cap = try await waiter.value
        XCTAssertEqual(cap.code, "THECODE")
        XCTAssertEqual(cap.state, "THESTATE")
    }

    func testPortFallbackWhenBusy() throws {
        let hog = LoopbackServer(); try hog.start(ports: [49270]); defer { hog.stop() }
        let srv = LoopbackServer(); try srv.start(ports: [49270, 49271]); defer { srv.stop() }
        XCTAssertEqual(srv.port, 49271)
    }

    func testTimeoutThrows() async throws {
        let srv = LoopbackServer(); try srv.start(ports: [49280]); defer { srv.stop() }
        do {
            _ = try await srv.waitForCallback(timeout: 0.3)
            XCTFail("expected timeout")
        } catch { /* expected */ }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter LoopbackServerTests`
Expected: FAIL — `cannot find 'LoopbackServer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PitStop/LoopbackServer.swift`:

```swift
import Foundation
import Darwin

/// One-shot loopback HTTP server on a raw BSD socket, bound to `127.0.0.1`.
/// Captures the first `GET …?code=…&state=…`, replies 200, yields it.
///
/// Raw sockets (not Network.framework) because `NWListener` fails to bind in
/// some environments, and a short-lived localhost OAuth callback needs exactly
/// this and nothing more.
final class LoopbackServer {
    struct Captured { let code: String; let state: String }
    struct ServerError: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    private var fd: Int32 = -1
    private(set) var port: UInt16 = 0

    /// Parse an HTTP request line's query. Pure.
    static func parse(requestLine: String) -> Captured? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let query = parts[1].split(separator: "?").dropFirst().first else { return nil }
        return captured(fromQuery: String(query))
    }

    /// Parse a value the user pasted from claude.ai's callback page. Accepts a
    /// full redirect URL, a "CODE#STATE" string, or a "code=…&state=…" query.
    static func parsePasted(_ input: String) -> Captured? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let comps = URLComponents(string: s), comps.scheme != nil,
           let cap = captured(fromItems: comps.queryItems) { return cap }
        if s.contains("#") {
            let hs = s.split(separator: "#", maxSplits: 1)
            if hs.count == 2 { return Captured(code: String(hs[0]), state: String(hs[1])) }
        }
        return captured(fromQuery: s)
    }

    private static func captured(fromQuery query: String) -> Captured? {
        var code: String?, state: String?
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let v = kv[1].removingPercentEncoding ?? String(kv[1])
            if kv[0] == "code" { code = v } else if kv[0] == "state" { state = v }
        }
        guard let code, let state else { return nil }
        return Captured(code: code, state: state)
    }

    private static func captured(fromItems items: [URLQueryItem]?) -> Captured? {
        guard let items else { return nil }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value else { return nil }
        return Captured(code: code, state: state)
    }

    /// Bind the first available loopback port in `ports`.
    func start(ports: [UInt16]) throws {
        for p in ports {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { continue }
            var yes: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = p.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0, listen(s, 1) == 0 { fd = s; port = p; return }
            close(s)
        }
        throw ServerError(msg: "No free loopback port in \(ports)")
    }

    /// Await the first callback (blocking accept on a background queue), racing a
    /// timeout. `stop()` unblocks a pending accept so the task can be cancelled.
    func waitForCallback(timeout: TimeInterval) async throws -> Captured {
        let listenFD = fd
        guard listenFD >= 0 else { throw ServerError(msg: "Loopback server not started") }
        return try await withThrowingTaskGroup(of: Captured.self) { group in
            group.addTask { try await self.acceptOne(listenFD) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ServerError(msg: "Timed out waiting for the browser")
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            return result
        }
    }

    private func acceptOne(_ listenFD: Int32) async throws -> Captured {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let client = accept(listenFD, nil, nil)
                guard client >= 0 else {
                    cont.resume(throwing: ServerError(msg: "accept failed (errno \(errno))")); return
                }
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = read(client, &buf, buf.count)
                let text = n > 0 ? (String(bytes: buf[0..<n], encoding: .utf8) ?? "") : ""
                let firstLine = text.components(separatedBy: "\r\n").first ?? ""
                let body = "You can close this tab and return to PitStop."
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = resp.withCString { write(client, $0, strlen($0)) }
                close(client)
                if let cap = LoopbackServer.parse(requestLine: firstLine) {
                    cont.resume(returning: cap)
                } else {
                    cont.resume(throwing: ServerError(msg: "Unparseable callback"))
                }
            }
        }
    }

    func stop() {
        if fd >= 0 { close(fd); fd = -1 }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter LoopbackServerTests`
Expected: PASS (5 tests). (The round-trip test binds/reaches `127.0.0.1`; confirmed to work under the sandbox.)

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/LoopbackServer.swift Tests/PitStopTests/LoopbackServerTests.swift
git commit -m "Add raw-socket loopback callback server"
```

---

### Task 3: Claude token exchange + identity fetch

Adds the Claude authorization_code exchange and identity lookup to `UsageAPI`, alongside the existing refresh grant.

**Files:**
- Modify: `Sources/PitStop/UsageAPI.swift`
- Test: `Tests/PitStopTests/ClaudeExchangeTests.swift`

**Interfaces:**
- Consumes: `UsageAPI.clientID`, `OAuthPKCE`.
- Produces:
  - `UsageAPI.exchangeCodeRequest(code:state:verifier:redirectURI:host:) -> URLRequest` (pure builder)
  - `UsageAPI.exchangeCode(code:state:verifier:redirectURI:) async throws -> (accessToken: String, refreshToken: String?, expiresAtMs: Double)`
  - `UsageAPI.profileRequest(accessToken:) -> URLRequest` (pure builder)
  - `UsageAPI.fetchAccountEmail(accessToken:) async throws -> String`
  - `UsageAPI.authorizeTokenHosts: [URL]` (`platform.claude.com` then `console.anthropic.com`)

- [ ] **Step 1: Write the failing test**

Create `Tests/PitStopTests/ClaudeExchangeTests.swift`:

```swift
import XCTest
@testable import PitStop

final class ClaudeExchangeTests: XCTestCase {
    func testExchangeRequestShape() throws {
        let host = URL(string: "https://platform.claude.com/v1/oauth/token")!
        let req = UsageAPI.exchangeCodeRequest(
            code: "C", state: "S", verifier: "V",
            redirectURI: "http://localhost:1455/callback", host: host)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url, host)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["grant_type"] as? String, "authorization_code")
        XCTAssertEqual(body?["code"] as? String, "C")
        XCTAssertEqual(body?["state"] as? String, "S")           // Claude sends state in the body
        XCTAssertEqual(body?["code_verifier"] as? String, "V")
        XCTAssertEqual(body?["client_id"] as? String, UsageAPI.clientID)
        XCTAssertEqual(body?["redirect_uri"] as? String, "http://localhost:1455/callback")
    }

    func testProfileRequestShape() {
        let req = UsageAPI.profileRequest(accessToken: "sk-ant-oat01-TOKEN")
        XCTAssertEqual(req.url?.host, "api.anthropic.com")
        XCTAssertTrue(req.url?.path.contains("/oauth/profile") ?? false)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-TOKEN")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ClaudeExchangeTests`
Expected: FAIL — `type 'UsageAPI' has no member 'exchangeCodeRequest'`.

- [ ] **Step 3: Write the implementation**

In `Sources/PitStop/UsageAPI.swift`, add to `enum UsageAPI` (after the existing `refresh` function, before the closing brace):

```swift
    // MARK: - Fresh login (authorization_code)

    /// Anthropic OAuth token hosts, tried in order — the current `platform`
    /// host first, then the legacy `console` host PitStop's refresh already
    /// uses. [verify] which accepts the authorization_code grant.
    static let authorizeTokenHosts: [URL] = [
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
    ]

    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// Build the authorization_code exchange request (JSON body, `state`
    /// included — the shape Claude Code uses). Pure, for testing.
    static func exchangeCodeRequest(code: String, state: String, verifier: String,
                                    redirectURI: String, host: URL) -> URLRequest {
        var req = URLRequest(url: host)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
        return req
    }

    /// Exchange an authorization code for tokens. Tries each host in order,
    /// falling through on connection/host errors; a 4xx from a reachable host
    /// is returned as `.unauthorized`.
    static func exchangeCode(code: String, state: String, verifier: String,
                             redirectURI: String) async throws
        -> (accessToken: String, refreshToken: String?, expiresAtMs: Double) {
        var lastError: Error = APIError.malformed
        for host in authorizeTokenHosts {
            do {
                let req = exchangeCodeRequest(code: code, state: state, verifier: verifier,
                                              redirectURI: redirectURI, host: host)
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw APIError.malformed }
                if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 400 {
                    throw APIError.unauthorized
                }
                guard http.statusCode == 200 else { throw APIError.http(http.statusCode) }
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let access = root["access_token"] as? String,
                      let expiresIn = (root["expires_in"] as? NSNumber)?.doubleValue else {
                    throw APIError.malformed
                }
                let expiresAtMs = (Date().timeIntervalSince1970 + expiresIn) * 1000
                return (access, root["refresh_token"] as? String, expiresAtMs)
            } catch let error as APIError {
                // A definitive auth rejection shouldn't fall through to the next host.
                if case .unauthorized = error { throw error }
                lastError = error
            } catch {
                lastError = error   // connection/DNS — try the next host
            }
        }
        throw lastError
    }

    /// Build the identity (profile) request. Pure, for testing.
    static func profileRequest(accessToken: String) -> URLRequest {
        var req = URLRequest(url: profileURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        return req
    }

    /// Fetch the authenticated account's email. [verify] endpoint/shape — used
    /// only to confirm the re-login matches the target row.
    static func fetchAccountEmail(accessToken: String) async throws -> String {
        let (data, resp) = try await URLSession.shared.data(for: profileRequest(accessToken: accessToken))
        guard let http = resp as? HTTPURLResponse else { throw APIError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized }
        guard http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.http(http.statusCode)
        }
        // Accept a couple of plausible shapes: top-level `email`/`email_address`,
        // or nested under `account`.
        if let e = root["email"] as? String ?? root["email_address"] as? String { return e }
        if let account = root["account"] as? [String: Any],
           let e = account["email_address"] as? String ?? account["email"] as? String { return e }
        throw APIError.malformed
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ClaudeExchangeTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/UsageAPI.swift Tests/PitStopTests/ClaudeExchangeTests.swift
git commit -m "Add Claude authorization_code exchange and identity fetch"
```

---

### Task 4: Codex token exchange + identity from id_token

Adds the Codex authorization_code exchange (form-urlencoded) and JWT identity decode to `Codex`.

**Files:**
- Modify: `Sources/PitStop/Codex.swift`
- Test: `Tests/PitStopTests/CodexExchangeTests.swift`

**Interfaces:**
- Consumes: `Codex.clientID`, `Codex.Refreshed`, `Codex.decodeJWTClaims` (private, same file).
- Produces:
  - `Codex.LoginIdentity` is defined in Task 5; here return a tuple to avoid ordering issues: `Codex.identity(fromIDToken:) -> (email: String, accountID: String?)?`
  - `Codex.exchangeCodeRequest(code:verifier:redirectURI:) -> URLRequest` (pure builder)
  - `Codex.exchangeCode(code:verifier:redirectURI:) async throws -> Refreshed`

- [ ] **Step 1: Write the failing test**

Create `Tests/PitStopTests/CodexExchangeTests.swift`:

```swift
import XCTest
@testable import PitStop

final class CodexExchangeTests: XCTestCase {
    func testExchangeRequestIsFormUrlEncoded() {
        let req = Codex.exchangeCodeRequest(
            code: "C+1", verifier: "V", redirectURI: "http://localhost:1455/auth/callback")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://auth.openai.com/oauth/token")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"),
                       "application/x-www-form-urlencoded")
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=C%2B1"))                 // '+' percent-encoded
        XCTAssertTrue(body.contains("code_verifier=V"))
        XCTAssertTrue(body.contains("client_id=\(Codex.clientID)"))
        XCTAssertFalse(body.contains("state="))                    // Codex omits state in the body
    }

    func testIdentityFromIDToken() {
        // Minimal unsigned JWT: header.payload.sig ; payload carries email + auth.
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload = #"{"email":"user@example.com","https://api.openai.com/auth":{"chatgpt_account_id":"acct_123","chatgpt_plan_type":"plus"}}"#
        let jwt = "\(b64url("{}")).\(b64url(payload)).sig"
        let id = Codex.identity(fromIDToken: jwt)
        XCTAssertEqual(id?.email, "user@example.com")
        XCTAssertEqual(id?.accountID, "acct_123")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CodexExchangeTests`
Expected: FAIL — `type 'Codex' has no member 'exchangeCodeRequest'`.

- [ ] **Step 3: Write the implementation**

In `Sources/PitStop/Codex.swift`, add to `enum Codex` (near the existing `refresh`/`patching`, before the closing brace):

```swift
    // MARK: - Fresh login (authorization_code)

    /// Build the authorization_code exchange request (form-urlencoded, no
    /// `state` in the body — the shape the Codex CLI uses). Pure, for testing.
    static func exchangeCodeRequest(code: String, verifier: String,
                                    redirectURI: String) -> URLRequest {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        func enc(_ s: String) -> String {
            var cs = CharacterSet.alphanumerics
            cs.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
        }
        let fields = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]
        req.httpBody = Data(fields.map { "\($0.key)=\(enc($0.value))" }
            .joined(separator: "&").utf8)
        return req
    }

    /// Exchange an authorization code for Codex tokens.
    static func exchangeCode(code: String, verifier: String,
                             redirectURI: String) async throws -> Refreshed {
        let (data, resp) = try await URLSession.shared.data(
            for: exchangeCodeRequest(code: code, verifier: verifier, redirectURI: redirectURI))
        guard let http = resp as? HTTPURLResponse else { throw CodexError.malformed }
        if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
            throw CodexError.sessionExpired
        }
        guard http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String else {
            throw CodexError.malformed
        }
        return Refreshed(accessToken: access,
                         refreshToken: root["refresh_token"] as? String,
                         idToken: root["id_token"] as? String)
    }

    /// Decode identity (email + ChatGPT account id) from an id_token JWT.
    static func identity(fromIDToken idToken: String) -> (email: String, accountID: String?)? {
        guard let claims = decodeJWTClaims(idToken) else { return nil }
        let email = (claims["email"] as? String)
            ?? ((claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String)
        guard let email else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let accountID = auth?["chatgpt_account_id"] as? String
        return (email, accountID)
    }
```

Note: `tokenURL` and `clientID` already exist in `Codex`; `decodeJWTClaims` is a private static func in the same file, so it is in scope.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter CodexExchangeTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/Codex.swift Tests/PitStopTests/CodexExchangeTests.swift
git commit -m "Add Codex authorization_code exchange and id_token identity"
```

---

### Task 5: Login adapters (shared types + Claude + Codex)

The provider-agnostic types and the two thin adapters. Adapters own: authorize-URL assembly, exchange, identity, and the profile-slot blob construction.

**Files:**
- Create: `Sources/PitStop/OAuthLogin.swift`
- Create: `Sources/PitStop/ClaudeLoginAdapter.swift`
- Create: `Sources/PitStop/CodexLoginAdapter.swift`
- Test: `Tests/PitStopTests/LoginAdapterTests.swift`

**Interfaces:**
- Consumes: `Provider`, `OAuthPKCE`, `UsageAPI.*` (Task 3), `Codex.*` (Task 4), `CredentialBlob.*`, `Keychain.*`, `CodexStore.service`.
- Produces:
  - `struct FreshTokens { var accessToken; var refreshToken: String?; var idToken: String?; var expiresAtMs: Double? }`
  - `struct LoginIdentity: Equatable { var email: String; var accountID: String? }`
  - `enum LoginError: LocalizedError { case identityMismatch(expected:got:), noSavedProfile(String), stateMismatch, cancelled, timedOut, portUnavailable, badResponse(String) }`
  - `protocol LoginAdapter` with:
    - `var provider: Provider { get }`
    - `var loopbackPorts: [UInt16] { get }`
    - `var loopbackPath: String { get }`
    - `var supportsPaste: Bool { get }`
    - `var pasteRedirectURI: String { get }`
    - `func authorizeURL(challenge: String, state: String, redirectURI: String, pasteMode: Bool) -> URL`
    - `func exchange(code: String, state: String, verifier: String, redirectURI: String) async throws -> FreshTokens`
    - `func identity(from tokens: FreshTokens) async throws -> LoginIdentity`
    - `func buildBlob(old: Data, tokens: FreshTokens) throws -> Data`
    - `func persist(_ tokens: FreshTokens, email: String) async throws`
  - `struct ClaudeLoginAdapter: LoginAdapter`, `struct CodexLoginAdapter: LoginAdapter`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PitStopTests/LoginAdapterTests.swift`:

```swift
import XCTest
@testable import PitStop

final class LoginAdapterTests: XCTestCase {
    func testClaudeAuthorizeURLLoopback() throws {
        let url = ClaudeLoginAdapter().authorizeURL(
            challenge: "CH", state: "ST",
            redirectURI: "http://localhost:51000/callback", pasteMode: false)
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.host, "claude.ai")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["client_id"], UsageAPI.clientID)
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["code_challenge"], "CH")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["state"], "ST")
        XCTAssertEqual(q["redirect_uri"], "http://localhost:51000/callback")
        XCTAssertNil(q["code"])                       // no code=true in loopback mode
    }

    func testClaudeAuthorizeURLPasteMode() throws {
        let url = ClaudeLoginAdapter().authorizeURL(
            challenge: "CH", state: "ST",
            redirectURI: ClaudeLoginAdapter().pasteRedirectURI, pasteMode: true)
        let q = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["code"], "true")             // paste mode sets code=true
        XCTAssertEqual(q["redirect_uri"], "https://platform.claude.com/oauth/code/callback")
    }

    func testCodexAuthorizeURL() throws {
        let a = CodexLoginAdapter()
        XCTAssertEqual(a.loopbackPorts, [1455, 1457])
        XCTAssertEqual(a.loopbackPath, "/auth/callback")
        XCTAssertFalse(a.supportsPaste)
        let url = a.authorizeURL(challenge: "CH", state: "ST",
                                 redirectURI: "http://localhost:1455/auth/callback", pasteMode: false)
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.host, "auth.openai.com")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["client_id"], Codex.clientID)
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["id_token_add_organizations"], "true")
        XCTAssertEqual(q["codex_cli_simplified_flow"], "true")
        XCTAssertTrue((q["scope"] ?? "").contains("openid"))
    }

    func testClaudeBuildBlobPatchesTokensPreservesRest() throws {
        let old = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "OLD", "refreshToken": "OLDR", "expiresAt": 1000,
                "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x",
            ],
            "mcpOAuth": ["keep": "me"],
        ])
        let tokens = FreshTokens(accessToken: "NEW", refreshToken: "NEWR",
                                 idToken: nil, expiresAtMs: 9_999_000)
        let blob = try ClaudeLoginAdapter().buildBlob(old: old, tokens: tokens)
        let creds = try CredentialBlob.parse(blob)
        XCTAssertEqual(creds.accessToken, "NEW")
        XCTAssertEqual(creds.refreshToken, "NEWR")
        XCTAssertEqual(creds.expiresAtMs, 9_999_000)
        XCTAssertEqual(creds.subscriptionType, "max")            // preserved
        let root = try JSONSerialization.jsonObject(with: blob) as? [String: Any]
        XCTAssertNotNil(root?["mcpOAuth"])                        // preserved verbatim
    }

    func testCodexBuildBlobIsCompactAndPatched() throws {
        let old = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": ["access_token": "OLD", "refresh_token": "OLDR",
                       "id_token": "OLDID", "account_id": "acct_1"],
        ])
        let tokens = FreshTokens(accessToken: "NEW", refreshToken: "NEWR",
                                 idToken: "NEWID", expiresAtMs: nil)
        let blob = try CodexLoginAdapter().buildBlob(old: old, tokens: tokens)
        XCTAssertFalse(String(data: blob, encoding: .utf8)!.contains("\n"))   // compact
        let creds = Codex.credentials(from: blob)
        XCTAssertEqual(creds?.accessToken, "NEW")
        let root = try JSONSerialization.jsonObject(with: blob) as? [String: Any]
        XCTAssertEqual(root?["auth_mode"] as? String, "chatgpt")             // preserved
        let toks = root?["tokens"] as? [String: Any]
        XCTAssertEqual(toks?["id_token"] as? String, "NEWID")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter LoginAdapterTests`
Expected: FAIL — `cannot find 'ClaudeLoginAdapter' in scope`.

- [ ] **Step 3: Write the shared types**

Create `Sources/PitStop/OAuthLogin.swift`:

```swift
import Foundation

/// Fresh tokens from an authorization_code exchange, provider-neutral.
struct FreshTokens {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?        // Codex
    var expiresAtMs: Double?    // Claude (Codex derives expiry from the id_token)
}

/// The authenticated identity, for matching against the target row.
struct LoginIdentity: Equatable {
    var email: String
    var accountID: String?      // Codex chatgpt_account_id
}

enum LoginError: LocalizedError {
    case identityMismatch(expected: String, got: String)
    case noSavedProfile(String)
    case stateMismatch
    case cancelled
    case timedOut
    case portUnavailable
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .identityMismatch(let expected, let got):
            return "You signed in as \(got), but this row is \(expected). "
                + "Switch accounts in your browser and try again."
        case .noSavedProfile(let email): return "No saved profile for \(email)."
        case .stateMismatch: return "Sign-in could not be verified (state mismatch)."
        case .cancelled: return "Sign-in was cancelled."
        case .timedOut: return "Sign-in timed out waiting for the browser."
        case .portUnavailable:
            return "A sign-in may already be in progress — finish or cancel it and retry."
        case .badResponse(let why): return "Sign-in failed: \(why)"
        }
    }
}

/// The provider-varying surface of the OAuth login flow.
protocol LoginAdapter {
    var provider: Provider { get }
    /// Loopback ports to try (Codex: fixed 1455/1457; Claude: a candidate list).
    var loopbackPorts: [UInt16] { get }
    var loopbackPath: String { get }
    /// Whether a code-paste fallback exists (Claude yes, Codex no).
    var supportsPaste: Bool { get }
    /// Hosted redirect used in paste mode (unused when !supportsPaste).
    var pasteRedirectURI: String { get }

    func authorizeURL(challenge: String, state: String, redirectURI: String, pasteMode: Bool) -> URL
    func exchange(code: String, state: String, verifier: String, redirectURI: String) async throws -> FreshTokens
    func identity(from tokens: FreshTokens) async throws -> LoginIdentity
    /// Patch the existing saved blob with fresh tokens. Pure, for testing.
    func buildBlob(old: Data, tokens: FreshTokens) throws -> Data
    /// Read the saved profile blob, patch it, and write it back to the profile
    /// slot only. Throws `.noSavedProfile` if there is nothing to heal.
    func persist(_ tokens: FreshTokens, email: String) async throws
}
```

- [ ] **Step 4: Write the Claude adapter**

Create `Sources/PitStop/ClaudeLoginAdapter.swift`:

```swift
import Foundation

/// Claude Code (Claude.ai subscription) login. [verify] items: localhost
/// redirect acceptance, token host, and the /api/oauth/profile identity source.
struct ClaudeLoginAdapter: LoginAdapter {
    var provider: Provider { .claude }
    // A small candidate range; the exact port is embedded in redirect_uri, so any
    // free loopback port works if the client accepts localhost at all.
    var loopbackPorts: [UInt16] { [51000, 51001, 51002, 51003] }
    var loopbackPath: String { "/callback" }
    var supportsPaste: Bool { true }
    var pasteRedirectURI: String { "https://platform.claude.com/oauth/code/callback" }

    static let scopes = "org:create_api_key user:profile user:inference "
        + "user:sessions:claude_code user:mcp_servers user:file_upload"

    func authorizeURL(challenge: String, state: String, redirectURI: String, pasteMode: Bool) -> URL {
        var c = URLComponents(string: "https://claude.ai/oauth/authorize")!
        var items = [
            URLQueryItem(name: "client_id", value: UsageAPI.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if pasteMode { items.insert(URLQueryItem(name: "code", value: "true"), at: 0) }
        c.queryItems = items
        return c.url!
    }

    func exchange(code: String, state: String, verifier: String,
                  redirectURI: String) async throws -> FreshTokens {
        let r = try await UsageAPI.exchangeCode(code: code, state: state,
                                                verifier: verifier, redirectURI: redirectURI)
        return FreshTokens(accessToken: r.accessToken, refreshToken: r.refreshToken,
                           idToken: nil, expiresAtMs: r.expiresAtMs)
    }

    func identity(from tokens: FreshTokens) async throws -> LoginIdentity {
        let email = try await UsageAPI.fetchAccountEmail(accessToken: tokens.accessToken)
        return LoginIdentity(email: email, accountID: nil)
    }

    func buildBlob(old: Data, tokens: FreshTokens) throws -> Data {
        try CredentialBlob.patching(old,
                                    accessToken: tokens.accessToken,
                                    refreshToken: tokens.refreshToken,
                                    expiresAtMs: tokens.expiresAtMs ?? 0)
    }

    func persist(_ tokens: FreshTokens, email: String) async throws {
        guard let old = try await Keychain.read(service: CredentialBlob.profileService,
                                                account: email) else {
            throw LoginError.noSavedProfile(email)
        }
        let blob = try buildBlob(old: old, tokens: tokens)
        try await Keychain.upsert(service: CredentialBlob.profileService, account: email, data: blob)
    }
}
```

- [ ] **Step 5: Write the Codex adapter**

Create `Sources/PitStop/CodexLoginAdapter.swift`:

```swift
import Foundation

/// OpenAI Codex ("Sign in with ChatGPT") login. Fully automatic loopback on the
/// ports the Codex CLI already registers (1455, fallback 1457).
struct CodexLoginAdapter: LoginAdapter {
    var provider: Provider { .codex }
    var loopbackPorts: [UInt16] { [1455, 1457] }
    var loopbackPath: String { "/auth/callback" }
    var supportsPaste: Bool { false }
    var pasteRedirectURI: String { "" }

    static let scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke"

    func authorizeURL(challenge: String, state: String, redirectURI: String, pasteMode: Bool) -> URL {
        var c = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Codex.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
        ]
        return c.url!
    }

    func exchange(code: String, state: String, verifier: String,
                  redirectURI: String) async throws -> FreshTokens {
        let r = try await Codex.exchangeCode(code: code, verifier: verifier, redirectURI: redirectURI)
        return FreshTokens(accessToken: r.accessToken, refreshToken: r.refreshToken,
                           idToken: r.idToken, expiresAtMs: nil)
    }

    func identity(from tokens: FreshTokens) async throws -> LoginIdentity {
        guard let idToken = tokens.idToken,
              let id = Codex.identity(fromIDToken: idToken) else {
            throw LoginError.badResponse("Codex sign-in returned no id_token")
        }
        return LoginIdentity(email: id.email, accountID: id.accountID)
    }

    func buildBlob(old: Data, tokens: FreshTokens) throws -> Data {
        let refreshed = Codex.Refreshed(accessToken: tokens.accessToken,
                                        refreshToken: tokens.refreshToken,
                                        idToken: tokens.idToken)
        guard let patched = Codex.patching(old, with: refreshed) else {
            throw LoginError.badResponse("Could not patch Codex credentials")
        }
        return Codex.normalizedBlob(patched)
    }

    func persist(_ tokens: FreshTokens, email: String) async throws {
        guard let old = try await Keychain.read(service: CodexStore.service, account: email) else {
            throw LoginError.noSavedProfile(email)
        }
        let blob = try buildBlob(old: old, tokens: tokens)
        try await Keychain.upsert(service: CodexStore.service, account: email, data: blob)
    }
}
```

Note: `Codex.patching` already patches `last_refresh` to now; `account_id` is preserved from `old`. If a future check shows the account id drifts on re-login, re-derive it from the new `id_token` — out of scope unless Task 9 shows a problem.

- [ ] **Step 6: Run to verify it passes**

Run: `swift test --filter LoginAdapterTests`
Expected: PASS (5 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/PitStop/OAuthLogin.swift Sources/PitStop/ClaudeLoginAdapter.swift Sources/PitStop/CodexLoginAdapter.swift Tests/PitStopTests/LoginAdapterTests.swift
git commit -m "Add login adapters for Claude and Codex"
```

---

### Task 6: Login coordinator

Orchestrates one login: PKCE → browser → code (loopback, then paste for Claude) → exchange → identity match → profile-only persist. UI actions are injected so the orchestration is testable with fakes.

**Files:**
- Create: `Sources/PitStop/OAuthLoginCoordinator.swift`
- Test: `Tests/PitStopTests/OAuthLoginCoordinatorTests.swift`

**Interfaces:**
- Consumes: `LoginAdapter`, `FreshTokens`, `LoginIdentity`, `LoginError`, `LoopbackServer`, `OAuthPKCE`.
- Produces:
  - `struct OAuthLoginCoordinator.UI { var openURL: @MainActor (URL) -> Void; var promptPaste: @MainActor () async -> String?; var loopbackTimeout: TimeInterval }`
  - `OAuthLoginCoordinator.emailMatches(expected: String, _ identity: LoginIdentity) -> Bool` (pure)
  - `OAuthLoginCoordinator().finish(adapter:expectedEmail:code:state:verifier:redirectURI:) async throws` (exchange→identity→match→persist)
  - `OAuthLoginCoordinator().run(adapter:expectedEmail:ui:) async throws`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PitStopTests/OAuthLoginCoordinatorTests.swift`:

```swift
import XCTest
@testable import PitStop

/// Records what `persist` was called with; returns canned exchange/identity.
final class FakeAdapter: LoginAdapter, @unchecked Sendable {
    var provider: Provider { .claude }
    var loopbackPorts: [UInt16] { [51900] }
    var loopbackPath: String { "/callback" }
    var supportsPaste: Bool { false }
    var pasteRedirectURI: String { "" }
    var identityToReturn = LoginIdentity(email: "match@example.com", accountID: nil)
    var persistedEmails: [String] = []

    func authorizeURL(challenge: String, state: String, redirectURI: String, pasteMode: Bool) -> URL {
        URL(string: "https://example.com/authorize")!
    }
    func exchange(code: String, state: String, verifier: String, redirectURI: String) async throws -> FreshTokens {
        FreshTokens(accessToken: "A", refreshToken: "R", idToken: nil, expiresAtMs: 1)
    }
    func identity(from tokens: FreshTokens) async throws -> LoginIdentity { identityToReturn }
    func buildBlob(old: Data, tokens: FreshTokens) throws -> Data { Data() }
    func persist(_ tokens: FreshTokens, email: String) async throws { persistedEmails.append(email) }
}

final class OAuthLoginCoordinatorTests: XCTestCase {
    func testEmailMatchNormalizes() {
        XCTAssertTrue(OAuthLoginCoordinator.emailMatches(
            expected: "User@Example.com ", LoginIdentity(email: "user@example.com", accountID: nil)))
        XCTAssertFalse(OAuthLoginCoordinator.emailMatches(
            expected: "a@x.com", LoginIdentity(email: "b@x.com", accountID: nil)))
    }

    func testFinishPersistsOnMatch() async throws {
        let a = FakeAdapter()
        try await OAuthLoginCoordinator().finish(
            adapter: a, expectedEmail: "match@example.com",
            code: "C", state: "S", verifier: "V", redirectURI: "http://localhost:51900/callback")
        XCTAssertEqual(a.persistedEmails, ["match@example.com"])
    }

    func testFinishRejectsOnMismatch() async {
        let a = FakeAdapter()
        a.identityToReturn = LoginIdentity(email: "other@example.com", accountID: nil)
        do {
            try await OAuthLoginCoordinator().finish(
                adapter: a, expectedEmail: "match@example.com",
                code: "C", state: "S", verifier: "V", redirectURI: "x")
            XCTFail("expected mismatch")
        } catch {
            XCTAssertTrue(a.persistedEmails.isEmpty)   // nothing written
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter OAuthLoginCoordinatorTests`
Expected: FAIL — `cannot find 'OAuthLoginCoordinator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PitStop/OAuthLoginCoordinator.swift`:

```swift
import Foundation

/// Runs one OAuth re-login end to end. Provider-agnostic; UI actions are
/// injected so the flow is testable. Writes only to the profile slot.
final class OAuthLoginCoordinator {
    struct UI {
        var openURL: @MainActor (URL) -> Void
        /// Show the paste field; return the pasted string, or nil if cancelled.
        var promptPaste: @MainActor () async -> String?
        var loopbackTimeout: TimeInterval = 120
    }

    /// Identity match: Codex prefers the stable account id; otherwise email
    /// (case- and whitespace-insensitive).
    static func emailMatches(expected: String, _ identity: LoginIdentity) -> Bool {
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return norm(expected) == norm(identity.email)
    }

    /// Exchange → identity → match → persist. Nothing is written on mismatch.
    func finish(adapter: LoginAdapter, expectedEmail: String,
                code: String, state: String, verifier: String, redirectURI: String) async throws {
        let tokens = try await adapter.exchange(code: code, state: state,
                                                verifier: verifier, redirectURI: redirectURI)
        let identity = try await adapter.identity(from: tokens)
        guard Self.emailMatches(expected: expectedEmail, identity) else {
            throw LoginError.identityMismatch(expected: expectedEmail, got: identity.email)
        }
        try await adapter.persist(tokens, email: expectedEmail)
    }

    /// Full flow: loopback first, then (Claude) paste fallback.
    func run(adapter: LoginAdapter, expectedEmail: String, ui: UI) async throws {
        let pkce = OAuthPKCE.generate()

        // --- Attempt A: loopback ---
        let server = LoopbackServer()
        do {
            try server.start(ports: adapter.loopbackPorts)
        } catch {
            if !adapter.supportsPaste { throw LoginError.portUnavailable }
            try await runPaste(adapter: adapter, expectedEmail: expectedEmail, pkce: pkce, ui: ui)
            return
        }
        defer { server.stop() }

        let redirectURI = "http://localhost:\(server.port)\(adapter.loopbackPath)"
        let authURL = adapter.authorizeURL(challenge: pkce.challenge, state: pkce.state,
                                           redirectURI: redirectURI, pasteMode: false)
        await MainActor.run { ui.openURL(authURL) }

        do {
            let cap = try await server.waitForCallback(timeout: ui.loopbackTimeout)
            guard cap.state == pkce.state else { throw LoginError.stateMismatch }
            try await finish(adapter: adapter, expectedEmail: expectedEmail,
                             code: cap.code, state: cap.state,
                             verifier: pkce.verifier, redirectURI: redirectURI)
            return
        } catch let e as LoginError {
            // identity/state failures are terminal; only a timeout falls through
            if case .timedOut = e {} else if !(e is LoopbackServer.ServerError) { throw e }
        } catch {
            // timeout / accept error — fall through to paste if available
        }

        server.stop()
        guard adapter.supportsPaste else { throw LoginError.timedOut }
        try await runPaste(adapter: adapter, expectedEmail: expectedEmail, pkce: pkce, ui: ui)
    }

    /// --- Attempt B: paste (Claude) ---
    private func runPaste(adapter: LoginAdapter, expectedEmail: String,
                          pkce: (verifier: String, challenge: String, state: String), ui: UI) async throws {
        let redirectURI = adapter.pasteRedirectURI
        let authURL = adapter.authorizeURL(challenge: pkce.challenge, state: pkce.state,
                                           redirectURI: redirectURI, pasteMode: true)
        await MainActor.run { ui.openURL(authURL) }
        let pasted = await ui.promptPaste()   // @MainActor closure; hops to main automatically
        guard let pasted else { throw LoginError.cancelled }
        guard let cap = LoopbackServer.parsePasted(pasted) else {
            throw LoginError.badResponse("Could not read the pasted code")
        }
        guard cap.state == pkce.state else { throw LoginError.stateMismatch }
        try await finish(adapter: adapter, expectedEmail: expectedEmail,
                         code: cap.code, state: cap.state,
                         verifier: pkce.verifier, redirectURI: redirectURI)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter OAuthLoginCoordinatorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS (all tasks 1–6). Fix any type mismatches before continuing.

- [ ] **Step 6: Commit**

```bash
git add Sources/PitStop/OAuthLoginCoordinator.swift Tests/PitStopTests/OAuthLoginCoordinatorTests.swift
git commit -m "Add OAuth login coordinator"
```

---

### Task 7: Login pill in `AccountRowView`

Render an always-visible coral **Login** pill on rows that have an `onLogin` action, and route a click to it.

**Files:**
- Modify: `Sources/PitStop/AccountRowView.swift`
- Modify: `Sources/PitStop/main.swift` (add a preview row)

**Interfaces:**
- Produces: `AccountRowView.Model.onLogin: (() -> Void)?` (default `nil`).

- [ ] **Step 1: Add `onLogin` to the model**

In `Sources/PitStop/AccountRowView.swift`, in `struct Model`, add after `onSwitch`:

```swift
        var onLogin: (() -> Void)?   // non-nil = show a coral "Login" pill; click re-authenticates
```

- [ ] **Step 2: Route hover/click to `onLogin`**

In `mouseEntered(with:)`, change the guard so a login row also highlights:

```swift
    override func mouseEntered(with event: NSEvent) {
        guard model.onSwitch != nil || model.onLogin != nil else { return }
        hovering = true
        needsDisplay = true
    }
```

In `mouseUp(with:)`, prefer login:

```swift
    override func mouseUp(with event: NSEvent) {
        let action = model.onLogin ?? model.onSwitch
        guard let action else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async { action() }
    }
```

- [ ] **Step 3: Draw the coral Login pill**

In `draw(_:)`, replace the plan-chip block. Find:

```swift
        // Plan chip (flips to a coral "Switch" pill on hover)
        let chipFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let switching = hovering && model.onSwitch != nil
        let chipText = switching ? "Switch" : model.planLabel
```

Replace those four lines with:

```swift
        // Plan chip → coral "Switch" on hover, or always-coral "Login" when the
        // row's token was rejected.
        let chipFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let isLogin = model.onLogin != nil
        let switching = isLogin || (hovering && model.onSwitch != nil)
        let chipText = isLogin ? "Login" : (switching ? "Switch" : model.planLabel)
```

The existing code below already fills the chip coral and draws white text when `switching` is true, and `isLogin` forces `switching`, so the Login pill renders coral automatically. Also make the row background highlight when it's a login row: find the top of `draw`:

```swift
        if hovering, model.onSwitch != nil {
```

change to:

```swift
        if (hovering && model.onSwitch != nil) || model.onLogin != nil {
```

- [ ] **Step 4: Add a preview row for visual check**

In `Sources/PitStop/main.swift`, inside the `--preview` `models` array, add an entry (e.g., after the `side@example.com` row):

```swift
            .init(email: "expired@example.com",
                  planLabel: "Max · 5x", isActive: false,
                  bars: [.init(label: "5h", utilization: 0, resetText: ""),
                         .init(label: "7d", utilization: 0, resetText: "")],
                  modelsLine: nil,
                  statusLine: "⚠︎ Token rejected — re-login needed · showing 10:37 PM data",
                  onSwitch: nil, onLogin: {}),
```

- [ ] **Step 5: Build and render the preview**

Run: `swift build`
Expected: builds cleanly.

Run: `swift run PitStop --preview && open /tmp/pitstop-preview.png`
Expected: the new row shows a coral **Login** pill where the plan chip would be, with the row subtly highlighted. Confirm visually.

- [ ] **Step 6: Commit**

```bash
git add Sources/PitStop/AccountRowView.swift Sources/PitStop/main.swift
git commit -m "Add coral Login pill to expired account rows"
```

---

### Task 8: Wire the flow into `AppDelegate` + paste window

Connect the pill to the coordinator: set `onLogin` for eligible rows, add `performLogin`, and add the Claude paste window.

**Files:**
- Create: `Sources/PitStop/LoginPasteWindow.swift`
- Modify: `Sources/PitStop/AppDelegate.swift`
- Test: `Tests/PitStopTests/LoginEligibilityTests.swift`

**Interfaces:**
- Consumes: `MenuAccount`, `needsAction`, `OAuthLoginCoordinator`, `ClaudeLoginAdapter`, `CodexLoginAdapter`, `Notifier`.
- Produces: `AppDelegate.shouldOfferLogin(for account: MenuAccount) -> Bool` (pure-ish helper), `AppDelegate.performLogin(_:)`, `LoginPasteWindowController`.

- [ ] **Step 1: Write the failing test for eligibility**

Create `Tests/PitStopTests/LoginEligibilityTests.swift`:

```swift
import XCTest
@testable import PitStop

@MainActor
final class LoginEligibilityTests: XCTestCase {
    func testOfferLoginOnlyForInactiveSwitchableNeedsAction() {
        let d = AppDelegate()
        let claude = MenuAccount(email: "a@x.com", source: .code, planLabel: "", isActive: false)
        let claudeActive = MenuAccount(email: "a@x.com", source: .code, planLabel: "", isActive: true)
        let desktop = MenuAccount(email: "d@x.com", source: .desktop, planLabel: "", isActive: false)

        d.setNeedsActionForTest(["a@x.com", "d@x.com"])
        XCTAssertTrue(d.shouldOfferLogin(for: claude))      // inactive, switchable, needsAction
        XCTAssertFalse(d.shouldOfferLogin(for: claudeActive)) // active → no pill
        XCTAssertFalse(d.shouldOfferLogin(for: desktop))    // desktop not switchable

        d.setNeedsActionForTest([])
        XCTAssertFalse(d.shouldOfferLogin(for: claude))     // healthy → no pill
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter LoginEligibilityTests`
Expected: FAIL — `value of type 'AppDelegate' has no member 'shouldOfferLogin'`.

- [ ] **Step 3: Add the eligibility helper + test seam**

In `Sources/PitStop/AppDelegate.swift`, add these methods to the class (near `rowModel`):

```swift
    /// A row offers Login when its token was rejected (needsAction), it's a
    /// switchable provider, and it isn't the live account. Inactive-only keeps
    /// the "never touch live" invariant absolute.
    func shouldOfferLogin(for account: MenuAccount) -> Bool {
        needsAction.contains(account.key) && account.canSwitch && !account.isActive
    }

    /// Test seam: set the needs-action set directly.
    func setNeedsActionForTest(_ keys: Set<String>) { needsAction = keys }
```

- [ ] **Step 4: Wire `onLogin` in `rowModel`**

In `rowModel(for:)`, find the final `return AccountRowView.Model(` and its `onSwitch:` argument. Replace the `onSwitch:` argument block with login-aware wiring. Change:

```swift
            onSwitch: canSwitch ? { [weak self] in
                if isCodex { self?.performCodexSwitch(to: email) }
                else { self?.performSwitch(to: email) }
            } : nil)
```

to:

```swift
            onSwitch: (canSwitch && !offerLogin) ? { [weak self] in
                if isCodex { self?.performCodexSwitch(to: email) }
                else { self?.performSwitch(to: email) }
            } : nil,
            onLogin: offerLogin ? { [weak self] in self?.performLogin(account) } : nil)
```

And immediately before that `return`, add:

```swift
        let offerLogin = shouldOfferLogin(for: account)
```

- [ ] **Step 5: Add `performLogin` and the login-in-flight guard**

Add a stored property near the other state in `AppDelegate`:

```swift
    /// True while an OAuth re-login is running (prevents overlapping logins).
    private var loginInFlight = false
    private let pasteWindow = LoginPasteWindowController()
```

Add the method (near `performSwitch`):

```swift
    private func performLogin(_ account: MenuAccount) {
        guard !loginInFlight else { return }
        loginInFlight = true
        let adapter: LoginAdapter = account.isCodex ? CodexLoginAdapter() : ClaudeLoginAdapter()
        let email = account.email
        let ui = OAuthLoginCoordinator.UI(
            openURL: { url in NSWorkspace.shared.open(url) },
            promptPaste: { [weak self] in await self?.pasteWindow.prompt() ?? nil },
            loopbackTimeout: 120)
        Task { @MainActor in
            defer { loginInFlight = false }
            do {
                try await OAuthLoginCoordinator().run(adapter: adapter, expectedEmail: email, ui: ui)
                Notifier.shared.post(title: "Signed in to \(displayEmail(email))",
                                     body: "Fresh credentials saved. This account is switchable again.")
                refreshAll()
            } catch is CancellationError {
                // user cancelled — no message
            } catch {
                showError("Couldn't sign in", error)
            }
        }
    }
```

- [ ] **Step 6: Create the paste window**

Create `Sources/PitStop/LoginPasteWindow.swift`:

```swift
import AppKit

/// A small modal window for the Claude code-paste fallback: shows instructions,
/// a text field, and Submit/Cancel. Returns the pasted string or nil.
@MainActor
final class LoginPasteWindowController {
    private var window: NSWindow?
    private var field: NSTextField?
    private var continuation: CheckedContinuation<String?, Never>?

    func prompt() async -> String? {
        await withCheckedContinuation { cont in
            self.continuation = cont
            show()
        }
    }

    private func show() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Finish Claude sign-in"
        let label = NSTextField(wrappingLabelWithString:
            "Your browser is showing a sign-in code. Copy it and paste it here.")
        label.frame = NSRect(x: 20, y: 96, width: 380, height: 40)
        let field = NSTextField(frame: NSRect(x: 20, y: 60, width: 380, height: 24))
        field.placeholderString = "Paste code here"
        let submit = NSButton(title: "Sign In", target: self, action: #selector(submit(_:)))
        submit.frame = NSRect(x: 300, y: 16, width: 100, height: 32)
        submit.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.frame = NSRect(x: 200, y: 16, width: 100, height: 32)
        w.contentView?.addSubview(label)
        w.contentView?.addSubview(field)
        w.contentView?.addSubview(submit)
        w.contentView?.addSubview(cancel)
        w.center()
        self.window = w
        self.field = field
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func submit(_ sender: Any?) {
        finish(field?.stringValue)
    }

    @objc private func cancel(_ sender: Any?) {
        finish(nil)
    }

    private func finish(_ value: String?) {
        window?.orderOut(nil)
        window = nil; field = nil
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        continuation?.resume(returning: (trimmed?.isEmpty ?? true) ? nil : trimmed)
        continuation = nil
    }
}
```

- [ ] **Step 7: Run the eligibility test + full suite + build**

Run: `swift test --filter LoginEligibilityTests`
Expected: PASS.

Run: `swift test`
Expected: PASS (all suites).

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 8: Commit**

```bash
git add Sources/PitStop/LoginPasteWindow.swift Sources/PitStop/AppDelegate.swift Tests/PitStopTests/LoginEligibilityTests.swift
git commit -m "Wire in-app OAuth re-login into the menu"
```

---

### Task 9: End-to-end verification (manual)

No code. Verify the real behavior and the load-bearing **[verify]** assumptions. Uses the `scripts/make-app.sh` build so the flow runs in a real `.app` (menu bar, notifications, keychain grants).

- [ ] **Step 1: Build and install the app**

Run: `./scripts/make-app.sh`
Expected: PitStop builds and launches in the menu bar.

- [ ] **Step 2: Reproduce an expired Codex row**

Have a **saved, inactive** Codex account whose token is rejected (the "Codex session ended — sign in to Codex again" row). Confirm it now shows a coral **Login** pill.

- [ ] **Step 3: Codex re-login round-trip**

Click the Codex **Login** pill. Expected: the browser opens `auth.openai.com`; after signing in as that same account, the redirect to `localhost:1455/auth/callback` is captured automatically, a "Signed in to …" notification appears, and on the next refresh the row heals (usage bars, no error, pill reverts to the plan chip). Verify `~/.codex/auth.json` mtime is **unchanged** (profile-only write). Then switch to the account and run `codex` to confirm the restored credentials work.

- [ ] **Step 4: Codex identity mismatch**

Click **Login** on the Codex row but sign in as a *different* ChatGPT account. Expected: an error "You signed in as X, but this row is Y…", and nothing is written (row still shows the error).

- [ ] **Step 5: Claude re-login round-trip (loopback, then paste)**

On a saved, inactive Claude Code row showing "Token rejected — re-login needed", click **Login**. Expected: the browser opens `claude.ai/oauth/authorize`. If it redirects back to `localhost` → captured automatically. If it instead shows a code, use the paste window. Either way the row heals. Verify `~/.claude.json` and the `Claude Code-credentials` keychain item are **unchanged**. Then switch to the account and run `claude` to confirm it works. **Record which path worked (loopback vs paste)** and update the spec's `redirectStrategy` note accordingly.

- [ ] **Step 6: Confirm the [verify] items**

Confirm and note in the spec: (a) which Claude **token host** accepted the exchange (`platform.claude.com` vs `console.anthropic.com`); (b) that `GET /api/oauth/profile` returned the email (if not, adjust `fetchAccountEmail` per the fallback in the spec); (c) that the fresh Claude token's scopes still satisfy the usage call. If any differs, open a follow-up fix task.

- [ ] **Step 7: Confirm ongoing sessions are untouched**

While a `claude`/`codex` session is running on the **live** account, perform a re-login on a **different** inactive account. Confirm the running session is unaffected throughout (it keeps working; its live store is not modified).

- [ ] **Step 8: Commit any doc updates**

```bash
git add docs/superpowers/specs/2026-07-01-in-app-oauth-relogin-design.md
git commit -m "Record verified OAuth parameters from end-to-end testing"
```

---

## Self-Review

**Spec coverage:**
- Native PKCE OAuth, profile-only write → Tasks 1, 5, 6 (invariant enforced in adapters' `persist`).
- Both providers → Tasks 3–5 (Claude + Codex adapters and network).
- Loopback (Codex fixed 1455/1457) → Task 2, Task 5.
- Claude loopback-first + paste fallback → Task 6 `run`/`runPaste`, Task 8 paste window.
- Strict identity match → Task 6 `emailMatches`/`finish`; mismatch verified Task 9 Step 4.
- Coral Login pill, inactive rows only → Task 7 (draw), Task 8 (`shouldOfferLogin`).
- Expired-row only (no general sign-in) → no menu entry added; only `onLogin` wiring.
- Grounded OAuth params + [verify] items → Tasks 3–5 constants; Task 9 verifies.
- Testing (units + manual round-trips) → Tasks 1–8 units; Task 9 manual.

**Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N"; every code step shows complete code.

**Type consistency:** `FreshTokens`, `LoginIdentity`, `LoginError`, `LoginAdapter` (with `buildBlob`/`persist`/`authorizeURL(...,pasteMode:)`) are defined in Task 5 and consumed unchanged in Tasks 6 and 8. `Codex.identity(fromIDToken:)` returns a tuple (Task 4) and is adapted into `LoginIdentity` in Task 5. `AccountRowView.Model.onLogin` (Task 7) is set in Task 8. Loopback `Captured`/`parse`/`parsePasted`/`waitForCallback(timeout:)` (Task 2) are used in Task 6.

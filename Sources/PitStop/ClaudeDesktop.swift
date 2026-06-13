import Foundation
import CommonCrypto

/// Reads the account Claude Desktop is logged into and its usage.
///
/// Claude Desktop is an Electron app that signs into **claude.ai** with a
/// cookie session, not the OAuth-token-in-keychain flow Claude Code uses. So
/// PitStop can observe it but not switch it — these accounts show up read-only.
///
/// The pieces:
///  - The `sessionKey` cookie lives in `~/Library/Application Support/Claude/
///    Cookies` (a Chromium SQLite store), AES-encrypted with a key derived
///    from the `Claude Safe Storage` keychain item (Electron's safeStorage).
///  - That keychain read goes through the same `/usr/bin/security` path as the
///    Claude Code credentials, so it shares the one-time "Always Allow" model.
///  - claude.ai's `/api/bootstrap` gives the account email and its
///    subscription org; `/api/organizations/<uuid>/usage` returns the same
///    payload shape as the OAuth endpoint (so `UsageAPI.parse` is reused).
enum ClaudeDesktop {
    /// The logged-in Claude Desktop account (identity only — no secrets).
    struct Account: Equatable {
        var email: String
        var orgUUID: String
        var planLabel: String
    }

    enum DesktopError: LocalizedError {
        case sessionExpired
        case cookieUnreadable(String)
        case noSubscriptionOrg

        var errorDescription: String? {
            switch self {
            case .sessionExpired:
                return "Claude Desktop session expired — sign in again"
            case .cookieUnreadable(let why):
                return "Couldn't read Claude Desktop session: \(why)"
            case .noSubscriptionOrg:
                return "Claude Desktop account has no Claude subscription"
            }
        }
    }

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }
    static var cookiesURL: URL { supportDirectory.appendingPathComponent("Cookies") }

    /// True when Claude Desktop is installed and has a cookie store at all.
    static var isPresent: Bool {
        FileManager.default.fileExists(atPath: cookiesURL.path)
    }

    private static let safeStorageService = "Claude Safe Storage"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    /// Fetch the Claude Desktop account and its current usage in one pass.
    /// Returns nil when Claude Desktop isn't installed or isn't logged in;
    /// throws (rate-limited / session-expired / unreadable) when it is logged
    /// in but the fetch fails, so the caller can show that on the row.
    static func poll() async throws -> (account: Account, report: UsageReport)? {
        guard isPresent, let session = try await backgroundSessionKey() else { return nil }
        let account = try await fetchAccount(session: session)
        let data = try await get("/api/organizations/\(account.orgUUID)/usage", session: session)
        let report = try UsageAPI.parse(data)
        return (account, report)
    }

    /// Decrypt the session cookie on a background queue. `sessionKey()` shells
    /// out to `sqlite3` and `security` (which can block on a first-run keychain
    /// prompt), so — like `Keychain` — it must never run on the calling actor.
    private static func backgroundSessionKey() async throws -> String? {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try sessionKey()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: - claude.ai API

    /// Resolve the account email and subscription org from `/api/bootstrap`.
    private static func fetchAccount(session: String) async throws -> Account {
        let data = try await get("/api/bootstrap", session: session)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acct = root["account"] as? [String: Any],
              let email = acct["email_address"] as? String else {
            throw DesktopError.cookieUnreadable("unexpected bootstrap response")
        }
        let memberships = acct["memberships"] as? [[String: Any]] ?? []
        let orgs = memberships.compactMap { $0["organization"] as? [String: Any] }
        // The consumer subscription org is the one backing claude.ai chat;
        // the API/console org ("api"/"api_individual") has no usage windows.
        guard let org = orgs.first(where: {
            let caps = $0["capabilities"] as? [String] ?? []
            return caps.contains("chat")
        }), let uuid = org["uuid"] as? String else {
            throw DesktopError.noSubscriptionOrg
        }
        let caps = org["capabilities"] as? [String] ?? []
        let tier = try? await rateLimitTier(orgUUID: uuid, session: session)
        return Account(email: email, orgUUID: uuid,
                       planLabel: planLabel(orgName: org["name"] as? String,
                                            email: email, capabilities: caps, tier: tier))
    }

    /// Best-effort plan tier (`default_claude_max_20x`) for the chip label.
    private static func rateLimitTier(orgUUID: String, session: String) async throws -> String? {
        let data = try await get("/api/organizations/\(orgUUID)/rate_limits", session: session)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return root?["rate_limit_tier"] as? String
    }

    /// "Max · 20x" — mirrors Profile.planLabel: drop auto "<email>'s
    /// Organization" names and the `default_claude_` tier prefix.
    private static func planLabel(orgName: String?, email: String,
                                  capabilities: [String], tier: String?) -> String {
        var parts: [String] = []
        if let org = orgName, !org.isEmpty, org != "\(email)'s Organization" {
            parts.append(org)
        }
        if capabilities.contains("claude_max") { parts.append("Max") }
        else if capabilities.contains("claude_pro") { parts.append("Pro") }
        if let tier, let r = tier.range(of: "max_") {
            parts.append(String(tier[r.upperBound...]))   // "5x" / "20x"
        }
        return parts.joined(separator: " · ")
    }

    private static func get(_ path: String, session: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://claude.ai" + path)!)
        req.setValue("sessionKey=\(session)", forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UsageAPI.APIError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw DesktopError.sessionExpired }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageAPI.APIError.rateLimited(retryAfter: retryAfter)
        }
        guard http.statusCode == 200 else { throw UsageAPI.APIError.http(http.statusCode) }
        return data
    }

    // MARK: - Cookie decryption

    /// The decrypted `sessionKey` cookie value, or nil if there's no such
    /// cookie (Claude Desktop installed but not signed in).
    static func sessionKey() throws -> String? {
        guard let blob = try readEncryptedCookie(name: "sessionKey") else { return nil }
        // v10/v11 prefix, then AES-128-CBC ciphertext.
        guard blob.count > 3 else { throw DesktopError.cookieUnreadable("cookie too short") }
        let ciphertext = blob.dropFirst(3)
        guard let password = try keychainSafeStoragePassword() else {
            throw DesktopError.cookieUnreadable("\(safeStorageService) keychain item missing")
        }
        let key = pbkdf2SHA1(password: password, salt: Data("saltysalt".utf8),
                             rounds: 1003, keyLength: 16)
        let iv = Data(repeating: 0x20, count: 16)   // Chromium uses 16 spaces
        guard let plain = aesCBCDecrypt(Data(ciphertext), key: key, iv: iv) else {
            throw DesktopError.cookieUnreadable("AES decrypt failed")
        }
        // Newer Chromium prepends a 32-byte SHA-256 domain hash to the value.
        for candidate in [plain, plain.count >= 32 ? plain.dropFirst(32) : plain] {
            if let s = String(data: candidate, encoding: .utf8), s.hasPrefix("sk-ant") {
                return s
            }
        }
        throw DesktopError.cookieUnreadable("decrypted value not a session token")
    }

    /// Copy the Cookies SQLite store (Claude Desktop holds it open) and read
    /// the encrypted sessionKey via the `sqlite3` CLI, hex-encoded.
    private static func readEncryptedCookie(name: String) throws -> Data? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("pitstop-cookies-\(ProcessInfo.processInfo.globallyUniqueString)")
        try fm.copyItem(at: cookiesURL, to: tmp)
        defer { try? fm.removeItem(at: tmp) }

        let sql = "SELECT hex(encrypted_value) FROM cookies "
            + "WHERE host_key IN ('.claude.ai','claude.ai') AND name='\(name)' LIMIT 1;"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [tmp.path, sql]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        try p.run()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw DesktopError.cookieUnreadable("sqlite3 exited \(p.terminationStatus)")
        }
        let hex = String(data: out, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !hex.isEmpty else { return nil }   // no sessionKey cookie → not signed in
        return Data(hexString: hex)
    }

    /// Read the Electron safeStorage password through the shared `security`
    /// path (so it gets the same one-time grant as the credential reads).
    private static func keychainSafeStoragePassword() throws -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", safeStorageService, "-w"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        try p.run()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 44 { return nil }   // not found
        guard p.terminationStatus == 0 else {
            throw DesktopError.cookieUnreadable("security exited \(p.terminationStatus)")
        }
        var data = out
        if data.last == 0x0A { data.removeLast() }     // `-w` appends a newline
        return data
    }

    // MARK: - Crypto (CommonCrypto)

    private static func pbkdf2SHA1(password: Data, salt: Data,
                                   rounds: Int, keyLength: Int) -> Data {
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { dk in
            salt.withUnsafeBytes { sp in
                password.withUnsafeBytes { pp in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pp.baseAddress!.assumingMemoryBound(to: CChar.self), password.count,
                        sp.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), UInt32(rounds),
                        dk.baseAddress!.assumingMemoryBound(to: UInt8.self), keyLength)
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed (\(status))")
        return derived
    }

    private static func aesCBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        let capacity = ciphertext.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var moved = 0
        let status = out.withUnsafeMutableBytes { op in
            ciphertext.withUnsafeBytes { cp in
                iv.withUnsafeBytes { ip in
                    key.withUnsafeBytes { kp in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                kp.baseAddress, key.count, ip.baseAddress,
                                cp.baseAddress, ciphertext.count,
                                op.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }
}

private extension Data {
    /// Decode a contiguous hex string (sqlite3's `hex()` output) into bytes.
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }
}

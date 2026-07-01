import Foundation

/// A saved Gemini account. Secret blobs live in the keychain (services
/// "PitStop-gemini-cli" / "PitStop-gemini-antigravity", account = email); this
/// holds only non-secret metadata, persisted to ~/.config/pitstop/gemini-profiles.json.
struct GeminiProfile {
    var email: String
    var savedAt: Date
    var planLabel: String
    var onCli: Bool
    var onAntigravity: Bool

    fileprivate var asDict: [String: Any] {
        ["email": email, "savedAt": savedAt.timeIntervalSince1970,
         "planLabel": planLabel, "onCli": onCli, "onAntigravity": onAntigravity]
    }
    fileprivate init?(dict: [String: Any]) {
        guard let email = dict["email"] as? String else { return nil }
        self.email = email
        self.savedAt = Date(timeIntervalSince1970: (dict["savedAt"] as? NSNumber)?.doubleValue ?? 0)
        self.planLabel = dict["planLabel"] as? String ?? ""
        self.onCli = dict["onCli"] as? Bool ?? false
        self.onAntigravity = dict["onAntigravity"] as? Bool ?? false
    }
    init(email: String, savedAt: Date, planLabel: String, onCli: Bool, onAntigravity: Bool) {
        self.email = email; self.savedAt = savedAt; self.planLabel = planLabel
        self.onCli = onCli; self.onAntigravity = onAntigravity
    }
}

/// The Gemini equivalent of CodexStore, but with TWO live surfaces:
///  - CLI: the file ~/.gemini/oauth_creds.json (+ google_accounts.json active).
///  - Antigravity: the keychain item svce=gemini, acct=antigravity (go-keyring blob).
/// Saved snapshots are PitStop keychain items so a switch restores both surfaces.
final class GeminiStore {
    struct StoreError: LocalizedError { let message: String; var errorDescription: String? { message } }

    static let cliService = "PitStop-gemini-cli"
    static let antigravityService = "PitStop-gemini-antigravity"
    static let liveKeychainService = "gemini"
    static let liveKeychainAccount = "antigravity"
    static let file = ProfileStore.directory.appendingPathComponent("gemini-profiles.json")

    static var geminiDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
    }
    static var cliCredsURL: URL { geminiDir.appendingPathComponent("oauth_creds.json") }
    static var googleAccountsURL: URL { geminiDir.appendingPathComponent("google_accounts.json") }

    private(set) var profiles: [GeminiProfile] = []

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["profiles"] as? [[String: Any]] else { profiles = []; return }
        profiles = list.compactMap(GeminiProfile.init(dict:)).sorted { $0.email < $1.email }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: ProfileStore.directory, withIntermediateDirectories: true)
        let root: [String: Any] = ["profiles": profiles.map(\.asDict)]
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            .write(to: Self.file, options: .atomic)
    }

    // MARK: - Pure blob builders (also used by re-login)

    static func buildCliBlob(access: String, refresh: String?, idToken: String?, expiryMs: Double) -> Data {
        var obj: [String: Any] = ["access_token": access, "token_type": "Bearer",
                                  "expiry_date": expiryMs,
                                  "scope": Gemini.cliClient.scopes + " openid"]
        if let refresh { obj["refresh_token"] = refresh }
        if let idToken { obj["id_token"] = idToken }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    static func buildAntigravityBlob(access: String, refresh: String?, idToken: String?, expiryISO: String) -> Data {
        var token: [String: Any] = ["access_token": access, "token_type": "Bearer", "expiry": expiryISO]
        if let refresh { token["refresh_token"] = refresh }
        if let idToken { token["id_token"] = idToken }
        let inner = (try? JSONSerialization.data(withJSONObject: ["token": token, "auth_method": "consumer"],
                                                 options: [.sortedKeys])) ?? Data()
        return Data(Gemini.encodeGoKeyring(inner).utf8)
    }

    // MARK: - Live reads

    func liveCliBlob() -> Data? { try? Data(contentsOf: Self.cliCredsURL) }

    /// The active Google account email from the shared ~/.gemini/google_accounts.json.
    /// This is the one local identity source both surfaces agree on.
    func activeGoogleEmail() -> String? {
        guard let data = try? Data(contentsOf: Self.googleAccountsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let active = root["active"] as? String, !active.isEmpty else { return nil }
        return active
    }

    func liveCliEmail() -> String? {
        activeGoogleEmail() ?? liveCliBlob().flatMap(Gemini.cliCreds(from:))?.email
    }

    func liveAntigravityBlob() async -> Data? {
        try? await Keychain.read(service: Self.liveKeychainService, account: Self.liveKeychainAccount)
    }

    /// The Antigravity keychain blob carries no id_token/email, so the live
    /// Antigravity account's identity is the shared active Google account
    /// (google_accounts.json), not something decodable from the blob.
    func liveAntigravityEmail() async -> String? {
        guard await liveAntigravityBlob() != nil else { return nil }
        return activeGoogleEmail()
    }

    // MARK: - Snapshot / switch

    /// Snapshot both live surfaces into per-account saved profiles.
    @discardableResult
    func captureCurrent() async throws -> Bool {
        var touched = false
        let cliBlob = liveCliBlob().map(Gemini.normalizedBlob)
        let cliEmail = cliBlob.flatMap(Gemini.cliCreds(from:))?.email
        let agBlob = await liveAntigravityBlob()
        // The Antigravity blob has no identity; its account is the shared active
        // Google account (google_accounts.json), so it merges with the CLI row.
        let agEmail = agBlob != nil ? activeGoogleEmail() : nil

        func upsert(_ blob: Data?, email: String?, service: String) async throws -> Bool {
            guard let blob, let email else { return false }
            if let stored = try? await Keychain.read(service: service, account: email), stored == blob {
                return false
            }
            try await Keychain.upsert(service: service, account: email, data: blob)
            return true
        }
        touched = try await upsert(cliBlob, email: cliEmail, service: Self.cliService) || touched
        touched = try await upsert(agBlob, email: agEmail, service: Self.antigravityService) || touched

        // Merge metadata by email.
        for (email, isCli, isAg) in [(cliEmail, true, false), (agEmail, false, true)] {
            guard let email else { continue }
            let plan = profiles.first(where: { $0.email == email })?.planLabel ?? ""
            var p = profiles.first(where: { $0.email == email })
                ?? GeminiProfile(email: email, savedAt: Date(), planLabel: plan, onCli: false, onAntigravity: false)
            p.savedAt = Date()
            if isCli { p.onCli = true }
            if isAg { p.onAntigravity = true }
            profiles.removeAll { $0.email == email }
            profiles.append(p)
        }
        profiles.sort { $0.email < $1.email }
        if touched { try save() }
        return touched
    }

    /// Set the plan label for an account (from a successful loadCodeAssist).
    func setPlanLabel(_ label: String, email: String) {
        guard let i = profiles.firstIndex(where: { $0.email == email }), !label.isEmpty else { return }
        profiles[i].planLabel = label
        try? save()
    }

    /// Switch both surfaces to `email` (whichever snapshots exist). Snapshots the
    /// current live accounts first so their tokens aren't stranded.
    func switchTo(email: String) async throws {
        _ = try await captureCurrent()
        var wrote = false
        if let cli = try await Keychain.read(service: Self.cliService, account: email) {
            try writeCliLive(cli); wrote = true
        }
        if let ag = try await Keychain.read(service: Self.antigravityService, account: email) {
            try await Keychain.upsertLive(service: Self.liveKeychainService, account: Self.liveKeychainAccount, data: ag); wrote = true
        }
        guard wrote else {
            throw StoreError(message: "No saved Gemini credentials for \(email) — sign in once and save again")
        }
        // Both surfaces read their identity from the shared active Google
        // account, so update it for an Antigravity-only switch too — otherwise
        // the next captureCurrent files the new live AG token under the old email.
        try Self.updateGoogleAccounts(at: Self.googleAccountsURL, active: email)
    }

    /// The blob to fetch usage with for a surface — live for the active account,
    /// saved snapshot otherwise.
    func blob(for email: String, surface: Gemini.Surface, isActive: Bool) async throws -> Data? {
        if isActive {
            if surface == .cli, let live = liveCliBlob() {
                // Trust the live file only when it demonstrably belongs to this
                // account — google_accounts.json "active" (which decided
                // isActive) and oauth_creds.json can diverge. A blob without an
                // id_token can't be verified, so it keeps the old behavior.
                let owner = Gemini.cliCreds(from: live)?.email
                if owner == nil || owner == "Gemini account" || owner == email { return live }
            }
            if surface == .antigravity, let live = await liveAntigravityBlob() { return live }
        }
        let service = surface == .cli ? Self.cliService : Self.antigravityService
        return try await Keychain.read(service: service, account: email)
    }

    /// Persist a snapshot whose token PitStop refreshed itself (inactive only).
    func storeRefreshedBlob(_ data: Data, email: String, surface: Gemini.Surface) async throws {
        let service = surface == .cli ? Self.cliService : Self.antigravityService
        try await Keychain.upsert(service: service, account: email, data: data)
    }

    func remove(email: String) async throws {
        for service in [Self.cliService, Self.antigravityService] {
            try await Keychain.delete(service: service, account: email)
            try? await Keychain.delete(service: service, account: Keychain.stagingAccount(for: email))
        }
        profiles.removeAll { $0.email == email }
        try save()
    }

    /// Write the CLI blob into ~/.gemini/oauth_creds.json (mode 600).
    private func writeCliLive(_ blob: Data) throws {
        try blob.write(to: Self.cliCredsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: Self.cliCredsURL.path)
    }

    /// Set the active email in google_accounts.json, rotating the previous
    /// active into "old" (matching gemini-cli's own bookkeeping).
    static func updateGoogleAccounts(at url: URL, active email: String) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = existing
        }
        var old = (root["old"] as? [String]) ?? []
        if let prev = root["active"] as? String, prev != email, !old.contains(prev) { old.append(prev) }
        root["active"] = email
        root["old"] = old.filter { $0 != email }
        try JSONSerialization.data(withJSONObject: root)
            .write(to: url, options: .atomic)
    }
}

import Foundation

/// A saved Codex account. The secret `auth.json` blob lives in the keychain
/// (service "PitStop-codex", account = email); this struct holds only
/// non-secret metadata, persisted to ~/.config/pitstop/codex-profiles.json.
struct CodexProfile {
    var email: String
    var savedAt: Date
    var planLabel: String

    fileprivate var asDict: [String: Any] {
        ["email": email, "savedAt": savedAt.timeIntervalSince1970, "planLabel": planLabel]
    }

    fileprivate init?(dict: [String: Any]) {
        guard let email = dict["email"] as? String else { return nil }
        self.email = email
        self.savedAt = Date(timeIntervalSince1970: (dict["savedAt"] as? NSNumber)?.doubleValue ?? 0)
        self.planLabel = dict["planLabel"] as? String ?? ""
    }

    init(email: String, savedAt: Date, planLabel: String) {
        self.email = email
        self.savedAt = savedAt
        self.planLabel = planLabel
    }
}

/// The Codex equivalent of `ProfileStore`. The live store is the file
/// `~/.codex/auth.json` (not a keychain item, the one structural difference
/// from Claude); saved snapshots are keychain blobs so switching can restore a
/// previous account by writing its blob back into that file.
final class CodexStore {
    struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let service = "PitStop-codex"
    static let file = ProfileStore.directory.appendingPathComponent("codex-profiles.json")

    private(set) var profiles: [CodexProfile] = []

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["profiles"] as? [[String: Any]] else {
            profiles = []
            return
        }
        profiles = list.compactMap(CodexProfile.init(dict:)).sorted { $0.email < $1.email }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: ProfileStore.directory,
                                                withIntermediateDirectories: true)
        let root: [String: Any] = ["profiles": profiles.map(\.asDict)]
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.file, options: .atomic)
    }

    /// The email of the account currently live in `~/.codex/auth.json`.
    func liveEmail() -> String? {
        Codex.liveBlob().flatMap(Codex.credentials(from:))?.account.email
    }

    /// Snapshot the live Codex account into a saved profile. Called on every
    /// refresh so the saved copy of the live account always holds the newest
    /// tokens. Returns nil when nobody is signed in (or API-key auth).
    @discardableResult
    func captureCurrent() async throws -> CodexProfile? {
        guard let live = Codex.liveBlob(), let creds = Codex.credentials(from: live) else {
            return nil
        }
        let email = creds.account.email
        // Store compact JSON (see Codex.normalizedBlob) — the pretty-printed
        // live file would read back from the keychain hex-encoded.
        let blob = Codex.normalizedBlob(live)

        // Called on every refresh — skip the keychain/file writes when the
        // normalized blob is byte-identical to what we already saved.
        if let existing = profiles.first(where: { $0.email == email }),
           let stored = try? await Keychain.read(service: Self.service, account: email),
           stored == blob {
            return existing
        }

        try await Keychain.upsert(service: Self.service, account: email, data: blob)
        let profile = CodexProfile(email: email, savedAt: Date(),
                                   planLabel: creds.account.planLabel)
        profiles.removeAll { $0.email == email }
        profiles.append(profile)
        profiles.sort { $0.email < $1.email }
        try save()
        return profile
    }

    /// Make `email` the live Codex account: snapshot whatever's currently live
    /// (so its rotated tokens aren't lost), then write the saved blob into
    /// `~/.codex/auth.json`.
    func switchTo(email: String) async throws {
        // A failed snapshot aborts the switch — overwriting auth.json without a
        // fresh copy of the outgoing account could strand its refresh token.
        _ = try await captureCurrent()
        guard let blob = try await Keychain.read(service: Self.service, account: email) else {
            throw StoreError(message: "No saved credentials for \(email) — sign in once with `codex` and save again")
        }
        try writeLive(Codex.preservingAPIKey(from: Codex.liveBlob(), into: blob))
    }

    func remove(email: String) async throws {
        try await Keychain.delete(service: Self.service, account: email)
        try? await Keychain.delete(service: Self.service,
                                   account: Keychain.stagingAccount(for: email))
        profiles.removeAll { $0.email == email }
        try save()
    }

    /// The blob to fetch usage with — the live file for the active account, the
    /// saved snapshot otherwise.
    func blob(for email: String, isActive: Bool) async throws -> Data? {
        if isActive, let live = Codex.liveBlob() { return live }
        return try await Keychain.read(service: Self.service, account: email)
    }

    /// Persist a saved snapshot whose tokens PitStop refreshed itself, so the
    /// next fetch (and any later switch) uses the rotated tokens. Only inactive
    /// accounts are refreshed, so this never touches the live `auth.json`.
    func storeRefreshedBlob(_ data: Data, email: String) async throws {
        try await Keychain.upsert(service: Self.service, account: email,
                                  data: Codex.normalizedBlob(data))
    }

    /// Write a blob into the live `auth.json`, preserving its `600` mode (it
    /// holds secrets). Atomic so a crash can't leave a half-written file.
    private func writeLive(_ blob: Data) throws {
        try blob.write(to: Codex.authURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: Codex.authURL.path)
    }
}

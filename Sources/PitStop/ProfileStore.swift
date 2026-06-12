import Foundation

/// A saved Claude Code account. The secret credential blob lives in the
/// keychain (service "PitStop-profile", account = email); this struct holds
/// only non-secret metadata, persisted to ~/.config/pitstop/profiles.json.
struct Profile {
    var email: String
    var savedAt: Date
    var subscriptionType: String?
    var rateLimitTier: String?
    /// The `oauthAccount` object from ~/.claude.json, kept verbatim so it can
    /// be restored exactly on switch.
    var oauthAccount: [String: Any]

    var displayName: String? { oauthAccount["displayName"] as? String }
    var organizationName: String? { oauthAccount["organizationName"] as? String }

    /// e.g. "Acme AI · Team · 5x" — drops auto-generated "<email>'s
    /// Organization" names and the noisy default_claude_ tier prefix.
    var planLabel: String {
        var parts: [String] = []
        if let org = organizationName, !org.isEmpty,
           org != "\(email)'s Organization" {
            parts.append(org)
        }
        if let sub = subscriptionType, !sub.isEmpty {
            parts.append(sub.capitalized)
        }
        if let tier = rateLimitTier, let r = tier.range(of: "max_") {
            parts.append(String(tier[r.upperBound...]))   // "5x" / "20x"
        }
        return parts.joined(separator: " · ")
    }

    fileprivate var asDict: [String: Any] {
        var d: [String: Any] = [
            "email": email,
            "savedAt": savedAt.timeIntervalSince1970,
            "oauthAccount": oauthAccount,
        ]
        if let subscriptionType { d["subscriptionType"] = subscriptionType }
        if let rateLimitTier { d["rateLimitTier"] = rateLimitTier }
        return d
    }

    fileprivate init?(dict: [String: Any]) {
        guard let email = dict["email"] as? String else { return nil }
        self.email = email
        self.savedAt = Date(timeIntervalSince1970: (dict["savedAt"] as? NSNumber)?.doubleValue ?? 0)
        self.subscriptionType = dict["subscriptionType"] as? String
        self.rateLimitTier = dict["rateLimitTier"] as? String
        self.oauthAccount = dict["oauthAccount"] as? [String: Any] ?? [:]
    }

    init(email: String, savedAt: Date, subscriptionType: String?,
         rateLimitTier: String?, oauthAccount: [String: Any]) {
        self.email = email
        self.savedAt = savedAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.oauthAccount = oauthAccount
    }
}

final class ProfileStore {
    struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/pitstop", isDirectory: true)
    static let file = directory.appendingPathComponent("profiles.json")

    private(set) var profiles: [Profile] = []

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["profiles"] as? [[String: Any]] else {
            profiles = []
            return
        }
        profiles = list.compactMap(Profile.init(dict:)).sorted { $0.email < $1.email }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: Self.directory,
                                                withIntermediateDirectories: true)
        let root: [String: Any] = ["profiles": profiles.map(\.asDict)]
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.file, options: .atomic)
    }

    /// Snapshot the live Claude Code credentials + identity into a profile.
    /// Called on every refresh so the saved copy of the active account always
    /// holds the newest tokens. Returns nil when nobody is logged in.
    @discardableResult
    func captureCurrent() throws -> Profile? {
        guard let blob = try Keychain.read(service: CredentialBlob.liveService) else { return nil }
        guard let account = ClaudeConfig.oauthAccount(),
              let email = account["emailAddress"] as? String else { return nil }

        // Called on every refresh — skip the keychain/file writes when
        // nothing changed since the last capture.
        if let existing = profiles.first(where: { $0.email == email }),
           let storedBlob = try? Keychain.read(service: CredentialBlob.profileService, account: email),
           storedBlob == blob,
           (existing.oauthAccount as NSDictionary) == (account as NSDictionary) {
            return existing
        }

        let creds = try CredentialBlob.parse(blob)
        try Keychain.upsert(service: CredentialBlob.profileService, account: email, data: blob)
        let profile = Profile(email: email, savedAt: Date(),
                              subscriptionType: creds.subscriptionType,
                              rateLimitTier: creds.rateLimitTier,
                              oauthAccount: account)
        profiles.removeAll { $0.email == email }
        profiles.append(profile)
        profiles.sort { $0.email < $1.email }
        try save()
        return profile
    }

    /// Make `email` the live Claude Code account: snapshot whatever is
    /// currently live, then write the profile's blob into the live keychain
    /// item and its identity into ~/.claude.json.
    func switchTo(email: String) throws {
        _ = try? captureCurrent()
        guard let profile = profiles.first(where: { $0.email == email }) else {
            throw StoreError(message: "No saved profile for \(email)")
        }
        guard let blob = try Keychain.read(service: CredentialBlob.profileService, account: email) else {
            throw StoreError(message: "No saved credentials for \(email) — log in once with `claude` and save again")
        }
        try Keychain.upsertLive(service: CredentialBlob.liveService, data: blob)
        try ClaudeConfig.setOauthAccount(profile.oauthAccount)
    }

    func remove(email: String) throws {
        try Keychain.delete(service: CredentialBlob.profileService, account: email)
        profiles.removeAll { $0.email == email }
        try save()
    }

    /// The credential blob to use for a profile — the live item for the
    /// active account (Claude Code keeps that one fresh), the saved copy
    /// otherwise.
    func blob(for email: String, isActive: Bool) throws -> Data? {
        if isActive, let live = try Keychain.read(service: CredentialBlob.liveService) {
            return live
        }
        return try Keychain.read(service: CredentialBlob.profileService, account: email)
    }

    /// Persist a blob whose tokens we refreshed ourselves.
    func storeRefreshedBlob(_ data: Data, email: String, isActive: Bool) throws {
        try Keychain.upsert(service: CredentialBlob.profileService, account: email, data: data)
        if isActive {
            try Keychain.upsertLive(service: CredentialBlob.liveService, data: data)
        }
    }
}

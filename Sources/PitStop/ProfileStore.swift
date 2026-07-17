import Foundation

/// A saved Claude Code organization. The secret credential blob lives in the
/// keychain; this struct holds only non-secret identity and storage metadata.
struct Profile {
    var email: String
    var savedAt: Date
    var subscriptionType: String?
    var rateLimitTier: String?
    /// Keychain account attribute. Old installs used the bare email; keeping
    /// that slot preserves the one credential snapshot they could retain.
    var credentialAccount: String
    /// True once this exact email + organization pairing has been confirmed
    /// against the stored token. Profiles from email-only versions default to
    /// false so their first live capture cannot take the unchanged fast path.
    var identityVerified: Bool
    /// The `oauthAccount` object from ~/.claude.json, kept verbatim so it can
    /// be restored exactly on switch.
    var oauthAccount: [String: Any]

    var displayName: String? { oauthAccount["displayName"] as? String }
    var organizationName: String? { oauthAccount["organizationName"] as? String }
    var identity: ClaudeAccountIdentity? { ClaudeAccountIdentity(oauthAccount: oauthAccount) }
    /// Profiles old enough to lack organizationUuid remain addressable until a
    /// verified live capture upgrades them in place.
    var key: String { identity?.key ?? "claude:legacy:\(email.lowercased())" }

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
            "credentialAccount": credentialAccount,
            "identityVerified": identityVerified,
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
        // Backward compatibility: pre-org-aware snapshots live under email.
        if let credentialAccount = dict["credentialAccount"] as? String,
           !credentialAccount.isEmpty {
            self.credentialAccount = credentialAccount
        } else {
            self.credentialAccount = email
        }
        // Pre-organization versions verified only the email. Missing means
        // this pairing must pass one exact organization check after upgrade.
        self.identityVerified = (dict["identityVerified"] as? Bool) ?? false
    }

    init(email: String, savedAt: Date, subscriptionType: String?,
         rateLimitTier: String?, credentialAccount: String,
         identityVerified: Bool = true, oauthAccount: [String: Any]) {
        self.email = email
        self.savedAt = savedAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.credentialAccount = credentialAccount
        self.identityVerified = identityVerified
        self.oauthAccount = oauthAccount
    }
}

final class ProfileStore {
    struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// captureCurrent pairs credentials from the keychain with an identity
    /// from ~/.claude.json — two stores written by another program at
    /// different moments. These are the ways that pairing can be refused.
    enum CaptureError: LocalizedError {
        /// The token provably belongs to a different organization than the one
        /// ~/.claude.json names (a mid-switch read of crossed stores).
        case mismatch(tokenOwner: ClaudeAccountIdentity, configIdentity: ClaudeAccountIdentity)
        /// The token's owner couldn't be confirmed (network, expiry) — the
        /// pair might be fine, but filing it unverified risks poisoning.
        case unverifiable(String)

        var errorDescription: String? {
            switch self {
            case .mismatch(let owner, let expected):
                if owner.email.caseInsensitiveCompare(expected.email) == .orderedSame {
                    return "Skipped saving \(expected.email) — the credentials belong to another Claude organization"
                }
                return "Skipped saving \(expected.email) — the credentials belong to \(owner.email)"
            case .unverifiable(let why):
                return "Couldn't confirm the logged-in account's identity: \(why)"
            }
        }
    }

    /// Everything captureCurrent touches outside its own state, injectable so
    /// its filing decisions are testable without a real keychain. Defaults
    /// are the production stores.
    struct Deps {
        var file: URL = ProfileStore.file
        var readLive: () async throws -> Data? = {
            try await Keychain.read(service: CredentialBlob.liveService)
        }
        var readProfileBlob: (String) async throws -> Data? = {
            try await Keychain.read(service: CredentialBlob.profileService, account: $0)
        }
        var writeProfileBlob: (String, Data) async throws -> Void = {
            try await Keychain.upsert(service: CredentialBlob.profileService, account: $0, data: $1)
        }
        var deleteProfileBlob: (String) async throws -> Void = {
            try await Keychain.delete(service: CredentialBlob.profileService, account: $0)
            try? await Keychain.delete(service: CredentialBlob.profileService,
                                       account: Keychain.stagingAccount(for: $0))
        }
        var writeLive: (Data) async throws -> Void = {
            try await Keychain.upsertLive(service: CredentialBlob.liveService, data: $0)
        }
        var oauthAccount: () -> [String: Any]? = { ClaudeConfig.oauthAccount() }
        var setOauthAccount: ([String: Any]) throws -> Void = { try ClaudeConfig.setOauthAccount($0) }
        var verifyIdentity: (String) async throws -> ClaudeAccountIdentity = {
            try await UsageAPI.fetchAccountIdentity(accessToken: $0)
        }
        var refreshToken: (String) async throws
            -> (accessToken: String, refreshToken: String?, expiresAtMs: Double) = {
            try await UsageAPI.refresh(refreshToken: $0)
        }
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/pitstop", isDirectory: true)
    static let file = directory.appendingPathComponent("profiles.json")

    /// The row-level error for a profile the identity audit gated: its saved
    /// credentials belonged to a different account and were deleted.
    struct ForeignCredentialsError: LocalizedError {
        let owner: ClaudeAccountIdentity
        let expected: ClaudeAccountIdentity
        var errorDescription: String? {
            if owner.email.caseInsensitiveCompare(expected.email) == .orderedSame {
                return "Was showing another Claude organization's usage — sign in again"
            }
            return "Was showing \(owner.email)'s usage — sign in again"
        }
    }

    /// What the once-per-launch identity audit found for a profile.
    enum AuditOutcome: Equatable {
        case verified
        /// The stored credentials belong to `owner`, not the profile's email;
        /// the poisoned copy has been deleted.
        case poisoned(owner: ClaudeAccountIdentity)
        /// Couldn't reach the identity endpoint — audit again next cycle.
        case unverifiable
    }

    private(set) var profiles: [Profile] = []
    private let deps: Deps
    /// Account keys whose stored credentials passed this launch's identity audit.
    private var auditedKeys: Set<String> = []

    init(deps: Deps = Deps()) {
        self.deps = deps
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: deps.file),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var list = root["profiles"] as? [[String: Any]] else {
            profiles = []
            return
        }

        // Make the implicit pre-org-aware email slot explicit immediately.
        // Future captures can then add a same-email organization without ever
        // reinterpreting which keychain item owns this retained snapshot.
        var migratedCredentialSlots = false
        for index in list.indices {
            guard let email = list[index]["email"] as? String,
                  (list[index]["credentialAccount"] as? String)?.isEmpty != false else { continue }
            list[index]["credentialAccount"] = email
            migratedCredentialSlots = true
        }
        profiles = list.compactMap(Profile.init(dict:)).sorted {
            ($0.email, $0.key) < ($1.email, $1.key)
        }
        if migratedCredentialSlots {
            root["profiles"] = list
            if let migrated = try? JSONSerialization.data(withJSONObject: root,
                                                           options: [.prettyPrinted, .sortedKeys]) {
                try? migrated.write(to: deps.file, options: .atomic)
            }
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: deps.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let root: [String: Any] = ["profiles": profiles.map(\.asDict)]
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: deps.file, options: .atomic)
    }

    /// Snapshot the live Claude Code credentials + identity into a profile.
    /// Called on every refresh so the saved copy of the active account always
    /// holds the newest tokens. `profile` is nil when nobody is logged in;
    /// `changed` reports whether credentials or their exact identity verification
    /// were stored (so the caller can notice an external re-login or migration).
    @discardableResult
    func captureCurrent() async throws -> (profile: Profile?, changed: Bool) {
        guard let blob = try await deps.readLive() else { return (nil, false) }
        guard let account = deps.oauthAccount(),
              let identity = ClaudeAccountIdentity(oauthAccount: account) else { return (nil, false) }
        let email = (account["emailAddress"] as? String) ?? identity.email

        // Exact organization match first. A single pre-organization legacy
        // row may be upgraded in place after its live token is verified.
        let existingIndex = profiles.firstIndex { $0.identity == identity }
            ?? profiles.firstIndex {
                $0.identity == nil
                    && $0.email.caseInsensitiveCompare(identity.email) == .orderedSame
            }

        // Called on every refresh — skip the keychain/file writes when
        // nothing changed since the last capture.
        if let existingIndex,
           profiles[existingIndex].identityVerified,
           let storedBlob = try? await deps.readProfileBlob(profiles[existingIndex].credentialAccount),
           storedBlob == blob,
           (profiles[existingIndex].oauthAccount as NSDictionary) == (account as NSDictionary) {
            return (profiles[existingIndex], false)
        }

        // The blob (keychain) and identity (~/.claude.json) are separate
        // stores that Claude Code writes at different moments — reading them
        // mid-switch pairs one account's tokens with another's email, and
        // filing that pair makes both rows report the same usage forever.
        // Confirm the token's owner before filing; this runs only when the
        // credentials changed or a legacy pairing still needs its one-time
        // organization check, so it is not a per-cycle HTTP call.
        var blobToStore = blob
        var creds = try CredentialBlob.parse(blob)
        if creds.isExpired {
            // Can't verify an expired token (e.g. first launch after days
            // away). Refresh it, and write the rotation back to the live item
            // so Claude Code's session survives it.
            guard let refreshToken = creds.refreshToken else {
                throw CaptureError.unverifiable("credentials are expired")
            }
            let fresh: (accessToken: String, refreshToken: String?, expiresAtMs: Double)
            do {
                fresh = try await deps.refreshToken(refreshToken)
            } catch {
                throw CaptureError.unverifiable(error.localizedDescription)
            }
            blobToStore = try CredentialBlob.patching(blob,
                                                      accessToken: fresh.accessToken,
                                                      refreshToken: fresh.refreshToken,
                                                      expiresAtMs: fresh.expiresAtMs)
            try await deps.writeLive(blobToStore)
            creds = try CredentialBlob.parse(blobToStore)
        }
        let owner: ClaudeAccountIdentity
        do {
            owner = try await deps.verifyIdentity(creds.accessToken)
        } catch {
            throw CaptureError.unverifiable(error.localizedDescription)
        }
        guard owner == identity else {
            throw CaptureError.mismatch(tokenOwner: owner, configIdentity: identity)
        }

        let credentialAccount = existingIndex.map { profiles[$0].credentialAccount } ?? identity.key
        try await deps.writeProfileBlob(credentialAccount, blobToStore)
        let profile = Profile(email: email, savedAt: Date(),
                              subscriptionType: creds.subscriptionType,
                              rateLimitTier: creds.rateLimitTier,
                              credentialAccount: credentialAccount,
                              identityVerified: true,
                              oauthAccount: account)
        if let existingIndex { profiles.remove(at: existingIndex) }
        profiles.append(profile)
        profiles.sort { ($0.email, $0.key) < ($1.email, $1.key) }
        try save()
        return (profile, true)
    }

    /// Make `key` the live Claude Code account: snapshot whatever is
    /// currently live, then write the profile's blob into the live keychain
    /// item and its identity into ~/.claude.json.
    func switchTo(key: String) async throws {
        // A failed snapshot aborts the switch: overwriting the live item
        // without a fresh copy of the outgoing account could lose its only
        // valid refresh token. (A nil return — nobody logged in — is fine.)
        _ = try await captureCurrent()
        guard let profile = profiles.first(where: { $0.key == key }) else {
            throw StoreError(message: "No saved Claude profile for \(key)")
        }
        guard let blob = try await deps.readProfileBlob(profile.credentialAccount) else {
            throw StoreError(message: "No saved credentials for \(profile.email) — log in once with `claude` and save again")
        }
        let previousLive = try await deps.readLive()
        try await deps.writeLive(blob)
        do {
            try deps.setOauthAccount(profile.oauthAccount)
        } catch {
            // Roll the live item back so the keychain and ~/.claude.json can't
            // disagree — captureCurrent refuses a mismatched pair, so leaving
            // one behind would block every capture until a manual re-login.
            if let previousLive {
                try? await deps.writeLive(previousLive)
            }
            throw error
        }
    }

    func remove(key: String) async throws {
        guard let profile = profiles.first(where: { $0.key == key }) else { return }
        try await deps.deleteProfileBlob(profile.credentialAccount)
        profiles.removeAll { $0.key == key }
        try save()
    }

    /// Integrity check for a profile whose credentials are about to be used:
    /// confirm the token's owner is the profile's email. Installs poisoned
    /// before capture-time verification existed hold another account's tokens
    /// under this email — both rows then report the same usage. Each email is
    /// checked once per launch (a passing audit is cached; failures are not).
    func auditIdentity(profile: Profile, accessToken: String) async -> AuditOutcome {
        guard !auditedKeys.contains(profile.key) else { return .verified }
        guard let expected = profile.identity else { return .unverifiable }
        let owner: ClaudeAccountIdentity
        do {
            owner = try await deps.verifyIdentity(accessToken)
        } catch {
            return .unverifiable
        }
        guard owner == expected else {
            // Drop the foreign copy — the rightful owner's tokens live under
            // their own profile (or the live item), so nothing real is lost,
            // and the row stops reporting another account's usage. The email
            // is deliberately not marked audited: post-re-login credentials
            // get checked afresh.
            try? await deps.deleteProfileBlob(profile.credentialAccount)
            return .poisoned(owner: owner)
        }
        auditedKeys.insert(profile.key)
        return .verified
    }

    /// The credential blob to use for a profile — the live item for the
    /// active account (Claude Code keeps that one fresh), the saved copy
    /// otherwise.
    func blob(for profile: Profile, isActive: Bool) async throws -> Data? {
        if isActive, let live = try await deps.readLive() {
            return live
        }
        return try await deps.readProfileBlob(profile.credentialAccount)
    }

    /// Persist a blob whose tokens we refreshed ourselves.
    func storeRefreshedBlob(_ data: Data, profile: Profile, isActive: Bool) async throws {
        try await deps.writeProfileBlob(profile.credentialAccount, data)
        if isActive {
            try await deps.writeLive(data)
        }
    }

    func profile(forKey key: String) -> Profile? {
        profiles.first { $0.key == key }
    }
}

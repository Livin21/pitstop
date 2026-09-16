import Foundation

/// Persists the transient display state across launches so a relaunch whose
/// first fetch hits a rate limit degrades to stale bars (the existing
/// "showing HH:MM data" treatment) instead of a blank panel, and honors any
/// still-running backoff instead of re-hammering the endpoint.
enum UsageCache {
    static let file = ProfileStore.directory.appendingPathComponent("usage-cache.json")

    /// Usage entries older than this are dropped on load — bars that stale
    /// mislead more than they inform, and the time-only "showing HH:MM data"
    /// stamp stops making sense across days.
    static let maxAge: TimeInterval = 24 * 3600
    /// Restored backoffs are clamped to the live maximum (recordFetchError's
    /// cap) so a corrupt future date can't freeze an account's fetches
    /// across every subsequent launch.
    static let maxBackoff: TimeInterval = 900

    /// The dictionaries AppDelegate keeps per account key, verbatim.
    struct Snapshot: Codable, Equatable {
        var usage: [String: UsageReport] = [:]
        var codexUsage: [String: Codex.Usage] = [:]
        var geminiUsage: [String: Gemini.Usage] = [:]
        var openCodeUsage: [String: OpenCode.Usage] = [:]
        var fetchError: [String: String] = [:]
        var failureCount: [String: Int] = [:]
        var nextFetchAllowed: [String: Date] = [:]
        var needsAction: Set<String> = []
        var desktopAccount: ClaudeDesktop.Account?

        /// Move pre-org-aware bare-email Claude state only when that email has
        /// one unambiguous organization. Ambiguous legacy state is left behind
        /// and pruned after the first fresh cycle rather than copied to both.
        func migratingLegacyClaudeKeys(profiles: [Profile]) -> Snapshot {
            var copy = self
            var candidates: [String: Set<String>] = [:]
            for profile in profiles {
                candidates[profile.email.lowercased(), default: []].insert(profile.key)
            }
            if let desktopAccount {
                candidates[desktopAccount.email.lowercased(), default: []].insert(desktopAccount.key)
            }
            for (email, keys) in candidates where keys.count == 1 {
                guard let key = keys.first, email != key else { continue }
                func move<T>(_ dict: inout [String: T]) {
                    if dict[key] == nil, let value = dict.removeValue(forKey: email) {
                        dict[key] = value
                    }
                }
                move(&copy.usage)
                move(&copy.fetchError)
                move(&copy.failureCount)
                move(&copy.nextFetchAllowed)
                if copy.needsAction.remove(email) != nil { copy.needsAction.insert(key) }
            }
            return copy
        }
    }

    static func save(_ snapshot: Snapshot, to url: URL = file) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try AtomicFile.write(JSONEncoder().encode(snapshot), to: url)
    }

    /// nil when the file is missing or unreadable — the caller starts empty,
    /// exactly like a pre-cache launch. Errors and needs-action gates are
    /// kept regardless of age (an expired session stays expired); only the
    /// usage bars age out.
    static func load(from url: URL = file, now: Date = Date()) -> Snapshot? {
        guard let data = try? Data(contentsOf: url),
              var snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        snap.usage = snap.usage.filter { now.timeIntervalSince($0.value.fetchedAt) < maxAge }
        snap.codexUsage = snap.codexUsage.filter { now.timeIntervalSince($0.value.fetchedAt) < maxAge }
        snap.geminiUsage = snap.geminiUsage.filter { now.timeIntervalSince($0.value.fetchedAt) < maxAge }
        snap.openCodeUsage = snap.openCodeUsage.filter { now.timeIntervalSince($0.value.fetchedAt) < maxAge }
        snap.nextFetchAllowed = snap.nextFetchAllowed.mapValues {
            min($0, now.addingTimeInterval(maxBackoff))
        }
        return snap
    }
}

extension UsageCache.Snapshot {
    /// Everything but `openCodeUsage` decodes strictly, exactly as synthesized
    /// `Codable` did: a snapshot missing one of those keys is damaged, and
    /// `load` returning nil for it (a clean start) beats half-restoring
    /// backoff gates with no usage or error to explain them.
    ///
    /// `openCodeUsage` is the one exception — caches written before OpenCode
    /// support existed have no such key and are otherwise perfectly good.
    /// Declaring only `init(from:)`, and doing it in an extension, keeps the
    /// memberwise initializer and the synthesized `encode(to:)`, so a future
    /// field can't be silently left out of what gets written.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usage = try container.decode([String: UsageReport].self, forKey: .usage)
        codexUsage = try container.decode([String: Codex.Usage].self, forKey: .codexUsage)
        geminiUsage = try container.decode([String: Gemini.Usage].self, forKey: .geminiUsage)
        openCodeUsage = try container.decodeIfPresent([String: OpenCode.Usage].self,
                                                      forKey: .openCodeUsage) ?? [:]
        fetchError = try container.decode([String: String].self, forKey: .fetchError)
        failureCount = try container.decode([String: Int].self, forKey: .failureCount)
        nextFetchAllowed = try container.decode([String: Date].self, forKey: .nextFetchAllowed)
        needsAction = try container.decode(Set<String>.self, forKey: .needsAction)
        desktopAccount = try container.decodeIfPresent(ClaudeDesktop.Account.self,
                                                       forKey: .desktopAccount)
    }
}

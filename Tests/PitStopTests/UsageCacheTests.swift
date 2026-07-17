import XCTest
@testable import PitStop

/// UsageCache persists the transient display state (usage reports, fetch
/// errors, backoffs) across launches so a relaunch that immediately hits a
/// rate limit degrades to stale bars instead of a blank panel.
final class UsageCacheTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-cache-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func sampleSnapshot(now: Date) -> UsageCache.Snapshot {
        var report = UsageReport()
        report.fiveHour = UsageWindow(utilization: 42, resetsAt: now.addingTimeInterval(3600))
        report.sevenDay = UsageWindow(utilization: 7, resetsAt: nil)
        report.scoped = [ScopedWindow(label: "Fable",
                                      window: UsageWindow(utilization: 13, resetsAt: nil))]
        report.extraUsageEnabled = true
        report.extraUsageUtilization = 3
        report.fetchedAt = now
        return UsageCache.Snapshot(
            usage: ["a@x.com": report],
            codexUsage: ["codex:b@x.com": Codex.Usage(
                windows: [.init(label: "5h", usedPercent: 91, resetsAt: now)], fetchedAt: now)],
            geminiUsage: ["gemini:c@x.com": Gemini.Usage(
                windows: [.init(label: "2.5 Pro", usedPercent: 8, resetsAt: nil)], fetchedAt: now)],
            fetchError: ["a@x.com": "Rate limited"],
            failureCount: ["a@x.com": 2],
            nextFetchAllowed: ["a@x.com": now.addingTimeInterval(240)],
            needsAction: ["codex:b@x.com"],
            desktopAccount: ClaudeDesktop.Account(email: "a@x.com", orgUUID: "org",
                                                  planLabel: "Max"))
    }

    func testRoundTripRestoresEverything() throws {
        let now = Date()
        let snap = sampleSnapshot(now: now)
        try UsageCache.save(snap, to: url)
        let loaded = try XCTUnwrap(UsageCache.load(from: url, now: now))
        XCTAssertEqual(loaded, snap)
    }

    func testDropsUsageOlderThanADay() throws {
        let now = Date()
        var snap = sampleSnapshot(now: now)
        var old = UsageReport()
        old.fetchedAt = now.addingTimeInterval(-25 * 3600)
        snap.usage["old@x.com"] = old
        snap.codexUsage["codex:old@x.com"] = Codex.Usage(
            windows: [], fetchedAt: now.addingTimeInterval(-25 * 3600))
        snap.geminiUsage["gemini:old@x.com"] = Gemini.Usage(
            windows: [], fetchedAt: now.addingTimeInterval(-25 * 3600))
        try UsageCache.save(snap, to: url)
        let loaded = try XCTUnwrap(UsageCache.load(from: url, now: now))
        XCTAssertNil(loaded.usage["old@x.com"])
        XCTAssertNil(loaded.codexUsage["codex:old@x.com"])
        XCTAssertNil(loaded.geminiUsage["gemini:old@x.com"])
        XCTAssertNotNil(loaded.usage["a@x.com"])            // fresh entries survive
        XCTAssertNotNil(loaded.codexUsage["codex:b@x.com"])
    }

    func testClampsRestoredBackoffToMax() throws {
        let now = Date()
        var snap = sampleSnapshot(now: now)
        snap.nextFetchAllowed["far@x.com"] = now.addingTimeInterval(7200)
        try UsageCache.save(snap, to: url)
        let loaded = try XCTUnwrap(UsageCache.load(from: url, now: now))
        let clamped = try XCTUnwrap(loaded.nextFetchAllowed["far@x.com"])
        XCTAssertLessThanOrEqual(clamped.timeIntervalSince(now), 900 + 1)
        // In-range backoffs pass through untouched.
        XCTAssertEqual(loaded.nextFetchAllowed["a@x.com"],
                       snap.nextFetchAllowed["a@x.com"])
    }

    func testMissingOrCorruptFileLoadsNil() throws {
        XCTAssertNil(UsageCache.load(from: url, now: Date()))
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(UsageCache.load(from: url, now: Date()))
    }

    func testMigratesBareEmailStateForOneClaudeOrganization() throws {
        let now = Date()
        var snap = sampleSnapshot(now: now)
        snap.desktopAccount = ClaudeDesktop.Account(email: "a@x.com", orgUUID: "org-a",
                                                    planLabel: "Team")
        let oauth: [String: Any] = ["emailAddress": "a@x.com", "organizationUuid": "org-a"]
        let id = ClaudeAccountIdentity(email: "a@x.com", organizationUUID: "org-a")
        let p = Profile(email: "a@x.com", savedAt: now, subscriptionType: "team",
                        rateLimitTier: nil, credentialAccount: "a@x.com", oauthAccount: oauth)

        let migrated = snap.migratingLegacyClaudeKeys(profiles: [p])

        XCTAssertNil(migrated.usage["a@x.com"])
        XCTAssertNotNil(migrated.usage[id.key])
        XCTAssertEqual(migrated.fetchError[id.key], "Rate limited")
        XCTAssertEqual(migrated.failureCount[id.key], 2)
        XCTAssertNotNil(migrated.nextFetchAllowed[id.key])
    }

    func testDoesNotCopyAmbiguousBareEmailStateToTwoOrganizations() throws {
        let now = Date()
        let snap = sampleSnapshot(now: now)
        func make(_ org: String) -> Profile {
            let oauth: [String: Any] = ["emailAddress": "a@x.com", "organizationUuid": org]
            return Profile(email: "a@x.com", savedAt: now, subscriptionType: nil,
                           rateLimitTier: nil, credentialAccount: org, oauthAccount: oauth)
        }

        let migrated = snap.migratingLegacyClaudeKeys(profiles: [make("org-a"), make("org-b")])

        XCTAssertNotNil(migrated.usage["a@x.com"])
        XCTAssertNil(migrated.usage[ClaudeAccountIdentity(email: "a@x.com",
                                                          organizationUUID: "org-a").key])
    }
}

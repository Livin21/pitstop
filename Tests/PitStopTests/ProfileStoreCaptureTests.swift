import XCTest
@testable import PitStop

/// In-memory stand-ins for the live keychain item, the profile keychain
/// items, ~/.claude.json, and the identity/refresh endpoints — so
/// captureCurrent's filing decisions can be tested without touching real
/// credentials.
private final class CaptureHarness {
    var live: Data?
    var account: [String: Any]?
    var savedBlobs: [String: Data] = [:]
    var deletedBlobs: [String] = []
    var liveWrites: [Data] = []
    var owners: [String: ClaudeAccountIdentity] = [:]
    var configuredAccounts: [[String: Any]] = []
    var verifyCalls = 0
    var verifyError: Error?
    var refreshed: (access: String, refresh: String?, expMs: Double)?
    var refreshCalls = 0
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("pitstop-capture-\(UUID().uuidString)/profiles.json")

    func makeStore() -> ProfileStore {
        ProfileStore(deps: .init(
            file: file,
            readLive: { [self] in live },
            readProfileBlob: { [self] in savedBlobs[$0] },
            writeProfileBlob: { [self] in savedBlobs[$0] = $1 },
            deleteProfileBlob: { [self] in deletedBlobs.append($0); savedBlobs[$0] = nil },
            writeLive: { [self] in liveWrites.append($0); live = $0 },
            oauthAccount: { [self] in account },
            setOauthAccount: { [self] account in configuredAccounts.append(account) },
            verifyIdentity: { [self] token in
                verifyCalls += 1
                if let verifyError { throw verifyError }
                guard let owner = owners[token] else { throw UsageAPI.APIError.unauthorized }
                return owner
            },
            refreshToken: { [self] _ in
                refreshCalls += 1
                guard let refreshed else { throw UsageAPI.APIError.unauthorized }
                return (refreshed.access, refreshed.refresh, refreshed.expMs)
            }))
    }
}

private func identity(_ email: String = "a@x.com", _ org: String = "org-a")
    -> ClaudeAccountIdentity {
    ClaudeAccountIdentity(email: email, organizationUUID: org)
}

private func account(_ email: String = "a@x.com", _ org: String = "org-a",
                     name: String? = nil) -> [String: Any] {
    var value: [String: Any] = ["emailAddress": email, "organizationUuid": org]
    if let name { value["organizationName"] = name }
    return value
}

private func profile(_ email: String = "a@x.com", _ org: String = "org-a",
                     credentialAccount: String? = nil) -> Profile {
    let oauth = account(email, org)
    let id = identity(email, org)
    return Profile(email: email, savedAt: Date(), subscriptionType: "team",
                   rateLimitTier: nil, credentialAccount: credentialAccount ?? id.key,
                   oauthAccount: oauth)
}

private func blob(access: String, refresh: String? = "rt",
                  expiresAt: Date = Date(timeIntervalSinceNow: 3600)) -> Data {
    var oauth: [String: Any] = [
        "accessToken": access,
        "expiresAt": expiresAt.timeIntervalSince1970 * 1000,
        "subscriptionType": "team",
    ]
    if let refresh { oauth["refreshToken"] = refresh }
    return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
}

final class ProfileStoreCaptureTests: XCTestCase {

    /// The reported bug: the live keychain item and ~/.claude.json disagree
    /// (mid-switch crossed pair), so filing would store B's tokens under A's
    /// email and both rows would report the same usage forever after.
    func testCaptureRejectsBlobBelongingToAnotherAccount() async throws {
        let h = CaptureHarness()
        h.live = blob(access: "at-b")
        h.account = account("a@x.com", "org-a")
        h.owners["at-b"] = identity("b@x.com", "org-b")
        let store = h.makeStore()

        do {
            _ = try await store.captureCurrent()
            XCTFail("crossed capture should throw")
        } catch let e as ProfileStore.CaptureError {
            guard case .mismatch(let owner, let expected) = e else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(owner, identity("b@x.com", "org-b"))
            XCTAssertEqual(expected, identity("a@x.com", "org-a"))
        }
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(h.savedBlobs[identity().key])
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.file.path))
    }

    /// The mismatch is the one capture failure the user has to act on, and it
    /// also blocks switching (switchTo snapshots first). The message has to
    /// name both accounts and the way out, on one line — it surfaces in an
    /// NSAlert and in `--check`'s "capture failed:" line.
    func testMismatchMessageNamesBothAccountsAndTheFix() {
        let text = ProfileStore.CaptureError
            .mismatch(tokenOwner: identity("b@x.com", "org-b"),
                      configIdentity: identity("a@x.com", "org-a"))
            .localizedDescription
        XCTAssertTrue(text.contains("b@x.com"), text)
        XCTAssertTrue(text.contains("a@x.com"), text)
        XCTAssertTrue(text.contains("/login"), text)
        XCTAssertFalse(text.contains("\n"), "must stay one line: \(text)")
    }

    func testCaptureFilesVerifiedBlob() async throws {
        let h = CaptureHarness()
        h.live = blob(access: "at-a")
        h.account = account("a@x.com", "org-a", name: "Acme")
        h.owners["at-a"] = identity("A@X.com", "ORG-A")
        let store = h.makeStore()

        let (profile, changed) = try await store.captureCurrent()

        XCTAssertEqual(profile?.email, "a@x.com")
        XCTAssertTrue(changed)
        XCTAssertEqual(h.savedBlobs[identity().key], h.live)
        XCTAssertEqual(store.profiles.count, 1)
    }

    func testCaptureKeepsTwoOrganizationsWithSameEmailSeparate() async throws {
        let h = CaptureHarness()
        let teamBlob = blob(access: "at-team")
        h.live = teamBlob
        h.account = account("same@x.com", "org-team", name: "Team")
        h.owners["at-team"] = identity("same@x.com", "org-team")
        let store = h.makeStore()
        let teamCapture = try await store.captureCurrent()
        let team = try XCTUnwrap(teamCapture.profile)

        let personalBlob = blob(access: "at-personal")
        h.live = personalBlob
        h.account = account("same@x.com", "org-personal")
        h.owners["at-personal"] = identity("same@x.com", "org-personal")
        let personalCapture = try await store.captureCurrent()
        let personal = try XCTUnwrap(personalCapture.profile)

        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertNotEqual(team.key, personal.key)
        XCTAssertEqual(h.savedBlobs[team.credentialAccount], teamBlob)
        XCTAssertEqual(h.savedBlobs[personal.credentialAccount], personalBlob)
    }

    func testCaptureRejectsSameEmailFromWrongOrganization() async throws {
        let h = CaptureHarness()
        h.live = blob(access: "at-personal")
        h.account = account("same@x.com", "org-team")
        h.owners["at-personal"] = identity("same@x.com", "org-personal")

        do {
            _ = try await h.makeStore().captureCurrent()
            XCTFail("same-email wrong-org capture should throw")
        } catch let error as ProfileStore.CaptureError {
            guard case .mismatch(let owner, let expected) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(owner.organizationUUID, "org-personal")
            XCTAssertEqual(expected.organizationUUID, "org-team")
        }
        XCTAssertTrue(h.savedBlobs.isEmpty)
    }

    func testLegacyEmailCredentialSurvivesAddingSecondOrganization() async throws {
        let h = CaptureHarness()
        try FileManager.default.createDirectory(at: h.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let legacy: [String: Any] = ["profiles": [[
            "email": "same@x.com",
            "savedAt": Date().timeIntervalSince1970,
            "oauthAccount": account("same@x.com", "org-team", name: "Team"),
            "subscriptionType": "team",
        ]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: h.file)
        let teamBlob = blob(access: "at-team")
        h.savedBlobs["same@x.com"] = teamBlob

        let personalBlob = blob(access: "at-personal")
        h.live = personalBlob
        h.account = account("same@x.com", "org-personal")
        h.owners["at-personal"] = identity("same@x.com", "org-personal")
        let store = h.makeStore()

        let migratedData = try Data(contentsOf: h.file)
        let migratedRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: migratedData) as? [String: Any])
        let migratedProfiles = try XCTUnwrap(migratedRoot["profiles"] as? [[String: Any]])
        XCTAssertEqual(migratedProfiles.first?["credentialAccount"] as? String, "same@x.com")

        _ = try await store.captureCurrent()

        XCTAssertEqual(store.profiles.count, 2)
        let team = try XCTUnwrap(store.profiles.first { $0.identity == identity("same@x.com", "org-team") })
        let personal = try XCTUnwrap(store.profiles.first { $0.identity == identity("same@x.com", "org-personal") })
        XCTAssertEqual(team.credentialAccount, "same@x.com")
        XCTAssertEqual(h.savedBlobs[team.credentialAccount], teamBlob)
        XCTAssertEqual(h.savedBlobs[personal.credentialAccount], personalBlob)
    }

    func testLegacyUnchangedCaptureStillVerifiesOrganization() async throws {
        let h = CaptureHarness()
        try FileManager.default.createDirectory(at: h.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let legacy: [String: Any] = ["profiles": [[
            "email": "same@x.com",
            "savedAt": Date().timeIntervalSince1970,
            "oauthAccount": account("same@x.com", "org-team", name: "Team"),
            "subscriptionType": "team",
        ]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: h.file)

        // The old email-only verifier could file another organization's token
        // under this metadata. Matching bytes must not bypass the first exact
        // organization check after upgrade.
        let crossedBlob = blob(access: "at-personal")
        h.live = crossedBlob
        h.savedBlobs["same@x.com"] = crossedBlob
        h.account = account("same@x.com", "org-team", name: "Team")
        h.owners["at-personal"] = identity("same@x.com", "org-personal")
        let store = h.makeStore()

        do {
            _ = try await store.captureCurrent()
            XCTFail("legacy same-email crossed capture should be reverified")
        } catch let error as ProfileStore.CaptureError {
            guard case .mismatch(let owner, let expected) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(owner, identity("same@x.com", "org-personal"))
            XCTAssertEqual(expected, identity("same@x.com", "org-team"))
        }
        XCTAssertEqual(h.verifyCalls, 1)
    }

    func testLegacyValidCapturePersistsExactVerification() async throws {
        let h = CaptureHarness()
        try FileManager.default.createDirectory(at: h.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let legacy: [String: Any] = ["profiles": [[
            "email": "same@x.com",
            "savedAt": Date().timeIntervalSince1970,
            "oauthAccount": account("same@x.com", "org-team", name: "Team"),
            "subscriptionType": "team",
        ]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: h.file)
        let validBlob = blob(access: "at-team")
        h.live = validBlob
        h.savedBlobs["same@x.com"] = validBlob
        h.account = account("same@x.com", "org-team", name: "Team")
        h.owners["at-team"] = identity("same@x.com", "org-team")

        let first = try await h.makeStore().captureCurrent()
        XCTAssertTrue(first.changed)
        XCTAssertEqual(h.verifyCalls, 1)

        // The successful exact check is durable, so the next launch can take
        // the unchanged fast path without another profile request.
        let second = try await h.makeStore().captureCurrent()
        XCTAssertFalse(second.changed)
        XCTAssertEqual(h.verifyCalls, 1)
    }

    func testSwitchTargetsExactSameEmailOrganization() async throws {
        let h = CaptureHarness()
        h.live = blob(access: "at-team")
        h.account = account("same@x.com", "org-team", name: "Team")
        h.owners["at-team"] = identity("same@x.com", "org-team")
        let store = h.makeStore()
        let teamCapture = try await store.captureCurrent()
        let team = try XCTUnwrap(teamCapture.profile)

        h.live = blob(access: "at-personal")
        h.account = account("same@x.com", "org-personal")
        h.owners["at-personal"] = identity("same@x.com", "org-personal")
        _ = try await store.captureCurrent()

        try await store.switchTo(key: team.key)

        XCTAssertEqual(try CredentialBlob.parse(try XCTUnwrap(h.live)).accessToken, "at-team")
        XCTAssertEqual(h.configuredAccounts.last?["organizationUuid"] as? String, "org-team")
    }

    /// captureCurrent runs every refresh cycle — the identity check must only
    /// fire when the credentials actually changed, not add an HTTP call per tick.
    func testCaptureSkipsVerificationWhenNothingChanged() async throws {
        let h = CaptureHarness()
        h.live = blob(access: "at-a")
        h.account = account()
        h.owners["at-a"] = identity()
        _ = try await h.makeStore().captureCurrent()
        XCTAssertEqual(h.verifyCalls, 1)

        // Fresh instance reloads profiles.json; same blob + identity → dedup hit.
        let store = h.makeStore()
        let (profile, changed) = try await store.captureCurrent()

        XCTAssertEqual(profile?.email, "a@x.com")
        XCTAssertFalse(changed)
        XCTAssertEqual(h.verifyCalls, 1)
    }

    /// A changed-but-expired blob (e.g. first launch after days away) can't be
    /// verified as-is: refresh it, verify the fresh token, file the patched
    /// blob, and write the rotation back to the live item so Claude Code's
    /// session stays valid.
    func testCaptureRefreshesExpiredBlobBeforeVerifying() async throws {
        let h = CaptureHarness()
        h.live = blob(access: "at-old", refresh: "rt-old",
                      expiresAt: Date(timeIntervalSinceNow: -60))
        h.account = account()
        h.refreshed = ("at-new", "rt-new",
                       Date(timeIntervalSinceNow: 3600).timeIntervalSince1970 * 1000)
        h.owners["at-new"] = identity()
        let store = h.makeStore()

        let (profile, changed) = try await store.captureCurrent()

        XCTAssertEqual(profile?.email, "a@x.com")
        XCTAssertTrue(changed)
        XCTAssertEqual(h.refreshCalls, 1)
        let filed = try CredentialBlob.parse(try XCTUnwrap(h.savedBlobs[identity().key]))
        XCTAssertEqual(filed.accessToken, "at-new")
        XCTAssertEqual(filed.refreshToken, "rt-new")
        XCTAssertEqual(h.liveWrites.count, 1)
    }

    func testCaptureFilesNothingWhenVerificationFails() async throws {
        let h = CaptureHarness()
        h.live = blob(access: "at-a")
        h.account = account()
        h.verifyError = URLError(.notConnectedToInternet)
        let store = h.makeStore()

        do {
            _ = try await store.captureCurrent()
            XCTFail("unverifiable capture should throw")
        } catch let e as ProfileStore.CaptureError {
            guard case .unverifiable = e else { return XCTFail("wrong error: \(e)") }
        }
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(h.savedBlobs.isEmpty)
    }
}

/// Claude Desktop ships its own Claude Code, which writes the same
/// `Claude Code-credentials` keychain item the CLI uses. So the live item can
/// stop belonging to the account `~/.claude.json` still names as active, and
/// PitStop must not treat it as that account's — reporting the wrong usage is
/// the mild outcome; overwriting the saved snapshot with the other account's
/// tokens (which the audit then deletes) loses the credentials outright.
final class ProfileStoreLiveOwnershipTests: XCTestCase {

    /// The steady state: the live item is byte-identical to the snapshot filed
    /// under this email, which settles ownership without an HTTP call.
    func testUnchangedLiveItemIsUsedWithoutVerifying() async throws {
        let h = CaptureHarness()
        let p = profile(credentialAccount: "a@x.com")
        h.live = blob(access: "at-a")
        h.savedBlobs[p.credentialAccount] = h.live
        let store = h.makeStore()

        let stored = try await store.blob(for: p, isActive: true)

        XCTAssertEqual(stored?.data, h.live)
        XCTAssertEqual(stored?.source, .live)
        XCTAssertEqual(h.verifyCalls, 0)
    }

    /// The reported bug: Desktop's embedded Claude Code replaced the live item
    /// while ~/.claude.json still named the old account.
    func testForeignLiveItemFallsBackToSavedSnapshot() async throws {
        let h = CaptureHarness()
        let p = profile(credentialAccount: "a@x.com")
        h.live = blob(access: "at-b")               // Desktop's account
        h.savedBlobs[p.credentialAccount] = blob(access: "at-a")
        h.owners["at-b"] = identity("b@x.com", "org-b")
        let store = h.makeStore()

        let stored = try await store.blob(for: p, isActive: true)

        XCTAssertEqual(stored?.source, .saved)
        XCTAssertEqual(stored?.data, h.savedBlobs[p.credentialAccount])
        XCTAssertEqual(h.verifyCalls, 1)
    }

    /// The data loss itself: refreshing that fallback must stay in the
    /// snapshot and never be written back over the live item.
    func testRefreshOfFallbackNeverTouchesLiveItem() async throws {
        let h = CaptureHarness()
        let p = profile(credentialAccount: "a@x.com")
        let desktopBlob = blob(access: "at-b")
        h.live = desktopBlob
        h.savedBlobs[p.credentialAccount] = blob(access: "at-a")
        h.owners["at-b"] = identity("b@x.com", "org-b")
        let store = h.makeStore()

        let fetched = try await store.blob(for: p, isActive: true)
        let stored = try XCTUnwrap(fetched)
        let rotated = blob(access: "at-a2")
        try await store.storeRefreshedBlob(rotated, profile: p, source: stored.source)

        XCTAssertEqual(h.savedBlobs[p.credentialAccount], rotated)
        XCTAssertTrue(h.liveWrites.isEmpty)
        XCTAssertEqual(h.live, desktopBlob)   // still Desktop's, untouched
    }

    /// A live item this account does own — e.g. a `claude /login` that landed
    /// after the last capture — is verified once and then cached by its bytes.
    func testNewLiveItemIsVerifiedOnceThenCached() async throws {
        let h = CaptureHarness()
        let p = profile(credentialAccount: "a@x.com")
        h.live = blob(access: "at-a2")
        h.savedBlobs[p.credentialAccount] = blob(access: "at-a")
        h.owners["at-a2"] = identity("A@X.com", "ORG-A")
        let store = h.makeStore()

        for _ in 0..<3 {
            let stored = try await store.blob(for: p, isActive: true)
            XCTAssertEqual(stored?.source, .live)
        }
        XCTAssertEqual(h.verifyCalls, 1)
    }

    /// A disagreement is cached too — otherwise every refresh pays for the
    /// same answer for as long as the mismatch lasts.
    func testForeignLiveItemIsVerifiedOnlyOnce() async throws {
        let h = CaptureHarness()
        let p = profile(credentialAccount: "a@x.com")
        h.live = blob(access: "at-b")
        h.savedBlobs[p.credentialAccount] = blob(access: "at-a")
        h.owners["at-b"] = identity("b@x.com", "org-b")
        let store = h.makeStore()

        for _ in 0..<3 {
            let stored = try await store.blob(for: p, isActive: true)
            XCTAssertEqual(stored?.source, .saved)
        }
        XCTAssertEqual(h.verifyCalls, 1)
    }

    /// captureCurrent asks the same question about the same bytes moments
    /// earlier; its answer should carry over rather than be paid for twice.
    func testCaptureVerificationPrimesTheCache() async throws {
        let h = CaptureHarness()
        h.live = blob(access: "at-a")
        h.account = account()
        h.owners["at-a"] = identity()
        let store = h.makeStore()

        let captured = try await store.captureCurrent()
        let p = try XCTUnwrap(captured.profile)
        XCTAssertEqual(h.verifyCalls, 1)
        // captureCurrent filed the blob, so the byte-equality path settles this
        // one anyway; drop the snapshot to force the cache to answer.
        h.savedBlobs[p.credentialAccount] = nil

        let stored = try await store.blob(for: p, isActive: true)
        XCTAssertEqual(stored?.source, .live)
        XCTAssertEqual(h.verifyCalls, 1)
    }

    /// Offline, or a live token too expired to identify: prefer the snapshot.
    /// captureCurrent refreshes and re-verifies the live item next cycle.
    func testUnverifiableLiveItemFallsBackToSavedSnapshot() async throws {
        let h = CaptureHarness()
        let p = profile(credentialAccount: "a@x.com")
        h.live = blob(access: "at-?")
        h.savedBlobs[p.credentialAccount] = blob(access: "at-a")
        h.verifyError = URLError(.notConnectedToInternet)
        let store = h.makeStore()

        let offline = try await store.blob(for: p, isActive: true)
        XCTAssertEqual(offline?.source, .saved)

        // An expired live token can't be identified at all, so it doesn't even
        // reach the identity endpoint.
        h.verifyError = nil
        h.live = blob(access: "at-old", expiresAt: Date(timeIntervalSinceNow: -60))
        h.owners["at-old"] = identity()
        let store2 = h.makeStore()
        let callsBefore = h.verifyCalls
        let expired = try await store2.blob(for: p, isActive: true)
        XCTAssertEqual(expired?.source, .saved)
        XCTAssertEqual(h.verifyCalls, callsBefore)
    }

    func testInactiveAccountAlwaysUsesItsSnapshot() async throws {
        let h = CaptureHarness()
        let p = profile(credentialAccount: "a@x.com")
        h.live = blob(access: "at-b")
        h.savedBlobs[p.credentialAccount] = blob(access: "at-a")
        let store = h.makeStore()

        let stored = try await store.blob(for: p, isActive: false)

        XCTAssertEqual(stored?.source, .saved)
        XCTAssertEqual(stored?.data, h.savedBlobs[p.credentialAccount])
        XCTAssertEqual(h.verifyCalls, 0)
    }

    func testNoCredentialsAnywhereReturnsNil() async throws {
        let h = CaptureHarness()
        let p = profile(credentialAccount: "a@x.com")
        let store = h.makeStore()
        let stored = try await store.blob(for: p, isActive: true)
        XCTAssertNil(stored)
    }

    /// A live-sourced rotation goes to both stores — that's how Claude Code's
    /// own session survives PitStop refreshing its token.
    func testRefreshOfLiveSourceWritesBothStores() async throws {
        let h = CaptureHarness()
        let p = profile(credentialAccount: "a@x.com")
        h.live = blob(access: "at-a")
        h.savedBlobs[p.credentialAccount] = h.live
        let store = h.makeStore()

        let rotated = blob(access: "at-a2")
        try await store.storeRefreshedBlob(rotated, profile: p, source: .live)

        XCTAssertEqual(h.savedBlobs[p.credentialAccount], rotated)
        XCTAssertEqual(h.liveWrites, [rotated])
        XCTAssertEqual(h.live, rotated)
    }
}

/// The self-heal for installs poisoned before verification existed: once per
/// launch, each profile's token owner is checked against its email; a saved
/// blob that provably belongs to a different account is deleted so the row
/// can be gated for re-login instead of reporting the other account's usage.
final class ProfileStoreAuditTests: XCTestCase {

    func testAuditDeletesPoisonedBlobAndReportsOwner() async throws {
        let h = CaptureHarness()
        let p = profile()
        h.savedBlobs[p.credentialAccount] = blob(access: "at-b")
        h.owners["at-b"] = identity("b@x.com", "org-b")
        let store = h.makeStore()

        let outcome = await store.auditIdentity(profile: p, accessToken: "at-b")

        XCTAssertEqual(outcome, .poisoned(owner: identity("b@x.com", "org-b")))
        XCTAssertEqual(h.deletedBlobs, [p.credentialAccount])
        XCTAssertNil(h.savedBlobs[p.credentialAccount])
        // A poisoned row is never marked audited — after a re-login the new
        // credentials must be re-checked, not waved through.
        let again = await store.auditIdentity(profile: p, accessToken: "at-b")
        XCTAssertEqual(again, .poisoned(owner: identity("b@x.com", "org-b")))
    }

    func testAuditVerifiesOncePerLaunch() async throws {
        let h = CaptureHarness()
        let p = profile()
        h.owners["at-a"] = identity("A@x.com", "ORG-A")
        let store = h.makeStore()

        let first = await store.auditIdentity(profile: p, accessToken: "at-a")
        let second = await store.auditIdentity(profile: p, accessToken: "at-a")

        XCTAssertEqual(first, .verified)
        XCTAssertEqual(second, .verified)
        XCTAssertEqual(h.verifyCalls, 1)
        XCTAssertTrue(h.deletedBlobs.isEmpty)
    }

    func testAuditErrorIsUnverifiableAndRetriesNextTime() async throws {
        let h = CaptureHarness()
        h.verifyError = URLError(.timedOut)
        let store = h.makeStore()
        let p = profile()

        let outcome = await store.auditIdentity(profile: p, accessToken: "at-a")
        XCTAssertEqual(outcome, .unverifiable)
        XCTAssertTrue(h.deletedBlobs.isEmpty)

        h.verifyError = nil
        h.owners["at-a"] = identity()
        let retried = await store.auditIdentity(profile: p, accessToken: "at-a")
        XCTAssertEqual(retried, .verified)
        XCTAssertEqual(h.verifyCalls, 2)
    }
}

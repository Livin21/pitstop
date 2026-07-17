import XCTest
@testable import PitStop

/// Records what `persist` was called with; returns canned exchange/identity.
final class FakeAdapter: LoginAdapter, @unchecked Sendable {
    var provider: Provider { .claude }
    var loopbackPorts: [UInt16] { [51900] }
    var loopbackPath: String { "/callback" }
    var supportsPaste: Bool { false }
    var pasteRedirectURI: String { "" }
    var identityToReturn = LoginIdentity(email: "match@example.com", accountID: nil,
                                         organizationID: nil)
    var persistedTargets: [LoginTarget] = []

    func authorizeURL(challenge: String, state: String, redirectURI: String,
                      pasteMode: Bool, target: LoginTarget) -> URL {
        URL(string: "https://example.com/authorize")!
    }
    func exchange(code: String, state: String, verifier: String, redirectURI: String) async throws -> FreshTokens {
        FreshTokens(accessToken: "A", refreshToken: "R", idToken: nil, expiresAtMs: 1)
    }
    func identity(from tokens: FreshTokens) async throws -> LoginIdentity { identityToReturn }
    func buildBlob(old: Data, tokens: FreshTokens) throws -> Data { Data() }
    func persist(_ tokens: FreshTokens, target: LoginTarget) async throws {
        persistedTargets.append(target)
    }
}

final class OAuthLoginCoordinatorTests: XCTestCase {
    func testIdentityMatchNormalizesEmailAndChecksOrganization() {
        let target = LoginTarget(email: "User@Example.com ", organizationID: "ORG-A",
                                 credentialAccount: "slot")
        XCTAssertTrue(OAuthLoginCoordinator.identityMatches(
            target: target, LoginIdentity(email: "user@example.com", accountID: nil,
                                          organizationID: "org-a")))
        XCTAssertFalse(OAuthLoginCoordinator.identityMatches(
            target: target, LoginIdentity(email: "user@example.com", accountID: nil,
                                          organizationID: "org-b")))
        XCTAssertFalse(OAuthLoginCoordinator.identityMatches(
            target: target, LoginIdentity(email: "b@x.com", accountID: nil,
                                          organizationID: "org-a")))
    }

    func testFinishPersistsOnMatch() async throws {
        let a = FakeAdapter()
        let target = LoginTarget(email: "match@example.com", credentialAccount: "saved-slot")
        try await OAuthLoginCoordinator().finish(
            adapter: a, target: target,
            code: "C", state: "S", verifier: "V", redirectURI: "http://localhost:51900/callback")
        XCTAssertEqual(a.persistedTargets, [target])
    }

    func testFinishRejectsOnMismatch() async {
        let a = FakeAdapter()
        a.identityToReturn = LoginIdentity(email: "other@example.com", accountID: nil,
                                           organizationID: nil)
        do {
            try await OAuthLoginCoordinator().finish(
                adapter: a,
                target: LoginTarget(email: "match@example.com", credentialAccount: "slot"),
                code: "C", state: "S", verifier: "V", redirectURI: "x")
            XCTFail("expected mismatch")
        } catch {
            guard case LoginError.identityMismatch = error else {
                return XCTFail("expected .identityMismatch, got \(error)")
            }
            XCTAssertTrue(a.persistedTargets.isEmpty)   // nothing written
        }
    }
}

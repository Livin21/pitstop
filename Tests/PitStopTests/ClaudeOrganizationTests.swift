import XCTest
@testable import PitStop

@MainActor
final class ClaudeOrganizationTests: XCTestCase {
    func testSameEmailOrganizationsHaveDistinctKeys() {
        let team = ClaudeAccountIdentity(email: "Same@Example.com", organizationUUID: "ORG-TEAM")
        let personal = ClaudeAccountIdentity(email: "same@example.com", organizationUUID: "org-personal")

        XCTAssertNotEqual(team.key, personal.key)
        XCTAssertEqual(team.email, "same@example.com")
        XCTAssertEqual(team.organizationUUID, "org-team")
    }

    func testDesktopMergesOnlyWithExactOrganization() {
        let desktop = ClaudeDesktop.Account(email: "same@example.com", orgUUID: "org-team",
                                            planLabel: "Team")
        let team = ClaudeAccountIdentity(email: "same@example.com", organizationUUID: "org-team")
        let personal = ClaudeAccountIdentity(email: "same@example.com", organizationUUID: "org-personal")

        XCTAssertEqual(desktop.key, team.key)
        XCTAssertNotEqual(desktop.key, personal.key)
    }

    func testAutoSwitchCanSelectOtherOrganizationWithSameEmail() throws {
        let team = ClaudeAccountIdentity(email: "same@example.com", organizationUUID: "org-team").key
        let personal = ClaudeAccountIdentity(email: "same@example.com", organizationUUID: "org-personal").key
        let usage = [team: 95.0, personal: 12.0]

        let decision = try XCTUnwrap(AppDelegate.autoSwitchDecision(
            live: team, candidates: [team, personal], threshold: 90,
            utilization: { usage[$0] }))

        XCTAssertEqual(decision.target, personal)
        XCTAssertEqual(decision.liveUtil, 95)
        XCTAssertEqual(decision.targetUtil, 12)
    }
}

import XCTest
@testable import PitStop

/// Anthropic renamed the consumer Max plans on 2026-10-30 (Max 20x → Ultra,
/// Max 5x → Max), but tokens still carry `default_claude_max_20x` / `_5x`.
final class PlanLabelTests: XCTestCase {
    func testMaxTwentyXIsUltra() {
        XCTAssertEqual(Profile.planName(subscription: "max", tier: "default_claude_max_20x"), "Ultra")
        XCTAssertEqual(Profile.planName(subscription: "Max", tier: "default_claude_max_20x"), "Ultra")
    }

    func testMaxFiveXIsMax() {
        XCTAssertEqual(Profile.planName(subscription: "max", tier: "default_claude_max_5x"), "Max")
    }

    func testNonMaxPlansKeepTheirMultiplier() {
        XCTAssertEqual(Profile.planName(subscription: "team", tier: "default_claude_max_5x"), "Team · 5x")
    }

    func testPlansWithoutATier() {
        XCTAssertEqual(Profile.planName(subscription: "pro", tier: nil), "Pro")
        XCTAssertEqual(Profile.planName(subscription: "max", tier: nil), "Max")
        XCTAssertEqual(Profile.planName(subscription: nil, tier: nil), "")
    }

    func testProfileLabel() {
        let auto = Profile(email: "a@x.com", savedAt: Date(), subscriptionType: "max",
                           rateLimitTier: "default_claude_max_20x",
                           oauthAccount: ["organizationName": "a@x.com's Organization"])
        XCTAssertEqual(auto.planLabel, "Ultra")
        let named = Profile(email: "a@x.com", savedAt: Date(), subscriptionType: "max",
                            rateLimitTier: "default_claude_max_5x",
                            oauthAccount: ["organizationName": "Acme AI"])
        XCTAssertEqual(named.planLabel, "Acme AI · Max")
    }
}

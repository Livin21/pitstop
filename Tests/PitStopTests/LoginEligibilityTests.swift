import XCTest
@testable import PitStop

@MainActor
final class LoginEligibilityTests: XCTestCase {
    func testOfferLoginOnlyForInactiveSwitchableNeedsAction() {
        let d = AppDelegate()
        let claude = MenuAccount(email: "a@x.com", source: .code, planLabel: "", isActive: false)
        let claudeActive = MenuAccount(email: "a@x.com", source: .code, planLabel: "", isActive: true)
        let desktop = MenuAccount(email: "d@x.com", source: .desktop, planLabel: "", isActive: false)

        d.setNeedsActionForTest(["a@x.com", "d@x.com"])
        XCTAssertTrue(d.shouldOfferLogin(for: claude))      // inactive, switchable, needsAction
        XCTAssertFalse(d.shouldOfferLogin(for: claudeActive)) // active → no pill
        XCTAssertFalse(d.shouldOfferLogin(for: desktop))    // desktop not switchable

        d.setNeedsActionForTest([])
        XCTAssertFalse(d.shouldOfferLogin(for: claude))     // healthy → no pill
    }
}

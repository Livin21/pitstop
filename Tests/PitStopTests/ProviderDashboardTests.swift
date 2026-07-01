import XCTest
@testable import PitStop

final class ProviderDashboardTests: XCTestCase {
    func testDashboardURLs() {
        XCTAssertEqual(Provider.claude.dashboardURL?.absoluteString,
                       "https://claude.ai/new#settings/usage")
        XCTAssertEqual(Provider.codex.dashboardURL?.absoluteString,
                       "https://chatgpt.com/codex/cloud/settings/analytics#usage")
        XCTAssertEqual(Provider.gemini.dashboardURL?.absoluteString,
                       "https://gemini.google.com/usage")
    }

    func testEveryProviderHasADashboard() {
        for p in Provider.allCases { XCTAssertNotNil(p.dashboardURL, "\(p) missing dashboardURL") }
    }
}

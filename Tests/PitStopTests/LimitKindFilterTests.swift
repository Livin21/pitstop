import XCTest
@testable import PitStop

/// maxUtilization(kinds:) — auto-switch's filtered view of each provider's
/// usage. nil means "no enabled window reports a number": never a trigger,
/// never a target.
final class LimitKindFilterTests: XCTestCase {
    // MARK: Claude (UsageReport)

    private func claudeReport(fiveHour: Double? = nil, sevenDay: Double? = nil,
                              scoped: [(String, Double)] = []) -> UsageReport {
        var r = UsageReport()
        if let fiveHour { r.fiveHour = UsageWindow(utilization: fiveHour, resetsAt: nil) }
        if let sevenDay { r.sevenDay = UsageWindow(utilization: sevenDay, resetsAt: nil) }
        r.scoped = scoped.map {
            ScopedWindow(label: $0.0, window: UsageWindow(utilization: $0.1, resetsAt: nil))
        }
        return r
    }

    func testClaudeFullSetMatchesBindingMax() {
        let r = claudeReport(fiveHour: 10, sevenDay: 20, scoped: [("Fable", 95)])
        XCTAssertEqual(r.maxUtilization(kinds: Set(LimitKind.allCases)), 95)
        XCTAssertEqual(r.maxUtilization(kinds: Set(LimitKind.allCases)), r.maxUtilization)
    }

    func testClaudeDisabledPerModelIgnoresHotFable() {
        let r = claudeReport(fiveHour: 10, sevenDay: 20, scoped: [("Fable", 95)])
        XCTAssertEqual(r.maxUtilization(kinds: [.session, .weekly]), 20)
    }

    func testClaudeSessionOnly() {
        let r = claudeReport(fiveHour: 64, sevenDay: 80, scoped: [("Fable", 95)])
        XCTAssertEqual(r.maxUtilization(kinds: [.session]), 64)
    }

    func testClaudeNoEnabledWindowWithDataIsNil() {
        let r = claudeReport(scoped: [("Fable", 95)])
        XCTAssertNil(r.maxUtilization(kinds: [.session, .weekly]))
    }

    func testClaudeWindowWithoutNumberDoesNotCount() {
        var r = claudeReport(sevenDay: 20)
        r.fiveHour = UsageWindow(utilization: nil, resetsAt: nil)
        XCTAssertEqual(r.maxUtilization(kinds: [.session, .weekly]), 20)
        XCTAssertNil(r.maxUtilization(kinds: [.session]))
    }

    // MARK: Codex

    private func codexUsage(_ windows: [(String, Double)]) -> Codex.Usage {
        Codex.Usage(windows: windows.map {
            .init(label: $0.0, usedPercent: $0.1, resetsAt: nil)
        })
    }

    func testCodexFiveHourIsSession() {
        let u = codexUsage([("5h", 91), ("7d", 40)])
        XCTAssertEqual(u.maxUtilization(kinds: [.session]), 91)
        XCTAssertEqual(u.maxUtilization(kinds: [.weekly]), 40)
    }

    func testCodexThirtyDayCountsAsWeekly() {
        let u = codexUsage([("30d", 77)])
        XCTAssertEqual(u.maxUtilization(kinds: [.weekly]), 77)
        XCTAssertNil(u.maxUtilization(kinds: [.session]))
    }

    func testCodexUnknownLabelFallsToWeekly() {
        let u = codexUsage([("90d", 55)])
        XCTAssertEqual(u.maxUtilization(kinds: [.weekly]), 55)
        XCTAssertNil(u.maxUtilization(kinds: [.session, .perModel]))
    }

    func testCodexPerModelNeverMatches() {
        let u = codexUsage([("5h", 91), ("7d", 40)])
        XCTAssertNil(u.maxUtilization(kinds: [.perModel]))
    }
}

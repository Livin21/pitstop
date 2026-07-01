import XCTest
@testable import PitStop

final class UsageAPIParseTests: XCTestCase {
    func testParsesScopedWeeklyLimit() throws {
        let data = Data(#"""
        {
          "five_hour": {"utilization": 64.0, "resets_at": "2026-07-02T00:50:00.818202+00:00"},
          "seven_day": {"utilization": 7.0, "resets_at": "2026-07-05T00:00:00+00:00"},
          "limits": [
            {"kind": "session", "group": "session", "percent": 64, "resets_at": "2026-07-02T00:50:00.818202+00:00"},
            {"kind": "weekly_all", "group": "weekly", "percent": 7, "resets_at": "2026-07-05T00:00:00+00:00"},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 13,
             "resets_at": "2026-07-05T00:00:00+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
          ]
        }
        """#.utf8)
        let report = try UsageAPI.parse(data)
        XCTAssertEqual(report.scoped.count, 1)
        XCTAssertEqual(report.scoped.first?.label, "Fable")
        XCTAssertEqual(report.scoped.first?.window.utilization, 13)
        XCTAssertNotNil(report.scoped.first?.window.resetsAt)
        XCTAssertEqual(report.fiveHour?.utilization, 64)      // legacy fields preferred
        XCTAssertNotNil(report.fiveHour?.resetsAt)            // 6-digit fraction parses
    }

    func testScopedLabelFallsBack() throws {
        let data = Data(#"{"limits": [{"kind": "weekly_scoped", "percent": 5}]}"#.utf8)
        XCTAssertEqual(try UsageAPI.parse(data).scoped.first?.label, "Scoped")
    }

    func testFallsBackToLimitsForMainWindows() throws {
        let data = Data(#"""
        {"limits": [
          {"kind": "session", "percent": 42, "resets_at": "2026-07-02T00:50:00+00:00"},
          {"kind": "weekly_all", "percent": 24}
        ]}
        """#.utf8)
        let report = try UsageAPI.parse(data)
        XCTAssertEqual(report.fiveHour?.utilization, 42)
        XCTAssertNotNil(report.fiveHour?.resetsAt)
        XCTAssertEqual(report.sevenDay?.utilization, 24)
    }

    func testUnknownLimitKindsIgnored() throws {
        let data = Data(#"{"limits": [{"kind": "hourly_lunar", "percent": 99}], "five_hour": {"utilization": 1}}"#.utf8)
        let report = try UsageAPI.parse(data)
        XCTAssertTrue(report.scoped.isEmpty)
        XCTAssertEqual(report.maxUtilization, 1)
    }

    func testBindingIncludesScoped() throws {
        let data = Data(#"""
        {"five_hour": {"utilization": 10}, "seven_day": {"utilization": 20},
         "limits": [{"kind": "weekly_scoped", "percent": 95,
                     "resets_at": "2026-07-05T00:00:00+00:00",
                     "scope": {"model": {"display_name": "Fable"}}}]}
        """#.utf8)
        let report = try UsageAPI.parse(data)
        XCTAssertEqual(report.maxUtilization, 95)
        XCTAssertNotNil(report.bindingWindow?.resetsAt)   // Fable's reset drives notifications
    }
}

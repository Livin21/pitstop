import XCTest
@testable import PitStop

/// Ultra accounts (formerly Max 20x) lost their 5-hour limit on 2026-10-30.
/// The usage endpoint then sends an explicit `"five_hour": null` and no
/// `session` entry in `limits[]` — "no such limit", not "data missing".
final class NoFiveHourLimitTests: XCTestCase {
    /// The live payload shape for an Ultra account, trimmed.
    private let ultraPayload = Data(#"""
    {
      "five_hour": null,
      "seven_day": {"utilization": 84.0, "resets_at": "2026-11-02T15:00:00.022909+00:00"},
      "limits": [
        {"kind": "weekly_all", "group": "weekly", "percent": 84,
         "resets_at": "2026-11-02T15:00:00.022909+00:00", "scope": null},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 0,
         "resets_at": "2026-11-02T15:00:00+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
      ]
    }
    """#.utf8)

    // MARK: Parsing

    func testExplicitNullFiveHourMeansNoLimit() throws {
        let report = try UsageAPI.parse(ultraPayload)
        XCTAssertTrue(report.noFiveHourLimit)
        XCTAssertNil(report.fiveHour)
        XCTAssertEqual(report.sevenDay?.utilization, 84)
        XCTAssertEqual(report.scoped.first?.label, "Fable")
    }

    func testAbsentFiveHourKeyIsNotNoLimit() throws {
        let data = Data(#"{"seven_day": {"utilization": 20}}"#.utf8)
        XCTAssertFalse(try UsageAPI.parse(data).noFiveHourLimit)
    }

    func testNullFiveHourWithSessionLimitIsStillTracked() throws {
        let data = Data(#"""
        {"five_hour": null,
         "limits": [{"kind": "session", "percent": 42, "resets_at": "2026-07-02T00:50:00+00:00"}]}
        """#.utf8)
        let report = try UsageAPI.parse(data)
        XCTAssertFalse(report.noFiveHourLimit)
        XCTAssertEqual(report.fiveHour?.utilization, 42)
    }

    func testIdleFiveHourWindowIsNotNoLimit() throws {
        let data = Data(#"{"five_hour": {"utilization": 0, "resets_at": null}}"#.utf8)
        let report = try UsageAPI.parse(data)
        XCTAssertFalse(report.noFiveHourLimit)
        XCTAssertEqual(report.fiveHour?.utilization, 0)
    }

    // MARK: Cache compatibility

    /// Reports cached before this field existed must still load, or every
    /// bar blanks for a launch after the upgrade.
    func testDecodesReportCachedBeforeTheFieldExisted() throws {
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(UsageReport())) as? [String: Any])
        dict.removeValue(forKey: "noFiveHourLimit")
        let legacy = try JSONSerialization.data(withJSONObject: dict)
        let report = try JSONDecoder().decode(UsageReport.self, from: legacy)
        XCTAssertFalse(report.noFiveHourLimit)
    }

    func testRoundTripKeepsNoFiveHourLimit() throws {
        let report = try UsageAPI.parse(ultraPayload)
        let decoded = try JSONDecoder().decode(UsageReport.self,
                                               from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded, report)
        XCTAssertTrue(decoded.noFiveHourLimit)
    }

    // MARK: Consumers

    /// Warming starts a 5-hour session; with no such limit there is nothing
    /// to start, and resetsAt stays nil forever — without this guard it
    /// fired every cooldown.
    func testNoFiveHourLimitNeverWarms() {
        let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 31,
                                                              hour: 12, minute: 0))!
        XCTAssertFalse(SessionWarmer.shouldWarm(now: noon, windowStartMinutes: 360,
                                                windowEndMinutes: 1080, resetsAt: nil,
                                                lastAttempt: nil, noFiveHourLimit: true))
        XCTAssertTrue(SessionWarmer.shouldWarm(now: noon, windowStartMinutes: 360,
                                               windowEndMinutes: 1080, resetsAt: nil,
                                               lastAttempt: nil))
    }

    /// A menu bar pinned to the 5-hour limit shows the highest limit instead
    /// of a dash when the account has no 5-hour limit.
    func testFiveHourMetricFallsBackToHighestLimit() throws {
        let report = try UsageAPI.parse(ultraPayload)
        XCTAssertEqual(IndicatorMetric.fiveHour.utilization(of: report), 84)
    }

    func testFiveHourMetricStillDashesWhenDataIsMissing() {
        var report = UsageReport()
        report.sevenDay = UsageWindow(utilization: 50, resetsAt: nil)
        XCTAssertNil(IndicatorMetric.fiveHour.utilization(of: report))
    }

    /// Auto-switch: a missing 5-hour limit can never block the account, so
    /// with only the session kind enabled it reads as 0%, not "no data".
    func testSessionKindReadsZeroWithoutAFiveHourLimit() throws {
        let report = try UsageAPI.parse(ultraPayload)
        XCTAssertEqual(report.maxUtilization(kinds: [.session]), 0)
        XCTAssertEqual(report.maxUtilization(kinds: [.session, .weekly]), 84)
    }
}

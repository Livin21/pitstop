import XCTest
@testable import PitStop

final class SessionWarmerTests: XCTestCase {
    /// A fixed, deterministic date — 2026-07-16 at h:m local time.
    private func at(_ h: Int, _ m: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 16,
                                                   hour: h, minute: m))!
    }

    /// shouldWarm with only the argument under test varying.
    private func warm(now: Date, start: Int = 360, end: Int = 1080,
                      resetsAt: Date? = nil, lastAttempt: Date? = nil) -> Bool {
        SessionWarmer.shouldWarm(now: now, windowStartMinutes: start,
                                 windowEndMinutes: end, resetsAt: resetsAt,
                                 lastAttempt: lastAttempt)
    }

    func testWindowBounds() {
        XCTAssertTrue(warm(now: at(7, 0)))              // inside 6:00–18:00
        XCTAssertFalse(warm(now: at(5, 59)))            // before start
        XCTAssertTrue(warm(now: at(6, 0)))              // start is inclusive
        XCTAssertFalse(warm(now: at(18, 0)))            // end is exclusive
        XCTAssertFalse(warm(now: at(23, 30)))           // after end
    }

    func testWrapAroundWindow() {
        // 22:00–04:00 spans midnight.
        XCTAssertTrue(warm(now: at(23, 0), start: 1320, end: 240))
        XCTAssertTrue(warm(now: at(3, 0), start: 1320, end: 240))
        XCTAssertFalse(warm(now: at(12, 0), start: 1320, end: 240))
    }

    func testEmptyWindowNeverWarms() {
        XCTAssertFalse(warm(now: at(7, 0), start: 420, end: 420))
    }

    func testRunningSessionBlocksWarm() {
        let now = at(9, 0)
        XCTAssertFalse(warm(now: now, resetsAt: now.addingTimeInterval(3600)))
        XCTAssertTrue(warm(now: now, resetsAt: now.addingTimeInterval(-60)))  // window ended
        XCTAssertTrue(warm(now: now, resetsAt: nil))                          // never started
    }

    func testCooldownBlocksRetry() {
        let now = at(9, 0)
        XCTAssertFalse(warm(now: now, lastAttempt: now.addingTimeInterval(-9 * 60)))
        XCTAssertTrue(warm(now: now, lastAttempt: now.addingTimeInterval(-11 * 60)))
    }
}

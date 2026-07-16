import XCTest
@testable import PitStop

final class AutoSwitchKindsTests: XCTestCase {
    private let keys = ["autoSwitchOnSession", "autoSwitchOnWeekly", "autoSwitchOnPerModel"]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testAbsentKeysMeanAllKinds() {
        XCTAssertEqual(Settings.autoSwitchKinds, Set(LimitKind.allCases))
    }

    func testFalseKeyRemovesItsKind() {
        UserDefaults.standard.set(false, forKey: "autoSwitchOnPerModel")
        XCTAssertEqual(Settings.autoSwitchKinds, [.session, .weekly])
    }

    func testAllFalseIsEmpty() {
        keys.forEach { UserDefaults.standard.set(false, forKey: $0) }
        XCTAssertTrue(Settings.autoSwitchKinds.isEmpty)
    }

    func testExplicitTrueStillCounts() {
        UserDefaults.standard.set(true, forKey: "autoSwitchOnSession")
        UserDefaults.standard.set(false, forKey: "autoSwitchOnWeekly")
        XCTAssertEqual(Settings.autoSwitchKinds, [.session, .perModel])
    }

    func testObservedKeysIncludeTriggerKeys() {
        keys.forEach { XCTAssertTrue(Settings.observedKeys.contains($0)) }
    }
}

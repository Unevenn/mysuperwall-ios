import XCTest
@testable import MySuperwall

final class LifecycleHistoryTests: XCTestCase {
    func testBackgroundExcludedAndThresholdsSurviveMissingConfiguration() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let h = LifecycleHistory(defaults: defaults, scope: "a", version: "1", now: 1000)
        h.resume(now: 1000); h.tick(keys: [], now: 1120); h.pause(now: 1120)
        h.resume(now: 4720); h.tick(keys: ["mysuperwall.day_1","mysuperwall.active_minutes_1"], now: 4720)
        XCTAssertEqual(h.state.active, 120)
        XCTAssertEqual(h.state.sessions, 2)
        XCTAssertEqual(h.state.pending["mysuperwall.active_minutes_1"], 1060)
        XCTAssertEqual(h.state.pending["mysuperwall.session_2"], 4720)
        h.shown("mysuperwall.install", occurrence: 1000)
        XCTAssertNil(h.state.pending["mysuperwall.install"])
        let restored = LifecycleHistory(defaults: defaults, scope: "a", version: "2", now: 5000)
        XCTAssertNil(restored.state.pending["mysuperwall.install"])
        XCTAssertEqual(restored.state.pending["mysuperwall.update"], 5000)
        XCTAssertEqual(restored.state.pending["mysuperwall.active_minutes_1"], 1060)
    }
    func testThirtyDayExpiryDoesNotResurrectOldDayThreshold() {
        let h = LifecycleHistory(defaults: UserDefaults(suiteName: UUID().uuidString)!, scope: "b", version: "1", now: 1000)
        let now = 1000 + 32 * 86400.0
        h.tick(keys: ["mysuperwall.day_1"], now: now)
        XCTAssertNil(h.state.pending["mysuperwall.install"])
        XCTAssertNil(h.state.pending["mysuperwall.day_1"])
        h.tick(keys: ["mysuperwall.day_1"], now: now + 1)
        XCTAssertNil(h.state.pending["mysuperwall.day_1"])
    }
}

import XCTest
@testable import MySuperwall

final class LifecycleGateTests: XCTestCase {
    private func trigger(_ fields: String) throws -> ManifestTrigger {
        let json = "{\"id\":\"t\",\"key\":\"mysuperwall.session\",\"paywallId\":null,\"variants\":[],\"rules\":[]\(fields)}"
        return try JSONDecoder().decode(ManifestTrigger.self, from: Data(json.utf8))
    }
    private func gate(_ defaults: UserDefaults) -> LifecycleGate { LifecycleGate(defaults: defaults, scope: "s") }
    private func newDefaults() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    func testMissingFieldsNeverBlock() throws {
        XCTAssertNil(gate(newDefaults()).blockReason(try trigger(""), sessions: 0, premium: true, now: 1000))
    }

    func testScheduleSubscribersAndDelay() throws {
        let t = try trigger(",\"schedule\":{\"fromOpen\":2,\"delaySeconds\":5},\"displayLimit\":{\"hideForPurchasers\":true}")
        let g = gate(newDefaults())
        XCTAssertEqual(g.blockReason(t, sessions: 1, premium: false, now: 1000), "schedule_not_reached")
        XCTAssertNil(g.blockReason(t, sessions: 2, premium: false, now: 1000))
        XCTAssertEqual(g.blockReason(t, sessions: 2, premium: true, now: 1000), "purchased")
        XCTAssertEqual(g.remainingDelay(t, readyAt: 1000, now: 1003), 2)
        XCTAssertEqual(g.remainingDelay(t, readyAt: 1000, now: 1007), 0)
    }

    func testLimitsSurviveRestart() throws {
        let defaults = newDefaults()
        let g = gate(defaults)
        let now = 8_640_000.0
        let weekly = try trigger(",\"displayLimit\":{\"maxPerPeriod\":1,\"period\":\"week\"}")
        g.recordShown(weekly.key, now: now)
        XCTAssertEqual(g.blockReason(weekly, sessions: 5, premium: false, now: now + 6 * 86400), "max_per_period")
        XCTAssertNil(g.blockReason(weekly, sessions: 5, premium: false, now: now + 8 * 86400))
        let spaced = try trigger(",\"displayLimit\":{\"minIntervalHours\":6,\"maxPerUser\":2}")
        XCTAssertEqual(g.blockReason(spaced, sessions: 5, premium: false, now: now + 5 * 3600), "min_interval")
        XCTAssertNil(g.blockReason(spaced, sessions: 5, premium: false, now: now + 6 * 3600))
        g.recordShown(spaced.key, now: now + 6 * 3600)
        g.recordDismissed(spaced.key)
        let reopened = gate(defaults)
        XCTAssertEqual(reopened.blockReason(spaced, sessions: 5, premium: false, now: now + 90 * 86400), "max_per_user")
        let dismissals = try trigger(",\"displayLimit\":{\"stopAfterDismissals\":1}")
        XCTAssertEqual(reopened.blockReason(dismissals, sessions: 5, premium: false, now: now), "dismissals")
    }
}

import XCTest
@testable import MySuperwall

final class PendingFollowUpsTests: XCTestCase {
    func testElapsedOfferSurvivesRestartAndCommitsOnlyOnShown() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let history = LifecycleHistory(defaults: defaults,scope: "x",version: "1",now: 1000)
        let rule = ManifestFollowUpRule(enabled: true,triggerKey: "discount",timingMode: "elapsed",waitMinutes: 10,expiresMinutes: 60)
        let store = PendingFollowUps(defaults: defaults,scope: "x")
        store.enqueue(source: "source",event: "onDismiss",rule: rule,metrics: history.state,depth: 0,seen: ["source"],now: 1000)
        let loaded = PendingFollowUps(defaults: defaults,scope: "x")
        XCTAssertTrue(loaded.eligible(metrics: history.state,premium: false,current: { _,_ in rule },now: 1599).isEmpty)
        let due = loaded.eligible(metrics: history.state,premium: false,current: { _,_ in rule },now: 1600)
        XCTAssertEqual(due.count,1)
        XCTAssertEqual(loaded.eligible(metrics: history.state,premium: false,current: { _,_ in rule },now: 1601).count,1,"unsuccessful attempts retain the offer")
        loaded.shown(due[0].id,now: 1602)
        XCTAssertTrue(loaded.eligible(metrics: history.state,premium: false,current: { _,_ in rule },now: 1603).isEmpty)
    }
    func testPurchaseAndPolicyRemovalCancelOffers() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let history = LifecycleHistory(defaults: defaults,scope: "y",version: "1",now: 1000)
        let rule = ManifestFollowUpRule(enabled: true,triggerKey: "discount",timingMode: "immediate")
        let store = PendingFollowUps(defaults: defaults,scope: "y")
        store.enqueue(source: "source",event: "onDismiss",rule: rule,metrics: history.state,depth: 0,seen: [],now: 1000)
        store.cancelAfterPurchase()
        XCTAssertTrue(store.eligible(metrics: history.state,premium: false,current: { _,_ in rule },now: 1001).isEmpty)
        store.enqueue(source: "source",event: "onDismiss",rule: rule,metrics: history.state,depth: 0,seen: [],now: 1000)
        XCTAssertTrue(store.eligible(metrics: history.state,premium: false,current: { _,_ in nil },now: 1001).isEmpty)
    }
}

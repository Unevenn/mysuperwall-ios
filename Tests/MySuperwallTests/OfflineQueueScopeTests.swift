import XCTest
@testable import MySuperwall

final class OfflineQueueScopeTests: XCTestCase {
    func testQueueFlushUsesOnlyMatchingAppAndServerScope() {
        StubURLProtocol.reset()
        let defaults = freshDefaults("queue.scopes")
        let queue = OfflineEventQueue(userDefaults: defaults, session: StubURLProtocol.session())
        let one = ManifestScope(baseURL: "https://one.test", appKey: "one", appIdentifier: "com.app", platform: "ios", lang: "en")
        let two = ManifestScope(baseURL: "https://two.test", appKey: "two", appIdentifier: "com.app", platform: "ios", lang: "en")
        queue.enqueue(event: ["type": "paywall_shown", "paywallId": "one", "userId": "user"], scope: one)
        queue.enqueue(event: ["type": "paywall_shown", "paywallId": "two", "userId": "user"], scope: two)
        let first = expectation(description: "first flush")
        queue.flush(baseUrl: "https://one.test/", appKey: "one", bundleId: "com.app") { count in
            XCTAssertEqual(count, 1); first.fulfill()
        }
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })
        let firstEvents = StubURLProtocol.bodies.last?["events"] as? [[String: Any]]
        XCTAssertEqual(firstEvents?.first?["paywallId"] as? String, "one")
        StubURLProtocol.respondNext(); wait(for: [first], timeout: 3)
        let second = expectation(description: "second flush")
        queue.flush(baseUrl: "https://two.test/", appKey: "two", bundleId: "com.app") { count in
            XCTAssertEqual(count, 1); second.fulfill()
        }
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })
        let secondEvents = StubURLProtocol.bodies.last?["events"] as? [[String: Any]]
        XCTAssertEqual(secondEvents?.first?["paywallId"] as? String, "two")
        StubURLProtocol.respondNext(); wait(for: [second], timeout: 3)
    }
}

import XCTest
@testable import MySuperwall

private final class RecordingTransport: PushTransport {
    var calls: [(path: String, body: [String: Any])] = []
    var accept = true
    func post(path: String, body: [String: Any], completion: @escaping (Bool) -> Void) {
        calls.append((path, body))
        completion(accept)
    }
}

final class PushRegistrarTests: XCTestCase {
    private var transport: RecordingTransport!
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var registrar: PushRegistrar!

    override func setUp() {
        super.setUp()
        transport = RecordingTransport()
        defaults = UserDefaults(suiteName: "msw.push.\(UUID().uuidString)")!
        clock = Date(timeIntervalSince1970: 1_000)
        registrar = PushRegistrar(defaults: defaults, transport: transport, queue: DispatchQueue(label: "test.push"), now: { [unowned self] in self.clock })
    }

    private func identity(user: String? = "u1", locale: String = "tr") -> PushIdentity {
        PushIdentity(appKey: "key", bundleId: "com.app", userId: user, locale: locale, appVersion: "1.2.3", utcOffsetMinutes: 180)
    }

    private func settle() {
        let done = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testSetSendsTokenWithIdentityAndLanguage() {
        XCTAssertTrue(registrar.set("  tok  ", identity: identity()))
        settle()
        XCTAssertEqual(transport.calls.count, 1)
        let call = transport.calls[0]
        XCTAssertEqual(call.path, "paywall/push-token")
        XCTAssertEqual(call.body["token"] as? String, "tok")
        XCTAssertEqual(call.body["userId"] as? String, "u1")
        XCTAssertEqual(call.body["locale"] as? String, "tr")
        XCTAssertEqual(call.body["platform"] as? String, "ios")
        XCTAssertEqual(call.body["bundleId"] as? String, "com.app")
        XCTAssertEqual(call.body["utcOffsetMinutes"] as? Int, 180)
    }

    func testEmptyTokenIsRejected() {
        XCTAssertFalse(registrar.set("  ", identity: identity()))
        settle()
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testSyncSkipsUnchangedRegistrationsForADayUnlessForced() {
        registrar.set("tok", identity: identity()); settle()
        transport.calls.removeAll()
        registrar.sync(identity: identity()); settle()
        XCTAssertTrue(transport.calls.isEmpty)
        registrar.sync(identity: identity(locale: "de")); settle()
        XCTAssertEqual(transport.calls.last?.body["locale"] as? String, "de")
        transport.calls.removeAll()
        clock = clock.addingTimeInterval(25 * 3600)
        registrar.sync(identity: identity(locale: "de")); settle()
        XCTAssertEqual(transport.calls.count, 1)
        transport.calls.removeAll()
        registrar.sync(identity: identity(locale: "de"), force: true); settle()
        XCTAssertEqual(transport.calls.count, 1)
    }

    func testFailedRegistrationIsRetried() {
        transport.accept = false
        registrar.set("tok", identity: identity()); settle()
        transport.calls.removeAll()
        transport.accept = true
        registrar.sync(identity: identity()); settle()
        XCTAssertEqual(transport.calls.count, 1)
    }

    func testClearForgetsTheTokenAndTellsTheServer() {
        registrar.set("tok", identity: identity()); settle()
        transport.calls.removeAll()
        registrar.clear(identity: identity()); settle()
        XCTAssertEqual(transport.calls.first?.path, "paywall/push-token/remove")
        XCTAssertEqual(transport.calls.first?.body["token"] as? String, "tok")
        XCTAssertNil(registrar.savedToken)
        transport.calls.removeAll()
        registrar.sync(identity: identity()); settle()
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testReportOpenedSendsJobAndUser() {
        registrar.reportOpened(jobId: "job1", identity: identity()); settle()
        XCTAssertEqual(transport.calls.first?.path, "paywall/notification-opened")
        XCTAssertEqual(transport.calls.first?.body["jobId"] as? String, "job1")
        XCTAssertEqual(transport.calls.first?.body["userId"] as? String, "u1")
    }

    func testNotificationMarkerAndTrigger() {
        XCTAssertTrue(MySuperwall.isMySuperwallNotification(["mysuperwall": "1"]))
        XCTAssertFalse(MySuperwall.isMySuperwallNotification(["other": "1"]))
        XCTAssertFalse(MySuperwall.isMySuperwallNotification(nil))
        let sdk = MySuperwall(userDefaults: UserDefaults(suiteName: "msw.push.\(UUID().uuidString)")!, bundleIdentifier: "com.app", pushTransport: transport)
        XCTAssertEqual(sdk.trackNotificationOpened(userInfo: ["mysuperwall": "1", "triggerKey": " discount ", "jobId": "j"]), "discount")
        XCTAssertNil(sdk.trackNotificationOpened(userInfo: ["x": "1"]))
    }
}

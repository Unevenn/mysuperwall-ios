#if canImport(UIKit)
import UIKit
import XCTest
@testable import MySuperwall

/// Runs on the iOS simulator (`xcodebuild test`); `swift test` on macOS skips it.
final class PrewarmTests: XCTestCase {
    private var defaults: UserDefaults!
    private var service: ManifestService!
    private var sdk: MySuperwall!

    private func manifest(html: String, paywall: String = "pw1") -> PaywallManifest {
        PaywallManifest(ok: true, hash: html,
                        triggers: [ManifestTrigger(id: "t", key: "main", paywallId: paywall)],
                        paywalls: [paywall: ManifestPaywall(id: paywall, name: paywall, templateKey: "t", html: html)])
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        defaults = freshDefaults("prewarm")
        service = ManifestService(userDefaults: defaults, session: StubURLProtocol.session())
        sdk = MySuperwall(manifestService: service,
                          eventQueue: OfflineEventQueue(userDefaults: defaults, session: StubURLProtocol.session()),
                          userDefaults: defaults, bundleIdentifier: "com.app")
        sdk.configure(appKey: "k", userId: "u1", baseUrl: "https://mysuperwall.com", locale: "en", country: nil)
        service.saveToDisk(manifest(html: "<p>A</p>"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    override func tearDown() {
        sdk.dispose()
        super.tearDown()
    }

    func testPrewarmBuildsOneLoadedSlotForTheResolvedPaywall() {
        sdk.prewarm(triggerKey: "main")
        XCTAssertEqual(sdk.prewarmedPaywall?.id, "pw1")
        XCTAssertEqual(sdk.prewarmedPaywall?.html, "<p>A</p>")
        XCTAssertEqual(sdk.paywallState(for: "main"), .idle, "off-screen preparation reports no lifecycle state")

        sdk.prewarm(triggerKey: "missing")
        XCTAssertNil(sdk.prewarmedPaywall, "one slot: the new target replaces the old one")
    }

    func testSlotIsRebuiltAfterManifestChange() {
        sdk.prewarm(triggerKey: "main")
        service.saveToDisk(manifest(html: "<p>B</p>"))
        XCTAssertTrue(waitUntil { self.sdk.prewarmedPaywall?.html == "<p>B</p>" })

        service.saveToDisk(manifest(html: "<p>C</p>", paywall: "pw2"))
        XCTAssertTrue(waitUntil { self.sdk.prewarmedPaywall?.id == "pw2" })
    }

    func testSlotIsRebuiltAfterLocaleChange() {
        let tr = ManifestScope(baseURL: "https://mysuperwall.com/", appKey: "k", appIdentifier: "com.app", platform: "ios", lang: "tr")
        defaults.set(try! JSONEncoder().encode(manifest(html: "<p>TR</p>")), forKey: tr.cacheKey)
        sdk.prewarm(triggerKey: "main")
        sdk.setLocale("tr")
        XCTAssertTrue(waitUntil { self.sdk.prewarmedPaywall?.html == "<p>TR</p>" })
    }

    func testMemoryWarningAndDisposeReleaseTheSlot() {
        sdk.prewarm(triggerKey: "main")
        XCTAssertNotNil(sdk.prewarmedPaywall)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertNil(sdk.prewarmedPaywall)

        sdk.prewarm(triggerKey: "main")
        sdk.dispose()
        XCTAssertNil(sdk.prewarmedPaywall)
    }

    func testReleaseStopsRebuilding() {
        sdk.prewarm(triggerKey: "main")
        sdk.releasePrewarmedPaywall()
        service.saveToDisk(manifest(html: "<p>B</p>"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(sdk.prewarmedPaywall)
    }

    func testPrewarmedControllerAdoptsTheFreshAttribution() {
        let prepared = PaywallData(id: "pw1", name: "pw1", html: "<p>A</p>", triggerKey: "main", abVariant: "A")
        let controller = PaywallWebViewController(paywall: prepared, delegate: nil, prewarmed: true)
        controller.loadViewIfNeeded()
        XCTAssertTrue(controller.isReusablePrewarm)

        let fresh = PaywallData(id: "pw1", name: "pw1", html: "<p>A</p>", triggerKey: "follow", abVariant: "B", attributionUserId: "u2")
        controller.activatePrewarmed(paywall: fresh, delegate: nil)
        XCTAssertFalse(controller.isReusablePrewarm, "a handed-out controller is never reused")
        XCTAssertEqual(controller.paywall.triggerKey, "follow")
        XCTAssertEqual(controller.paywall.abVariant, "B")
    }
}
#endif

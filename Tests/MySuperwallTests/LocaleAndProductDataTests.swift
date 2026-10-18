import XCTest
@testable import MySuperwall

final class LocaleAndProductDataTests: XCTestCase {
    private func scope(lang: String, prices: [String: Any] = [:], key: String = "k") -> ManifestScope {
        ManifestScope(baseURL: "https://mysuperwall.com/", appKey: key, appIdentifier: "com.app", platform: "ios",
                      lang: lang, priceFingerprint: ManifestScope.fingerprint(prices))
    }

    private func manifest(_ hash: String, html: String = "<html/>") -> PaywallManifest {
        PaywallManifest(ok: true, hash: hash,
                        triggers: [ManifestTrigger(id: "t", key: "main", paywallId: "pw1")],
                        paywalls: ["pw1": ManifestPaywall(id: "pw1", name: "pw1", templateKey: "t", html: html)])
    }

    private func makeSDK(_ defaults: UserDefaults) -> (MySuperwall, ManifestService) {
        let service = ManifestService(userDefaults: defaults, session: StubURLProtocol.session())
        let sdk = MySuperwall(manifestService: service,
                              eventQueue: OfflineEventQueue(userDefaults: defaults, session: StubURLProtocol.session()),
                              userDefaults: defaults, bundleIdentifier: "com.app")
        return (sdk, service)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: Locale

    func testBaseLanguageAndSatisfaction() {
        XCTAssertEqual(LocaleSupport.baseLanguage("tr-tr"), "tr")
        XCTAssertEqual(LocaleSupport.baseLanguage("en"), "en")
        XCTAssertTrue(LocaleSupport.isSatisfied(requested: "tr", by: "tr-tr"))
        XCTAssertTrue(LocaleSupport.isSatisfied(requested: "tr", by: "tr"))
        XCTAssertFalse(LocaleSupport.isSatisfied(requested: "tr-tr", by: "tr"), "a region is a real request")
        XCTAssertFalse(LocaleSupport.isSatisfied(requested: "pt-pt", by: "pt-br"))
        XCTAssertFalse(LocaleSupport.isSatisfied(requested: "en", by: "tr-tr"))
    }

    func testRegionalVariantKeepsPreviousManifestUntilItsOwnSyncSucceeds() {
        let defaults = freshDefaults("locale.variant")
        let service = ManifestService(userDefaults: defaults, session: StubURLProtocol.session())
        service.activate(scope: scope(lang: "tr-tr"))
        service.saveToDisk(manifest("tr-tr-hash"))

        XCTAssertTrue(service.activate(scope: scope(lang: "tr")))
        XCTAssertEqual(service.manifest?.hash, "tr-tr-hash", "same language must not empty the manifest")
        XCTAssertTrue(service.isServingProvisionalManifest)
        XCTAssertNil(defaults.data(forKey: scope(lang: "tr").cacheKey), "provisional manifest is memory only")

        let done = expectation(description: "sync")
        service.syncInBackground(baseUrl: "https://mysuperwall.com/", appKey: "k", bundleId: "com.app", lang: "tr") { _ in done.fulfill() }
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })
        XCTAssertNil(StubURLProtocol.bodies[0]["hash"], "another scope's hash must not validate this scope")
        StubURLProtocol.respondNext(body: manifestJSON(hash: "tr-hash"))
        wait(for: [done], timeout: 3)

        XCTAssertEqual(service.manifest?.hash, "tr-hash")
        XCTAssertFalse(service.isServingProvisionalManifest)
        XCTAssertNotNil(defaults.data(forKey: scope(lang: "tr").cacheKey))
    }

    func testProvisionalManifestSurvivesFailedSync() {
        let service = ManifestService(userDefaults: freshDefaults("locale.fail"), session: StubURLProtocol.session())
        service.activate(scope: scope(lang: "tr-tr"))
        service.saveToDisk(manifest("tr-tr-hash"))
        let done = expectation(description: "sync")
        service.syncInBackground(baseUrl: "https://mysuperwall.com/", appKey: "k", bundleId: "com.app", lang: "tr") { _ in done.fulfill() }
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })
        StubURLProtocol.respondNext(status: 500)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(service.manifest?.hash, "tr-tr-hash")
    }

    func testOwnCacheWinsOverPreviousVariant() {
        let defaults = freshDefaults("locale.own")
        let service = ManifestService(userDefaults: defaults, session: StubURLProtocol.session())
        defaults.set(try! JSONEncoder().encode(manifest("cached-tr")), forKey: scope(lang: "tr").cacheKey)
        service.activate(scope: scope(lang: "tr-tr"))
        service.saveToDisk(manifest("tr-tr-hash"))
        service.activate(scope: scope(lang: "tr"))
        XCTAssertEqual(service.manifest?.hash, "cached-tr")
        XCTAssertFalse(service.isServingProvisionalManifest)
    }

    func testOtherLanguagesPricesAndAppsNeverCarryOver() {
        let service = ManifestService(userDefaults: freshDefaults("locale.isolation"), session: StubURLProtocol.session())
        service.activate(scope: scope(lang: "tr-tr"))
        service.saveToDisk(manifest("tr-tr-hash"))
        service.activate(scope: scope(lang: "en"))
        XCTAssertNil(service.manifest, "another language must never be shown")

        service.activate(scope: scope(lang: "tr-tr"))
        service.saveToDisk(manifest("tr-tr-hash"))
        service.activate(scope: scope(lang: "tr", prices: ["pro": "₺1"]))
        XCTAssertNil(service.manifest, "a different price payload must never show old prices")

        service.activate(scope: scope(lang: "tr-tr"))
        service.activate(scope: scope(lang: "tr", key: "other-app"))
        XCTAssertNil(service.manifest)
    }

    func testSetLocaleWithSameBaseLanguageIsNoOp() {
        let defaults = freshDefaults("locale.facade.noop")
        let (sdk, service) = makeSDK(defaults)
        defaults.set(try! JSONEncoder().encode(manifest("cached")), forKey: scope(lang: "tr-tr").cacheKey)
        sdk.configure(appKey: "k", userId: "u1", baseUrl: "https://mysuperwall.com", locale: "tr-TR", country: nil)
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })

        sdk.setLocale("tr")
        sdk.setLocale("TR")
        XCTAssertEqual(sdk.lang, "tr-tr")
        XCTAssertEqual(service.manifest?.hash, "cached")
        XCTAssertTrue(sdk.resolveTrigger(triggerKey: "main").show)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        // Filtered by this test's language: a previous test's late request may still be recorded.
        XCTAssertEqual(StubURLProtocol.bodies.filter { ($0["lang"] as? String)?.hasPrefix("tr") == true }.count, 1,
                       "no new manifest request")
    }

    func testSetLocaleToRegionalVariantKeepsPaywallVisibleDuringSync() {
        let defaults = freshDefaults("locale.facade.variant")
        let (sdk, service) = makeSDK(defaults)
        defaults.set(try! JSONEncoder().encode(manifest("cached")), forKey: scope(lang: "tr").cacheKey)
        sdk.configure(appKey: "k", userId: "u1", baseUrl: "https://mysuperwall.com", locale: "tr", country: nil)

        sdk.setLocale("tr-TR")
        XCTAssertEqual(sdk.lang, "tr-tr")
        XCTAssertTrue(service.isServingProvisionalManifest)
        XCTAssertTrue(sdk.resolveTrigger(triggerKey: "main").show, "paywall must not silently disappear")
        XCTAssertTrue(waitUntil { StubURLProtocol.bodies.last?["lang"] as? String == "tr-tr" })

        sdk.setLocale("en")
        XCTAssertFalse(sdk.resolveTrigger(triggerKey: "main").show, "different language: nothing cached yet")
        XCTAssertTrue(waitUntil { StubURLProtocol.bodies.last?["lang"] as? String == "en" }, "drain before the next test")
    }

    // MARK: Product data

    func testUnchangedProductDataSkipsTheNetwork() {
        let defaults = freshDefaults("products.skip")
        let (sdk, service) = makeSDK(defaults)
        sdk.configure(appKey: "k", userId: "u1", baseUrl: "https://mysuperwall.com", locale: "en", country: nil)
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })
        StubURLProtocol.respondNext(body: manifestJSON(hash: "plain"))
        XCTAssertTrue(waitUntil { service.manifest?.hash == "plain" })

        let products: [String: Any] = ["pro": ["displayPrice": "$9.99", "currencyCode": "USD"], "basic": ["displayPrice": "$1"]]
        let first = expectation(description: "first")
        sdk.setProductData(products) { _ in first.fulfill() }
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })
        StubURLProtocol.respondNext(body: manifestJSON(hash: "priced"))
        wait(for: [first], timeout: 3)
        let requests = StubURLProtocol.bodies.count

        let second = expectation(description: "second")
        var delivered: PaywallManifest?
        // Same content, different key order: same fingerprint.
        sdk.setProductData(["basic": ["displayPrice": "$1"], "pro": ["currencyCode": "USD", "displayPrice": "$9.99"]]) {
            delivered = try? $0.get(); second.fulfill()
        }
        wait(for: [second], timeout: 1)
        XCTAssertEqual(delivered?.hash, "priced")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(StubURLProtocol.bodies.count, requests, "unchanged products must not hit the network")

        sdk.setProductData(["pro": ["displayPrice": "$10.99"]])
        XCTAssertTrue(waitUntil { StubURLProtocol.bodies.count == requests + 1 }, "changed products still sync")
    }

    func testUnchangedProductDataStillSyncsWhenNothingIsCached() {
        let (sdk, _) = makeSDK(freshDefaults("products.empty"))
        sdk.configure(appKey: "k", userId: "u1", baseUrl: "https://mysuperwall.com", locale: "en", country: nil)
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })
        sdk.setProductData([:])
        XCTAssertTrue(waitUntil { StubURLProtocol.bodies.count == 2 }, "a waiting caller needs a real manifest")
    }

    // MARK: Prewarm policy

    func testPrewarmReuseRequiresSamePaywallAndHtml() {
        let prepared = PaywallData(id: "pw1", name: "n", html: "<a/>", triggerKey: "main", abVariant: "A")
        XCTAssertTrue(PrewarmPolicy.canReuse(prepared: prepared,
            for: PaywallData(id: "pw1", name: "n", html: "<a/>", triggerKey: "other", abVariant: "B")))
        XCTAssertFalse(PrewarmPolicy.canReuse(prepared: prepared, for: PaywallData(id: "pw2", name: "n", html: "<a/>")))
        XCTAssertFalse(PrewarmPolicy.canReuse(prepared: prepared, for: PaywallData(id: "pw1", name: "n", html: "<b/>")),
                       "new language or prices re-render the HTML")
    }
}

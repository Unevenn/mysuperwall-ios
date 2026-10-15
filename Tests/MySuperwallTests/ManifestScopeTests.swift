import XCTest
@testable import MySuperwall

final class ManifestScopeTests: XCTestCase {
    private func scope(base: String = "https://mysuperwall.com/", key: String? = "k", app: String? = "com.app",
                       platform: String = "ios", lang: String = "en") -> ManifestScope {
        ManifestScope(baseURL: base, appKey: key, appIdentifier: app, platform: platform, lang: lang)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: Cache key

    func testCacheKeyIsolatesEveryDimension() {
        let base = scope().cacheKey
        XCTAssertNotEqual(base, scope(base: "https://staging.mysuperwall.com/").cacheKey)
        XCTAssertNotEqual(base, scope(key: "other").cacheKey)
        XCTAssertNotEqual(base, scope(app: "com.other").cacheKey)
        XCTAssertNotEqual(base, scope(platform: "android").cacheKey)
        XCTAssertNotEqual(base, scope(lang: "tr").cacheKey)
    }

    func testCacheKeyIsNotAmbiguousAcrossFieldBoundaries() {
        XCTAssertNotEqual(scope(key: "ab", app: "c").cacheKey, scope(key: "a", app: "bc").cacheKey)
        XCTAssertNotEqual(scope(key: "a:b", app: "c").cacheKey, scope(key: "a", app: "b:c").cacheKey)
    }

    func testCacheKeyNormalizesBaseURLAndHidesSecrets() {
        XCTAssertEqual(scope(base: "HTTPS://MySuperwall.com:443").cacheKey, scope(base: "https://mysuperwall.com/").cacheKey)
        let key = scope(key: "super-secret-app-key").cacheKey
        XCTAssertFalse(key.contains("super-secret"))
        XCTAssertTrue(key.hasPrefix("mysuperwall_manifest_v2_"))
        XCTAssertEqual(key.count, "mysuperwall_manifest_v2_".count + 64)
    }

    // MARK: Locale

    func testLanguageNormalization() {
        XCTAssertEqual(LocaleSupport.normalizeLanguage("pt-BR"), "pt-br")
        XCTAssertEqual(LocaleSupport.normalizeLanguage("EN_us"), "en-us")
        XCTAssertEqual(LocaleSupport.normalizeLanguage(" tr "), "tr")
        XCTAssertNil(LocaleSupport.normalizeLanguage(""))
        XCTAssertNil(LocaleSupport.normalizeLanguage("1"))
        XCTAssertNil(LocaleSupport.normalizeLanguage("english-us"))
        XCTAssertEqual(LocaleSupport.normalizeCountry("us"), "US")
        XCTAssertNil(LocaleSupport.normalizeCountry("USA"))
    }

    // MARK: Disk isolation

    func testLegacyUnscopedCacheIsNeverLoaded() throws {
        let defaults = freshDefaults("scope.legacy")
        defaults.set(manifestJSON(hash: "legacy"), forKey: "mysuperwall_cached_manifest_v1")
        let service = ManifestService(userDefaults: defaults, session: StubURLProtocol.session())
        service.activate(scope: scope())
        XCTAssertNil(service.manifest)
        XCTAssertNil(service.loadFromDisk())
    }

    func testScopeChangeClearsMemoryAndLoadsOnlyItsOwnEntry() {
        let defaults = freshDefaults("scope.switch")
        let service = ManifestService(userDefaults: defaults, session: StubURLProtocol.session())
        let en = scope(lang: "en"), tr = scope(lang: "tr")

        service.activate(scope: en)
        service.saveToDisk(PaywallManifest(ok: true, hash: "en-hash"))
        XCTAssertEqual(service.manifest?.hash, "en-hash")

        XCTAssertTrue(service.activate(scope: tr))
        XCTAssertNil(service.manifest, "previous language must not leak into the new scope")

        service.saveToDisk(PaywallManifest(ok: true, hash: "tr-hash"))
        service.activate(scope: en)
        XCTAssertEqual(service.manifest?.hash, "en-hash")
        XCTAssertFalse(service.activate(scope: en), "same scope is a no-op")
    }

    // MARK: Network

    func testSyncSendsLangAndScopeFields() {
        let service = ManifestService(userDefaults: freshDefaults("scope.body"), session: StubURLProtocol.session())
        service.syncInBackground(baseUrl: "https://mysuperwall.com/", appKey: "k", bundleId: "com.app", lang: "tr")
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })
        let body = StubURLProtocol.bodies[0]
        XCTAssertEqual(body["lang"] as? String, "tr")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["bundleId"] as? String, "com.app")
    }

    func testSyncDefaultsToDeviceLanguage() {
        let service = ManifestService(userDefaults: freshDefaults("scope.devlang"), session: StubURLProtocol.session())
        service.syncInBackground(baseUrl: "https://mysuperwall.com/", appKey: "k", bundleId: "com.app")
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })
        XCTAssertEqual(StubURLProtocol.bodies[0]["lang"] as? String, LocaleSupport.deviceLanguage())
    }

    func testStaleResponseAfterScopeChangeIsDiscardedAndNotPersisted() {
        let defaults = freshDefaults("scope.stale")
        let service = ManifestService(userDefaults: defaults, session: StubURLProtocol.session())
        let done = expectation(description: "completion")
        var outcome: Result<PaywallManifest?, Error>?

        service.syncInBackground(baseUrl: "https://mysuperwall.com/", appKey: "k", bundleId: "com.app", lang: "en") {
            outcome = $0; done.fulfill()
        }
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })

        // Scope changes while the English request is in flight.
        service.activate(scope: scope(lang: "tr"))
        StubURLProtocol.respondNext(body: manifestJSON(hash: "english"))
        wait(for: [done], timeout: 3)

        if case .success = outcome! { XCTFail("stale response must not complete successfully") }
        XCTAssertNil(service.manifest)
        XCTAssertNil(defaults.data(forKey: scope(lang: "en").cacheKey), "stale write reached disk")
        XCTAssertNil(defaults.data(forKey: scope(lang: "tr").cacheKey))
    }

    func testStale304DoesNotDeliverOtherScopesManifest() {
        let defaults = freshDefaults("scope.stale304")
        let service = ManifestService(userDefaults: defaults, session: StubURLProtocol.session())
        service.activate(scope: scope(lang: "en"))
        service.saveToDisk(PaywallManifest(ok: true, hash: "en-hash"))

        let done = expectation(description: "completion")
        var outcome: Result<PaywallManifest?, Error>?
        service.syncInBackground(baseUrl: "https://mysuperwall.com/", appKey: "k", bundleId: "com.app", lang: "en") {
            outcome = $0; done.fulfill()
        }
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })
        service.activate(scope: scope(lang: "tr"))
        StubURLProtocol.respondNext(status: 304)
        wait(for: [done], timeout: 3)

        if case .success = outcome! { XCTFail("stale 304 must not report success") }
        XCTAssertNil(service.manifest)
    }

    func testCurrentScopeResponseIsAppliedAndPersistedUnderItsKey() {
        let defaults = freshDefaults("scope.ok")
        let service = ManifestService(userDefaults: defaults, session: StubURLProtocol.session())
        let done = expectation(description: "completion")
        service.syncInBackground(baseUrl: "https://mysuperwall.com/", appKey: "k", bundleId: "com.app", lang: "tr") { _ in
            done.fulfill()
        }
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })
        StubURLProtocol.respondNext(body: manifestJSON(hash: "turkish"))
        wait(for: [done], timeout: 3)

        XCTAssertEqual(service.manifest?.hash, "turkish")
        let key = scope(lang: "tr").cacheKey
        XCTAssertNotNil(defaults.data(forKey: key))
        XCTAssertNil(defaults.data(forKey: scope(lang: "en").cacheKey))
    }

    // MARK: MySuperwall facade

    func testSetLocaleReloadsOwnCacheAndRefreshesInBackground() {
        let defaults = freshDefaults("scope.facade")
        let service = ManifestService(userDefaults: defaults, session: StubURLProtocol.session())
        let sdk = MySuperwall(manifestService: service,
                              eventQueue: OfflineEventQueue(userDefaults: defaults, session: StubURLProtocol.session()),
                              userDefaults: defaults, bundleIdentifier: "com.app")
        let en = ManifestScope(baseURL: "https://mysuperwall.com/", appKey: "k", appIdentifier: "com.app", platform: "ios", lang: "en")
        let tr = ManifestScope(baseURL: "https://mysuperwall.com/", appKey: "k", appIdentifier: "com.app", platform: "ios", lang: "tr")
        defaults.set(try! JSONEncoder().encode(PaywallManifest(ok: true, hash: "cached-tr")), forKey: tr.cacheKey)
        defaults.set(try! JSONEncoder().encode(PaywallManifest(ok: true, hash: "cached-en")), forKey: en.cacheKey)

        sdk.configure(appKey: "k", userId: "u1", baseUrl: "https://mysuperwall.com", locale: "en", country: "DE")
        XCTAssertEqual(service.manifest?.hash, "cached-en")
        XCTAssertEqual(sdk.country, "DE")
        XCTAssertTrue(waitUntil { StubURLProtocol.pendingCount == 1 })

        sdk.setLocale("tr")
        XCTAssertEqual(service.manifest?.hash, "cached-tr")
        XCTAssertEqual(sdk.lang, "tr")
        XCTAssertEqual(sdk.country, "DE", "country is independent of language")
        XCTAssertTrue(waitUntil { StubURLProtocol.bodies.last?["lang"] as? String == "tr" })

        sdk.setLocale("1-invalid")
        XCTAssertEqual(sdk.lang, LocaleSupport.deviceLanguage())
    }

    func testReconfigureWithDifferentAppKeyDropsPreviousManifest() {
        let defaults = freshDefaults("scope.reinit")
        let service = ManifestService(userDefaults: defaults, session: StubURLProtocol.session())
        let sdk = MySuperwall(manifestService: service,
                              eventQueue: OfflineEventQueue(userDefaults: defaults, session: StubURLProtocol.session()),
                              userDefaults: defaults, bundleIdentifier: "com.app")
        sdk.configure(appKey: "A", userId: "u", baseUrl: "https://mysuperwall.com/", locale: "en", country: nil)
        service.saveToDisk(PaywallManifest(ok: true, hash: "app-A"))
        sdk.configure(appKey: "B", userId: "u", baseUrl: "https://mysuperwall.com/", locale: "en", country: nil)
        XCTAssertNil(service.manifest)
    }
}

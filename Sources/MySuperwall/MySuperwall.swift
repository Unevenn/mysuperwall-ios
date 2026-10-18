import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class MySuperwall {
    public static let shared = MySuperwall()

    private let stateLock = NSLock()
    private var _productData: [String: Any] = [:]
    private var _appKey: String?
    private var _userId: String?
    private var _baseUrl: String = "https://mysuperwall.com/"
    private var _userAttributes: [String: Any] = [:]
    private var _lang: String = LocaleSupport.deviceLanguage()
    private var _countryOverride: String?
    private var _subscriptionStatus: SubscriptionStatus = .unknown
    private var _isConfigured = false
    private var _paywallStates: [String: PaywallState] = [:]
    private var _presentationPending = false
    private var _configurationGeneration = 0
    public var onPaywallStateChanged: ((String, PaywallState) -> Void)?
    public var logLevel: MySuperwallLogLevel {
        get { MySuperwallLogging.level }
        set { MySuperwallLogging.level = newValue }
    }
    public func paywallState(for triggerKey: String) -> PaywallState {
        locked { _paywallStates[triggerKey] ?? .idle }
    }
    func updatePaywallState(_ paywall: PaywallData, _ state: PaywallState) {
        if let scope = paywall.attributionScope, scope != manifestService.scope?.cacheKey { return }
        if let user = paywall.attributionUserId, user != userId { return }
        let key = paywall.triggerKey ?? paywall.id
        let changed = locked { () -> Bool in
            guard _isConfigured, _paywallStates[key] != state else { return false }
            _paywallStates[key] = state
            return true
        }
        if changed {
            DispatchQueue.main.async { [weak self] in self?.onPaywallStateChanged?(key, state) }
        }
    }

    public func dispose() {
        #if canImport(UIKit)
        onMain { self.prewarmTarget = nil; self.releasePrewarmedController() }
        #endif
        followUps.reset()
        manifestService.dispose()
        eventQueue.cancelPending()
        locked { _configurationGeneration += 1; _isConfigured = false; _paywallStates.removeAll(); _presentationPending = false }
        #if canImport(UIKit)
        DispatchQueue.main.async { [weak self] in
            self?.activeController?.dismiss(animated: false)
            self?.activeController = nil
        }
        #endif
        onPaywallStateChanged = nil
    }

    public var appKey: String? { locked { _appKey } }
    public var userId: String? { locked { _userId } }
    private var baseUrl: String { locked { _baseUrl } }
    public var userAttributes: [String: Any] { locked { _userAttributes } }
    /// Language used for the manifest request and cache scope (e.g. "en").
    public var lang: String { locked { _lang } }
    /// Country used for audience rules: the explicit override, else the device region.
    public var country: String? { locked { _countryOverride } ?? LocaleSupport.deviceCountry() }
    public var subscriptionStatus: SubscriptionStatus { locked { _subscriptionStatus } }

    public let manifestService: ManifestService
    public let ruleEngine: LocalRuleEngine
    public let eventQueue: OfflineEventQueue

    private let userDefaults: UserDefaults
    private let bundleIdentifier: String?
    private(set) var followUps: FollowUpController!

    init(
        manifestService: ManifestService = ManifestService(),
        ruleEngine: LocalRuleEngine = LocalRuleEngine(),
        eventQueue: OfflineEventQueue = OfflineEventQueue(),
        userDefaults: UserDefaults = .standard,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        followUpScheduler: ((TimeInterval, @escaping () -> Void) -> () -> Void)? = nil
    ) {
        self.manifestService = manifestService
        self.ruleEngine = ruleEngine
        self.eventQueue = eventQueue
        self.userDefaults = userDefaults
        self.bundleIdentifier = bundleIdentifier

        var env = FollowUpController.Environment(
            manifest: { [weak manifestService] in manifestService?.manifest },
            isPremium: { [weak self] in self?.subscriptionStatus == .active },
            userId: { [weak self] in self?.userId },
            resolveTrigger: { [weak self] key in
                self?.resolveTrigger(triggerKey: key) ?? PaywallResult(show: false)
            }
        )
        if let scheduler = followUpScheduler { env.schedule = scheduler }
        self.followUps = FollowUpController(environment: env)
        #if canImport(UIKit)
        manifestService.onManifestChange = { [weak self] in self?.schedulePrewarmRefresh() }
        #endif
    }

    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body()
    }

    /// Initializes MySuperwall with an instant disk load of this scope's cache and a background sync.
    /// Calling it again re-scopes safely: stale in-memory data is dropped and in-flight work is ignored.
    /// Call it once at startup with the app's language; that is the intended way to set the locale.
    /// - Parameters:
    ///   - locale: explicit language (e.g. "tr", "pt-BR"); defaults to the device language.
    ///   - country: optional region override for audience rules; never affects the language.
    public static func initialize(
        appKey: String? = nil,
        userId: String? = nil,
        locale: String? = nil,
        country: String? = nil,
        logLevel: MySuperwallLogLevel = .warning
    ) {
        MySuperwallLogging.level = logLevel
        shared.configure(appKey: appKey, userId: userId, baseUrl: "https://mysuperwall.com/", locale: locale, country: country)
    }

    func configure(appKey: String?, userId: String?, baseUrl: String, locale: String?, country: String?) {
        let resolvedUser: String
        if let uid = userId, !uid.isEmpty {
            resolvedUser = uid
        } else if let cached = userDefaults.string(forKey: "mysuperwall_user_id_v1") {
            resolvedUser = cached
        } else {
            resolvedUser = UUID().uuidString
            userDefaults.set(resolvedUser, forKey: "mysuperwall_user_id_v1")
        }

        stateLock.lock()
        let userChanged = _userId != resolvedUser
        _productData = [:]
        _appKey = appKey
        _baseUrl = baseUrl.hasSuffix("/") ? baseUrl : "\(baseUrl)/"
        _userId = resolvedUser
        _lang = LocaleSupport.normalizeLanguage(locale) ?? LocaleSupport.deviceLanguage()
        _countryOverride = LocaleSupport.normalizeCountry(country)
        _isConfigured = true
        _configurationGeneration += 1
        if userChanged { _subscriptionStatus = .unknown }
        let scope = makeScopeLocked()
        stateLock.unlock()

        // 1. Switch scope: clears memory first, then loads only this scope's disk entry.
        let scopeChanged = manifestService.activate(scope: scope)
        if scopeChanged || userChanged { followUps.reset() }

        // 2. Background sync with ETag / 304 validation.
        syncManifest(scope: scope)
    }

    private func makeScopeLocked() -> ManifestScope {
        ManifestScope(baseURL: _baseUrl, appKey: _appKey, appIdentifier: bundleIdentifier,
                      platform: "ios", lang: _lang, priceFingerprint: ManifestScope.fingerprint(_productData))
    }

    private func syncManifest(scope: ManifestScope) {
        manifestService.syncInBackground(baseUrl: baseUrl, appKey: appKey, bundleId: bundleIdentifier, lang: scope.lang, substitutionData: locked { _productData })
    }

    /// Re-renders cached paywalls with localized store product prices. Call it once when the
    /// store prices load (not before every presentation). Wait for completion before presenting
    /// on a first installation; this SDK does not fetch billing products itself.
    /// Unchanged products are a no-op: no request is made and `completion` receives the
    /// current manifest.
    public func setProductData(_ products: [String: Any], completion: ((Result<PaywallManifest?, Error>) -> Void)? = nil) {
        guard JSONSerialization.isValidJSONObject(products),
              let data = try? JSONSerialization.data(withJSONObject: products),
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion?(.failure(URLError(.cannotDecodeContentData))); return
        }
        stateLock.lock()
        let unchanged = ManifestScope.fingerprint(snapshot) == ManifestScope.fingerprint(_productData)
        _productData = snapshot
        let scope = makeScopeLocked()
        let url = _baseUrl, key = _appKey
        stateLock.unlock()
        // Skip only when the active scope already serves this exact payload with its own manifest;
        // with nothing cached yet, a sync is still needed for the caller awaiting completion.
        if unchanged, manifestService.scope == scope, !manifestService.isServingProvisionalManifest,
           let current = manifestService.manifest {
            completion?(.success(current)); return
        }
        manifestService.activate(scope: scope)
        manifestService.syncInBackground(baseUrl: url, appKey: key, bundleId: bundleIdentifier,
            lang: scope.lang, substitutionData: snapshot, completion: completion)
    }

    /// Changes the manifest language at runtime (prefer `initialize(locale:)` at startup).
    /// Pending follow-ups are cancelled, the cache for the new language is loaded, and a
    /// background refresh starts. `nil` (or an unparseable value) restores the device language.
    /// A bare language already covered by the current one ("tr" while "tr-tr" is active) is a
    /// no-op; a regional variant of the same language keeps the current paywalls until the
    /// refresh completes. A different language never shows the previous language's paywalls.
    public func setLocale(_ locale: String?) {
        stateLock.lock()
        let requested = LocaleSupport.normalizeLanguage(locale) ?? LocaleSupport.deviceLanguage()
        let resolved = LocaleSupport.isSatisfied(requested: requested, by: _lang) ? _lang : requested
        guard resolved != _lang else { stateLock.unlock(); return }
        _lang = resolved
        let configured = _isConfigured
        let scope = makeScopeLocked()
        stateLock.unlock()

        guard configured else { return }
        followUps.reset()
        manifestService.activate(scope: scope)
        syncManifest(scope: scope)
    }

    /// Overrides the country used for audience rules (ISO 3166-1 alpha-2). `nil` restores the
    /// device region. Does not change the language or the manifest cache scope.
    public func setCountry(_ country: String?) {
        stateLock.lock()
        _countryOverride = LocaleSupport.normalizeCountry(country)
        stateLock.unlock()
    }

    /// Host-reported entitlement, consulted by follow-up rules with `skipIfPremium`. Reset to
    /// `.unknown` whenever the user identity changes.
    public func setSubscriptionStatus(_ status: SubscriptionStatus) {
        stateLock.lock()
        _subscriptionStatus = status
        stateLock.unlock()
    }

    /// Set authenticated or persistent user ID
    public func identify(userId: String) {
        stateLock.lock()
        let changed = _userId != userId
        _userId = userId
        if changed { _subscriptionStatus = .unknown }
        stateLock.unlock()
        userDefaults.set(userId, forKey: "mysuperwall_user_id_v1")
        if changed {
            followUps.reset()
            #if canImport(UIKit)
            schedulePrewarmRefresh()
            #endif
        }
    }

    /// Set persistent custom user attributes for audience rule evaluation
    public func setUserAttributes(_ attributes: [String: Any]) {
        stateLock.lock()
        _userAttributes.merge(attributes) { _, new in new }
        stateLock.unlock()
    }

    /// Evaluates rules locally and resolves the paywall result with 0 ms latency.
    public func resolveTrigger(
        triggerKey: String,
        metadata: [String: Any]? = nil
    ) -> PaywallResult {
        guard let manifest = manifestService.manifest,
              let trigger = manifest.findTrigger(triggerKey) else {
            return PaywallResult(show: false, paywall: nil, reason: "manifest_or_trigger_not_found")
        }

        let currentUser = userId
        var evalContext: [String: Any] = [
            "platform": "ios",
            "country": country ?? Locale.current.identifier,
            "lang": lang,
            "metadata": metadata ?? [:],
            "userAttributes": userAttributes
        ]
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            evalContext["appVersion"] = version
        }
        if let meta = metadata {
            evalContext.merge(meta) { _, new in new }
        }

        let resolution = ruleEngine.resolveTrigger(
            trigger: trigger,
            userId: currentUser,
            context: evalContext
        )

        if resolution.isHoldout {
            return PaywallResult(show: false, paywall: nil, reason: "holdout")
        }

        if resolution.show, let paywallId = resolution.paywallId, let manifestPaywall = manifest.paywalls[paywallId] {
            let paywallData = PaywallData(
                id: manifestPaywall.id,
                name: manifestPaywall.name,
                html: manifestPaywall.html,
                productIds: manifestPaywall.productIds,
                products: manifestPaywall.products,
                triggerKey: triggerKey,
                abVariant: resolution.abVariant,
                experimentContext: experimentContext(trigger: trigger, resolution: resolution, paywall: manifestPaywall),
                attributionUserId: currentUser,
                attributionScope: manifestService.scope?.cacheKey
            )

            return PaywallResult(show: true, paywall: paywallData, reason: resolution.reason)
        }

        return PaywallResult(show: false, paywall: nil, reason: resolution.reason)
    }

    private func experimentContext(trigger: ManifestTrigger, resolution: RuleEngineResolution, paywall: ManifestPaywall) -> ExperimentContext? {
        let rule = resolution.matchedRuleId.flatMap { id in trigger.rules.first { $0.id == id } }
        let variants = rule?.variants ?? trigger.variants
        let matches = variants.filter { $0.paywallId == paywall.id && $0.variant == resolution.abVariant }
        guard matches.count == 1, let variant = matches.first,
              let variantId = variant.variantId,
              let experimentId = rule != nil ? rule?.experimentId : trigger.experimentId,
              let version = rule != nil ? rule?.experimentVersion : trigger.experimentVersion,
              let audience = rule != nil ? rule?.audienceId : trigger.audienceId,
              let paywallVersion = paywall.publishedVersion else { return nil }
        return ExperimentContext(experimentId: experimentId, experimentVersion: version,
                                 audienceId: audience, variantId: variantId,
                                 variantLabel: variant.variantLabel ?? variant.variant,
                                 paywallId: paywall.id, paywallVersion: paywallVersion)
    }

    /// Use the displayed paywall, never a freshly resolved assignment.
    ///
    /// Host-confirmed outcomes (`purchase`, `purchase_success`, `purchase_failed`, `restore`,
    /// `restore_success`) additionally arm the matching `followUpRules` entry of the paywall that is
    /// currently shown by the SDK; the follow-up only presents after that paywall is dismissed.
    public func trackPaywallEvent(type: String, paywall: PaywallData, productId: String? = nil) {
        guard locked({ _isConfigured }) else { return }
        if let scope = paywall.attributionScope, scope != manifestService.scope?.cacheKey { return }
        if let user = paywall.attributionUserId, user != userId { return }
        let currentUser = userId
        var event: [String: Any] = ["type": type, "eventId": UUID().uuidString,
                                  "paywallId": paywall.id, "triggerKey": paywall.triggerKey ?? "",
                                  "abVariant": paywall.abVariant ?? "", "userId": currentUser ?? ""]
        if paywall.attributionUserId == currentUser, let context = paywall.experimentContext { event["experimentContext"] = context.dictionary }
        if let productId = productId { event["productId"] = productId }
        eventQueue.enqueue(event: event, scope: ManifestScope(baseURL: baseUrl, appKey: appKey, appIdentifier: bundleIdentifier, platform: "ios", lang: "en"))
        flushEventQueue()
        followUps.recordSignal(type: type, paywall: paywall)
    }

    #if canImport(UIKit)
    private weak var activeController: PaywallWebViewController?

    /// Triggers a paywall event and automatically presents it over the specified controller with 0 ms network wait.
    /// `onDismiss` is invoked exactly once per presented paywall (including automatic follow-ups).
    @discardableResult
    public func handleTrigger(
        presentingController: UIViewController?,
        triggerKey: String,
        metadata: [String: Any]? = nil,
        onPurchase: ((String) -> Void)? = nil,
        onRestore: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        onOpenUrl: ((URL) -> Void)? = nil
    ) -> PaywallResult {
        let reserved = locked { () -> Bool in
            guard _isConfigured, !_presentationPending else { return false }
            _presentationPending = true
            return true
        }
        guard reserved else { return PaywallResult(show: false, reason: "presentation_in_progress") }
        let generation = locked { _configurationGeneration }
        let result = resolveTrigger(triggerKey: triggerKey, metadata: metadata)

        guard result.show, let paywall = result.paywall, let presenter = presentingController else {
            locked { _presentationPending = false }
            return result
        }

        let callbacks = PaywallCallbacks(onPurchase: onPurchase, onRestore: onRestore,
                                         onDismiss: onDismiss, onOpenUrl: onOpenUrl)
        DispatchQueue.main.async { [weak self, weak presenter] in
            guard let self = self else { return }
            guard self.locked({ self._isConfigured && self._configurationGeneration == generation }) else { return }
            guard let presenter = presenter else { self.locked { self._presentationPending = false }; return }
            if !self.present(paywall: paywall, depth: 0, chain: [paywall.id], presenter: presenter, callbacks: callbacks) {
                self.locked { self._presentationPending = false }
            }
        }

        return result
    }

    /// Dismisses the paywall currently shown by the SDK, if any. The normal dismissal path runs
    /// (callback once, pending follow-up evaluated after the UI is gone).
    public func dismissActivePaywall(animated: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            self?.activeController?.dismiss(animated: animated, completion: nil)
        }
    }

    /// Main thread only.
    private func present(paywall: PaywallData, depth: Int, chain: [String],
                         presenter: UIViewController, callbacks: PaywallCallbacks) -> Bool {
        guard locked({ _isConfigured }), Self.isValidHost(presenter),
              activeController?.viewIfLoaded?.window == nil else { return false }
        locked { _presentationPending = true }
        let session = followUps.begin(paywall: paywall, depth: depth, chain: chain)
        let delegate = ClosurePaywallDelegate(callbacks: callbacks) { [weak self, weak presenter] in
            guard let self = self else { return }
            self.activeController = nil
            self.locked { self._presentationPending = false }
            self.schedulePrewarmRefresh()
            self.followUps.sessionDidClose(
                session,
                hostValid: { MySuperwall.isValidHost(presenter) },
                present: { [weak self] next in
                    guard let self = self, let presenter = presenter else { return false }
                    return self.present(paywall: next.paywall, depth: next.depth, chain: next.chain,
                                        presenter: presenter, callbacks: callbacks)
                }
            )
        }
        let warm = takePrewarmedController(for: paywall)
        let controller = warm ?? PaywallWebViewController(paywall: paywall, delegate: delegate)
        // Retain delegate for controller lifecycle
        objc_setAssociatedObject(controller, &MySuperwall.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        activeController = controller
        updatePaywallState(paywall, .presenting)
        warm?.activatePrewarmed(paywall: paywall, delegate: delegate)
        presenter.present(controller, animated: true, completion: nil)
        return true
    }

    // MARK: Prewarm (single slot, main thread only)

    private var prewarmTarget: (triggerKey: String, metadata: [String: Any]?)?
    private var prewarmedController: PaywallWebViewController?
    private var memoryWarningObserver: NSObjectProtocol?
    private var prewarmRefreshScheduled = false

    /// Resolves `triggerKey` now and loads its paywall off-screen, so the next `handleTrigger`
    /// that resolves to the same paywall (same id and rendered HTML) presents instantly.
    /// Call once at startup for the main trigger, after `initialize`. One slot only: a new call
    /// replaces the previous target. The slot is rebuilt automatically after manifest, locale,
    /// product-data or user changes and after the prepared paywall has been shown, and is
    /// released on memory warnings. A stale prepared paywall is never presented.
    public func prewarm(triggerKey: String, metadata: [String: Any]? = nil) {
        onMain {
            self.prewarmTarget = (triggerKey, metadata)
            self.observeMemoryWarnings()
            self.refreshPrewarm()
        }
    }

    /// Drops the prepared paywall and stops rebuilding it.
    public func releasePrewarmedPaywall() {
        onMain { self.prewarmTarget = nil; self.releasePrewarmedController() }
    }

    /// The paywall currently prepared off-screen (main thread; for diagnostics and tests).
    var prewarmedPaywall: PaywallData? { prewarmedController?.paywall }

    func schedulePrewarmRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.prewarmTarget != nil, !self.prewarmRefreshScheduled else { return }
            self.prewarmRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.prewarmRefreshScheduled = false
                self.refreshPrewarm()
            }
        }
    }

    /// Main thread only. Keeps the slot when it still matches the current resolution, otherwise rebuilds it.
    func refreshPrewarm() {
        guard let target = prewarmTarget, locked({ _isConfigured }) else { releasePrewarmedController(); return }
        // Building a second WebView under a visible paywall is wasted memory; refreshed on dismissal.
        guard activeController == nil else { return }
        let result = resolveTrigger(triggerKey: target.triggerKey, metadata: target.metadata)
        guard result.show, let paywall = result.paywall else { releasePrewarmedController(); return }
        if let current = prewarmedController, current.isReusablePrewarm,
           PrewarmPolicy.canReuse(prepared: current.paywall, for: paywall) { return }
        releasePrewarmedController()
        let controller = PaywallWebViewController(paywall: paywall, delegate: nil, prewarmed: true)
        controller.loadViewIfNeeded()
        prewarmedController = controller
    }

    private func takePrewarmedController(for paywall: PaywallData) -> PaywallWebViewController? {
        guard let warm = prewarmedController else { return nil }
        prewarmedController = nil
        guard warm.isReusablePrewarm, PrewarmPolicy.canReuse(prepared: warm.paywall, for: paywall) else {
            return nil // stale or failed: discarded, a fresh controller is built instead
        }
        return warm
    }

    private func releasePrewarmedController() {
        prewarmedController = nil
    }

    private func observeMemoryWarnings() {
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.releasePrewarmedController() }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private static var delegateKey: UInt8 = 0

    /// The old UI must be gone and the host screen must still be on screen and free to present.
    private static func isValidHost(_ presenter: UIViewController?) -> Bool {
        guard let presenter = presenter else { return false }
        return presenter.viewIfLoaded?.window != nil
            && presenter.presentedViewController == nil
            && !presenter.isBeingDismissed
            && !presenter.isBeingPresented
    }
    #endif

    private func flushEventQueue() {
        eventQueue.flush(baseUrl: baseUrl, appKey: appKey, bundleId: bundleIdentifier)
    }
}

#if canImport(UIKit)
private struct PaywallCallbacks {
    let onPurchase: ((String) -> Void)?
    let onRestore: (() -> Void)?
    let onDismiss: (() -> Void)?
    let onOpenUrl: ((URL) -> Void)?
}

private final class ClosurePaywallDelegate: PaywallDelegate {
    private let callbacks: PaywallCallbacks
    private let onClosed: () -> Void

    init(callbacks: PaywallCallbacks, onClosed: @escaping () -> Void) {
        self.callbacks = callbacks
        self.onClosed = onClosed
    }

    func paywallDidRequestPurchase(productId: String) {
        callbacks.onPurchase?(productId)
    }

    func paywallDidRequestRestore() {
        callbacks.onRestore?()
    }

    func paywallDidDismiss() {
        callbacks.onDismiss?()
        onClosed()
    }

    func paywallDidOpenUrl(url: URL) {
        callbacks.onOpenUrl?(url)
    }
}
#endif

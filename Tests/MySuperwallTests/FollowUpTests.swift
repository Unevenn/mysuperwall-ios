import XCTest
@testable import MySuperwall

final class FollowUpTests: XCTestCase {
    // MARK: Harness

    final class Clock { var now = Date(timeIntervalSince1970: 1_000) }

    final class ManualScheduler {
        struct Job { let delay: TimeInterval; let work: () -> Void; var cancelled = false }
        var jobs: [Job] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
            jobs.append(Job(delay: delay, work: work))
            let index = jobs.count - 1
            return { [unowned self] in self.jobs[index].cancelled = true }
        }
        /// Runs every job that has not been cancelled.
        func runAll() {
            let pending = jobs
            jobs.removeAll()
            for job in pending where !job.cancelled { job.work() }
        }
        var liveCount: Int { jobs.filter { !$0.cancelled }.count }
    }

    var manifest: PaywallManifest!
    var premium = false
    var userId: String? = "u1"
    var scheduler: ManualScheduler!
    var clock: Clock!
    var controller: FollowUpController!
    var presented: [FollowUpPresentation] = []
    var hostIsValid = true

    func rule(_ trigger: String? = "t_follow", enabled: Bool = true, delayMs: Int = 0, once: Bool = false,
              cooldownMs: Int = 0, depth: Int = 1, skipPremium: Bool = false, prevent: Bool = true,
              actionType: String = "trigger") -> ManifestFollowUpRule {
        ManifestFollowUpRule(enabled: enabled, actionType: actionType, triggerKey: trigger, delayMs: delayMs,
                             oncePerSession: once, cooldownMs: cooldownMs, maxChainDepth: depth,
                             skipIfPremium: skipPremium, preventRepeatPaywall: prevent)
    }

    func paywall(_ id: String, rules: [String: ManifestFollowUpRule] = [:]) -> ManifestPaywall {
        ManifestPaywall(id: id, name: id, templateKey: "t", html: "<html/>", followUpRules: rules)
    }

    func trigger(_ key: String, paywall: String, dismiss: ManifestDismissAction? = nil) -> ManifestTrigger {
        ManifestTrigger(id: "id_\(key)", key: key, paywallId: paywall, dismissAction: dismiss)
    }

    func makeController(paywalls: [ManifestPaywall], triggers: [ManifestTrigger]) {
        manifest = PaywallManifest(ok: true, hash: "h", triggers: triggers,
                                   paywalls: Dictionary(uniqueKeysWithValues: paywalls.map { ($0.id, $0) }))
        scheduler = ManualScheduler()
        clock = Clock()
        presented = []
        let engine = LocalRuleEngine()
        var env = FollowUpController.Environment(
            manifest: { [unowned self] in self.manifest },
            isPremium: { [unowned self] in self.premium },
            userId: { [unowned self] in self.userId },
            resolveTrigger: { [unowned self] key in
                guard let t = self.manifest.findTrigger(key) else { return PaywallResult(show: false) }
                let res = engine.resolveTrigger(trigger: t, userId: self.userId, context: [:])
                guard res.show, let id = res.paywallId, let p = self.manifest.paywalls[id] else {
                    return PaywallResult(show: false, reason: res.reason)
                }
                // Mirrors MySuperwall.resolveTrigger, including real experiment attribution.
                let ctx = ExperimentContext(experimentId: "e", experimentVersion: "1", audienceId: "a",
                                            variantId: "v", variantLabel: "A", paywallId: p.id, paywallVersion: 1)
                return PaywallResult(show: true, paywall: PaywallData(
                    id: p.id, name: p.name, html: p.html, triggerKey: key, abVariant: "A",
                    experimentContext: ctx, attributionUserId: self.userId))
            }
        )
        env.now = { [unowned self] in self.clock.now }
        env.schedule = { [unowned self] d, w in self.scheduler.schedule(d, w) }
        controller = FollowUpController(environment: env)
    }

    func shown(_ id: String, trigger: String) -> PaywallData {
        PaywallData(id: id, name: id, html: "<html/>", triggerKey: trigger, abVariant: "B", attributionUserId: userId)
    }

    @discardableResult
    func open(_ id: String, trigger: String, depth: Int = 0, chain: [String]? = nil) -> FollowUpSession {
        controller.begin(paywall: shown(id, trigger: trigger), depth: depth, chain: chain)
    }

    func close(_ s: FollowUpSession) {
        controller.sessionDidClose(s, hostValid: { [unowned self] in self.hostIsValid },
                                   present: { [unowned self] p in self.presented.append(p); return true })
        scheduler.runAll()
    }

    override func setUp() {
        super.setUp()
        premium = false
        userId = "u1"
        hostIsValid = true
    }

    // MARK: Legacy root dismissAction

    func testLegacyDismissActionPresentsFollowUpOnceAfterActualClose() {
        let legacy = ManifestDismissAction(type: "follow_up_paywall", followUpPaywallId: "pw_b")
        makeController(paywalls: [paywall("pw_a"), paywall("pw_b")], triggers: [trigger("main", paywall: "pw_a", dismiss: legacy)])
        let s = open("pw_a", trigger: "main")
        XCTAssertTrue(presented.isEmpty, "nothing may present while the first paywall is still up")
        close(s)
        controller.sessionDidClose(s, hostValid: { true }, present: { [unowned self] p in self.presented.append(p); return true })
        scheduler.runAll()

        XCTAssertEqual(presented.count, 1, "close is processed once")
        XCTAssertEqual(presented[0].paywall.id, "pw_b")
        XCTAssertNil(presented[0].paywall.abVariant)
        XCTAssertNil(presented[0].paywall.experimentContext)
        XCTAssertEqual(presented[0].paywall.attributionUserId, "u1", "user binding retained")
        XCTAssertEqual(presented[0].depth, 1)
    }

    func testLegacyNeverRepeatsSamePaywallAndNeverChains() {
        let legacy = ManifestDismissAction(type: "follow_up_paywall", followUpPaywallId: "pw_a")
        makeController(paywalls: [paywall("pw_a")], triggers: [trigger("main", paywall: "pw_a", dismiss: legacy)])
        close(open("pw_a", trigger: "main"))
        XCTAssertTrue(presented.isEmpty, "same paywall must not repeat")

        let chain = ManifestDismissAction(type: "follow_up_paywall", followUpPaywallId: "pw_b")
        makeController(paywalls: [paywall("pw_a"), paywall("pw_b")], triggers: [trigger("main", paywall: "pw_a", dismiss: chain)])
        close(open("pw_b", trigger: "main", depth: 1, chain: ["pw_a", "pw_b"]))
        XCTAssertTrue(presented.isEmpty, "legacy fallback applies to the root presentation only")
    }

    func testNoFollowUpWhenActionTypeIsNone() {
        makeController(paywalls: [paywall("pw_a")], triggers: [trigger("main", paywall: "pw_a", dismiss: ManifestDismissAction())])
        close(open("pw_a", trigger: "main"))
        XCTAssertTrue(presented.isEmpty)
    }

    // MARK: Explicit rules

    func testExplicitRuleTakesPrecedenceOverLegacy() {
        let legacy = ManifestDismissAction(type: "follow_up_paywall", followUpPaywallId: "pw_legacy")
        makeController(
            paywalls: [paywall("pw_a", rules: ["onDismiss": rule("t_follow")]), paywall("pw_legacy"), paywall("pw_rule")],
            triggers: [trigger("main", paywall: "pw_a", dismiss: legacy), trigger("t_follow", paywall: "pw_rule")])
        close(open("pw_a", trigger: "main"))
        XCTAssertEqual(presented.map { $0.paywall.id }, ["pw_rule"])
        XCTAssertEqual(presented[0].paywall.triggerKey, "t_follow")
        XCTAssertNil(presented[0].paywall.experimentContext, "no false A/B attribution on follow-ups")
        XCTAssertNil(presented[0].paywall.abVariant)
    }

    func testDisabledOrUnsupportedRuleFallsBackAsExpected() {
        let legacy = ManifestDismissAction(type: "follow_up_paywall", followUpPaywallId: "pw_legacy")
        // Disabled explicit rule -> legacy applies.
        makeController(
            paywalls: [paywall("pw_a", rules: ["onDismiss": rule(enabled: false)]), paywall("pw_legacy")],
            triggers: [trigger("main", paywall: "pw_a", dismiss: legacy)])
        close(open("pw_a", trigger: "main"))
        XCTAssertEqual(presented.map { $0.paywall.id }, ["pw_legacy"])

        // Enabled rule with unsupported actionType -> nothing (explicit still wins, no silent legacy).
        makeController(
            paywalls: [paywall("pw_a", rules: ["onDismiss": rule(actionType: "url")]), paywall("pw_legacy")],
            triggers: [trigger("main", paywall: "pw_a", dismiss: legacy)])
        close(open("pw_a", trigger: "main"))
        XCTAssertTrue(presented.isEmpty)
    }

    func testDelayIsHonouredAndCancelledOnReset() {
        makeController(
            paywalls: [paywall("pw_a", rules: ["onDismiss": rule(delayMs: 1500)]), paywall("pw_f")],
            triggers: [trigger("main", paywall: "pw_a"), trigger("t_follow", paywall: "pw_f")])
        let s = open("pw_a", trigger: "main")
        controller.sessionDidClose(s, hostValid: { true }, present: { [unowned self] p in self.presented.append(p); return true })
        XCTAssertEqual(scheduler.jobs.first?.delay, 1.5)
        XCTAssertEqual(scheduler.liveCount, 1)

        controller.reset() // identity / scope / locale change
        XCTAssertEqual(scheduler.liveCount, 0)
        scheduler.runAll()
        XCTAssertTrue(presented.isEmpty)
    }

    func testStaleCallbackAfterResetCannotPresentEvenIfWorkStillRuns() {
        makeController(
            paywalls: [paywall("pw_a", rules: ["onDismiss": rule(delayMs: 10)]), paywall("pw_f")],
            triggers: [trigger("main", paywall: "pw_a"), trigger("t_follow", paywall: "pw_f")])
        let s = open("pw_a", trigger: "main")
        controller.sessionDidClose(s, hostValid: { true }, present: { [unowned self] p in self.presented.append(p); return true })
        let work = scheduler.jobs[0].work
        controller.reset()
        work() // simulates a callback that was already dequeued
        XCTAssertTrue(presented.isEmpty)

        // A session opened before the reset can't present after it either.
        let old = open("pw_a", trigger: "main")
        controller.reset()
        controller.sessionDidClose(old, hostValid: { true }, present: { [unowned self] p in self.presented.append(p); return true })
        scheduler.runAll()
        XCTAssertTrue(presented.isEmpty)
    }

    func testOncePerSessionAndCooldown() {
        makeController(
            paywalls: [paywall("pw_a", rules: ["onDismiss": rule(once: true)]), paywall("pw_f")],
            triggers: [trigger("main", paywall: "pw_a"), trigger("t_follow", paywall: "pw_f")])
        close(open("pw_a", trigger: "main"))
        close(open("pw_a", trigger: "main"))
        XCTAssertEqual(presented.count, 1, "oncePerSession")
        controller.reset()
        close(open("pw_a", trigger: "main"))
        XCTAssertEqual(presented.count, 2, "a new session (after reset) may fire again")

        makeController(
            paywalls: [paywall("pw_a", rules: ["onDismiss": rule(cooldownMs: 60_000)]), paywall("pw_f")],
            triggers: [trigger("main", paywall: "pw_a"), trigger("t_follow", paywall: "pw_f")])
        close(open("pw_a", trigger: "main"))
        clock.now.addTimeInterval(30)
        close(open("pw_a", trigger: "main"))
        XCTAssertEqual(presented.count, 1, "inside cooldown")
        clock.now.addTimeInterval(31)
        close(open("pw_a", trigger: "main"))
        XCTAssertEqual(presented.count, 2, "after cooldown")
    }

    func testSkipIfPremiumIsEvaluatedWhenTheFollowUpFires() {
        makeController(
            paywalls: [paywall("pw_a", rules: ["onDismiss": rule(delayMs: 100, skipPremium: true)]), paywall("pw_f")],
            triggers: [trigger("main", paywall: "pw_a"), trigger("t_follow", paywall: "pw_f")])
        let s = open("pw_a", trigger: "main")
        controller.sessionDidClose(s, hostValid: { true }, present: { [unowned self] p in self.presented.append(p); return true })
        premium = true // host reports the entitlement during the delay
        scheduler.runAll()
        XCTAssertTrue(presented.isEmpty)
    }

    func testChainDepthIsLimitedAndRepeatsPrevented() {
        makeController(
            paywalls: [paywall("pw_a", rules: ["onDismiss": rule("t_b", depth: 2)]),
                       paywall("pw_b", rules: ["onDismiss": rule("t_c", depth: 2)]),
                       paywall("pw_c", rules: ["onDismiss": rule("t_a", depth: 2)])],
            triggers: [trigger("main", paywall: "pw_a"), trigger("t_b", paywall: "pw_b"),
                       trigger("t_c", paywall: "pw_c"), trigger("t_a", paywall: "pw_a")])
        close(open("pw_a", trigger: "main"))
        XCTAssertEqual(presented.last?.paywall.id, "pw_b")
        let second = presented[0]
        close(open("pw_b", trigger: "t_b", depth: second.depth, chain: second.chain))
        XCTAssertEqual(presented.last?.paywall.id, "pw_c")
        let third = presented[1]
        XCTAssertEqual(third.depth, 2)
        close(open("pw_c", trigger: "t_c", depth: third.depth, chain: third.chain))
        XCTAssertEqual(presented.count, 2, "depth 3 exceeds maxChainDepth 2 (and would repeat pw_a)")
    }

    func testHostNoLongerValidSkipsPresentation() {
        makeController(
            paywalls: [paywall("pw_a", rules: ["onDismiss": rule()]), paywall("pw_f")],
            triggers: [trigger("main", paywall: "pw_a"), trigger("t_follow", paywall: "pw_f")])
        hostIsValid = false
        close(open("pw_a", trigger: "main"))
        XCTAssertTrue(presented.isEmpty)
    }

    func testFollowUpWithHoldoutOrMissingTriggerDoesNothing() {
        makeController(
            paywalls: [paywall("pw_a", rules: ["onDismiss": rule("missing")])],
            triggers: [trigger("main", paywall: "pw_a")])
        close(open("pw_a", trigger: "main"))
        XCTAssertTrue(presented.isEmpty)
    }

    // MARK: Purchase / restore signals

    func testButtonTapEventsDoNotArmPurchaseFollowUps() {
        for type in ["purchase_started", "restore_started", "paywall_shown", "paywall_dismissed", "purchase_cancelled"] {
            XCTAssertNil(FollowUpEvent.fromTrackedType(type), type)
        }
        for type in ["purchase", "purchase_success", "purchase_failed", "restore", "restore_success", "PURCHASE_SUCCESS"] {
            XCTAssertNotNil(FollowUpEvent.fromTrackedType(type), type)
        }
    }

    func testPurchaseSignalWaitsForActualDismissalThenUsesOnPurchaseRule() {
        makeController(
            paywalls: [paywall("pw_a", rules: ["onPurchase": rule("t_thanks"), "onDismiss": rule("t_win_back")]),
                       paywall("pw_thanks"), paywall("pw_win")],
            triggers: [trigger("main", paywall: "pw_a"), trigger("t_thanks", paywall: "pw_thanks"),
                       trigger("t_win_back", paywall: "pw_win")])
        let s = open("pw_a", trigger: "main")
        controller.recordSignal(type: "purchase_success", paywall: shown("pw_a", trigger: "main"))
        scheduler.runAll()
        XCTAssertTrue(presented.isEmpty, "purchase signal alone must not stack UI over the visible paywall")

        close(s)
        XCTAssertEqual(presented.map { $0.paywall.id }, ["pw_thanks"], "purchase rule wins; dismiss rule is not also fired")
    }

    func testFailedPurchaseUsesFailureRuleAndFallsBackToDismissWhenAbsent() {
        makeController(
            paywalls: [paywall("pw_a", rules: ["onPurchaseFailed": rule("t_retry")]), paywall("pw_retry")],
            triggers: [trigger("main", paywall: "pw_a"), trigger("t_retry", paywall: "pw_retry")])
        let s = open("pw_a", trigger: "main")
        controller.recordSignal(type: "purchase_failed", paywall: shown("pw_a", trigger: "main"))
        close(s)
        XCTAssertEqual(presented.map { $0.paywall.id }, ["pw_retry"])

        let legacy = ManifestDismissAction(type: "follow_up_paywall", followUpPaywallId: "pw_legacy")
        makeController(paywalls: [paywall("pw_a"), paywall("pw_legacy")],
                       triggers: [trigger("main", paywall: "pw_a", dismiss: legacy)])
        let s2 = open("pw_a", trigger: "main")
        controller.recordSignal(type: "purchase_failed", paywall: shown("pw_a", trigger: "main"))
        close(s2)
        XCTAssertEqual(presented.map { $0.paywall.id }, ["pw_legacy"], "failed purchase then leave = dismissal")
    }

    func testConfirmedPurchaseWithoutRuleDoesNotTriggerDismissFallback() {
        let legacy = ManifestDismissAction(type: "follow_up_paywall", followUpPaywallId: "pw_legacy")
        makeController(paywalls: [paywall("pw_a"), paywall("pw_legacy")],
                       triggers: [trigger("main", paywall: "pw_a", dismiss: legacy)])
        let s = open("pw_a", trigger: "main")
        controller.recordSignal(type: "purchase_success", paywall: shown("pw_a", trigger: "main"))
        close(s)
        XCTAssertTrue(presented.isEmpty, "never upsell a user who just bought")
    }

    func testLateOrForeignSignalsDoNotResurrectAClosedPaywall() {
        makeController(
            paywalls: [paywall("pw_a", rules: ["onPurchase": rule("t_f")]), paywall("pw_f")],
            triggers: [trigger("main", paywall: "pw_a"), trigger("t_f", paywall: "pw_f")])
        let s = open("pw_a", trigger: "main")
        close(s) // closed (e.g. programmatically) before the billing result arrived
        presented.removeAll()
        controller.recordSignal(type: "purchase_success", paywall: shown("pw_a", trigger: "main"))
        scheduler.runAll()
        XCTAssertTrue(presented.isEmpty)

        // Signal for another user's paywall is ignored.
        let s2 = open("pw_a", trigger: "main")
        let foreign = PaywallData(id: "pw_a", name: "a", html: "", triggerKey: "main", attributionUserId: "someone-else")
        controller.recordSignal(type: "purchase_success", paywall: foreign)
        XCTAssertNil(s2.pendingEvent)
    }

    func testConfirmedSuccessIsNotOverwrittenByLaterFailure() {
        makeController(paywalls: [paywall("pw_a")], triggers: [trigger("main", paywall: "pw_a")])
        let s = open("pw_a", trigger: "main")
        controller.recordSignal(type: "purchase_success", paywall: shown("pw_a", trigger: "main"))
        controller.recordSignal(type: "purchase_failed", paywall: shown("pw_a", trigger: "main"))
        XCTAssertEqual(s.pendingEvent, .purchase)
    }

    func testIdentityChangeBetweenSignalAndCloseCancelsFollowUp() {
        makeController(
            paywalls: [paywall("pw_a", rules: ["onPurchase": rule("t_f")]), paywall("pw_f")],
            triggers: [trigger("main", paywall: "pw_a"), trigger("t_f", paywall: "pw_f")])
        let s = open("pw_a", trigger: "main")
        controller.recordSignal(type: "purchase_success", paywall: shown("pw_a", trigger: "main"))
        userId = "u2"
        controller.reset()
        close(s)
        XCTAssertTrue(presented.isEmpty)
    }

    // MARK: Manifest decoding

    func testFollowUpRulesDecodeFromContentJsonAndSurviveCacheRoundTrip() throws {
        let json = """
        {"ok": true, "triggers": [{"id":"t","key":"k","paywallId":"p","variants":[],"rules":[],
            "dismissAction": {"type": "follow_up_paywall", "followUpPaywallId": "p2"}}],
         "paywalls": {"p": {"id":"p","name":"p","templateKey":"t","html":"<h/>",
            "contentJson": {"other": 1, "followUpRules": {
                "onDismiss": {"enabled": true, "actionType": "trigger", "triggerKey": "next", "delayMs": 250.0,
                              "oncePerSession": true, "cooldownMs": 5000, "maxChainDepth": 2,
                              "skipIfPremium": true, "preventRepeatPaywall": false},
                "onRestore": "garbage"}}}}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PaywallManifest.self, from: json)
        let rules = try XCTUnwrap(decoded.paywalls["p"]).followUpRules
        XCTAssertEqual(rules.count, 1, "malformed rule dropped without failing the manifest")
        let r = try XCTUnwrap(rules["onDismiss"])
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.triggerKey, "next")
        XCTAssertEqual(r.delayMs, 250)
        XCTAssertTrue(r.oncePerSession)
        XCTAssertEqual(r.cooldownMs, 5000)
        XCTAssertEqual(r.maxChainDepth, 2)
        XCTAssertTrue(r.skipIfPremium)
        XCTAssertFalse(r.preventRepeatPaywall)
        XCTAssertEqual(decoded.triggers[0].dismissAction?.followUpPaywallId, "p2")

        let again = try JSONDecoder().decode(PaywallManifest.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(again, decoded)
    }

    // MARK: Facade wiring

    func testSubscriptionStatusResetsOnIdentityChange() {
        let defaults = freshDefaults("followup.facade")
        let sdk = MySuperwall(manifestService: ManifestService(userDefaults: defaults, session: StubURLProtocol.session()),
                              eventQueue: OfflineEventQueue(userDefaults: defaults, session: StubURLProtocol.session()),
                              userDefaults: defaults, bundleIdentifier: "com.app")
        sdk.identify(userId: "a")
        sdk.setSubscriptionStatus(.active)
        XCTAssertEqual(sdk.subscriptionStatus, .active)
        sdk.identify(userId: "a")
        XCTAssertEqual(sdk.subscriptionStatus, .active, "same user keeps status")
        sdk.identify(userId: "b")
        XCTAssertEqual(sdk.subscriptionStatus, .unknown)
    }
}

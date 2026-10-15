import Foundation

/// Host-reported entitlement state, used only for `skipIfPremium`. `unknown` is never
/// treated as premium, so a follow-up is not suppressed on a guess.
public enum SubscriptionStatus: Equatable {
    case unknown
    case active
    case inactive
}

enum FollowUpEvent: String {
    case dismiss = "onDismiss"
    case purchase = "onPurchase"
    case purchaseFailed = "onPurchaseFailed"
    case restore = "onRestore"

    /// Only these host-confirmed event types are accepted; button taps never map here.
    static func fromTrackedType(_ type: String) -> FollowUpEvent? {
        switch type.lowercased() {
        case "purchase", "purchase_success": return .purchase
        case "purchase_failed": return .purchaseFailed
        case "restore", "restore_success": return .restore
        default: return nil
        }
    }

    var isSuccess: Bool { self == .purchase || self == .restore }
}

/// One presented paywall as seen by the follow-up logic (UI independent).
final class FollowUpSession {
    let paywall: PaywallData
    let depth: Int
    let chain: [String]
    let epoch: Int
    fileprivate(set) var pendingEvent: FollowUpEvent?
    fileprivate(set) var closed = false

    fileprivate init(paywall: PaywallData, depth: Int, chain: [String], epoch: Int) {
        self.paywall = paywall
        self.depth = depth
        self.chain = chain
        self.epoch = epoch
    }
}

struct FollowUpPresentation {
    let paywall: PaywallData
    let depth: Int
    let chain: [String]
}

/// Decides, schedules and validates automatic follow-up paywalls. It never touches UIKit /
/// Android views: presentation is delegated to the `present` closure supplied on close, and
/// that closure only runs after the previous UI is gone and the host is still valid.
final class FollowUpController {
    struct Environment {
        var manifest: () -> PaywallManifest?
        var isPremium: () -> Bool
        var userId: () -> String?
        /// Normal rule-engine resolution for a trigger key.
        var resolveTrigger: (String) -> PaywallResult
        var now: () -> Date = Date.init
        /// Runs `work` after the delay and returns a cancel closure.
        var schedule: (TimeInterval, @escaping () -> Void) -> () -> Void = FollowUpController.mainQueueSchedule
    }

    /// Absolute ceiling regardless of what a rule asks for.
    static let hardMaxDepth = 5

    static let mainQueueSchedule: (TimeInterval, @escaping () -> Void) -> () -> Void = { delay, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    private let env: Environment
    private let lock = NSLock()
    private var epoch = 0
    private var active: FollowUpSession?
    private var firedKeys = Set<String>()
    private var lastFired = [String: Date]()
    private var scheduled = [UUID: () -> Void]()

    init(environment: Environment) {
        self.env = environment
    }

    /// Identity, scope or locale changed: drop all session state and cancel delayed work.
    func reset() {
        lock.lock()
        epoch += 1
        active = nil
        firedKeys.removeAll()
        lastFired.removeAll()
        let cancels = Array(scheduled.values)
        scheduled.removeAll()
        lock.unlock()
        cancels.forEach { $0() }
    }

    /// Registers a paywall that is now on screen. A new presentation supersedes any delayed work.
    @discardableResult
    func begin(paywall: PaywallData, depth: Int = 0, chain: [String]? = nil) -> FollowUpSession {
        lock.lock()
        let session = FollowUpSession(paywall: paywall, depth: depth, chain: chain ?? [paywall.id], epoch: epoch)
        active = session
        let cancels = Array(scheduled.values)
        scheduled.removeAll()
        lock.unlock()
        cancels.forEach { $0() }
        return session
    }

    /// Host-confirmed purchase / restore outcome for a paywall. Records a pending event for the
    /// live session only; it does not present anything while the old UI is still showing.
    func recordSignal(type: String, paywall: PaywallData) {
        guard let event = FollowUpEvent.fromTrackedType(type) else { return }
        lock.lock(); defer { lock.unlock() }
        guard let s = active, !s.closed, s.epoch == epoch,
              s.paywall.id == paywall.id, s.paywall.triggerKey == paywall.triggerKey,
              paywall.attributionUserId == env.userId() else { return }
        // A confirmed success is never overwritten by a later failure.
        if let existing = s.pendingEvent, existing.isSuccess, !event.isSuccess { return }
        s.pendingEvent = event
    }

    /// Called exactly once per session after the paywall UI is actually gone.
    func sessionDidClose(
        _ session: FollowUpSession,
        hostValid: @escaping () -> Bool,
        present: @escaping (FollowUpPresentation) -> Bool
    ) {
        lock.lock()
        if session.closed { lock.unlock(); return }
        session.closed = true
        if active === session { active = nil }
        let live = session.epoch == epoch
        lock.unlock()
        guard live, let plan = makePlan(for: session) else { return }

        let id = UUID()
        let cancel = env.schedule(TimeInterval(plan.delayMs) / 1000.0) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.scheduled[id] = nil
            self.lock.unlock()
            self.fire(plan, session: session, hostValid: hostValid, present: present)
        }
        lock.lock()
        // The work may have run synchronously (injected scheduler); only track if still pending.
        if session.epoch == epoch { scheduled[id] = cancel } else { lock.unlock(); cancel(); return }
        lock.unlock()
    }

    // MARK: - Planning

    private enum Source {
        case rule(ManifestFollowUpRule)
        case legacy(paywallId: String)
    }

    private struct Plan {
        let event: FollowUpEvent
        let source: Source
        let delayMs: Int
    }

    private func makePlan(for session: FollowUpSession) -> Plan? {
        guard let manifest = env.manifest() else { return nil }
        let rules = manifest.paywalls[session.paywall.id]?.followUpRules ?? [:]

        var event = session.pendingEvent ?? .dismiss
        func enabledRule(_ e: FollowUpEvent) -> ManifestFollowUpRule? {
            guard let r = rules[e.rawValue], r.enabled else { return nil }
            return r
        }
        if event != .dismiss, enabledRule(event) == nil {
            // A confirmed purchase/restore with no rule must not fall back to the dismiss
            // behaviour; a failed purchase followed by leaving is just a dismissal.
            if event.isSuccess { return nil }
            event = .dismiss
        }

        if let rule = enabledRule(event) {
            // An enabled explicit rule always takes precedence over the legacy root action.
            guard rule.actionType.lowercased() == "trigger",
                  let key = rule.triggerKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                return nil
            }
            return Plan(event: event, source: .rule(rule), delayMs: rule.delayMs)
        }

        guard event == .dismiss, session.depth == 0,
              let triggerKey = session.paywall.triggerKey,
              let action = manifest.findTrigger(triggerKey)?.dismissAction,
              action.type.lowercased() == "follow_up_paywall",
              let target = action.followUpPaywallId, !target.isEmpty else { return nil }
        return Plan(event: .dismiss, source: .legacy(paywallId: target), delayMs: 0)
    }

    // MARK: - Firing

    private func fire(
        _ plan: Plan,
        session: FollowUpSession,
        hostValid: () -> Bool,
        present: (FollowUpPresentation) -> Bool
    ) {
        lock.lock()
        let epochOK = session.epoch == epoch
        lock.unlock()
        guard epochOK, hostValid() else { return }

        let depth = session.depth + 1
        let key = "\(session.paywall.id)|\(plan.event.rawValue)"
        let target: PaywallData
        let preventRepeat: Bool

        switch plan.source {
        case .rule(let rule):
            if rule.skipIfPremium && env.isPremium() { return }
            guard depth <= min(rule.maxChainDepth, FollowUpController.hardMaxDepth) else { return }
            lock.lock()
            let blockedOnce = rule.oncePerSession && firedKeys.contains(key)
            let last = lastFired[key]
            lock.unlock()
            if blockedOnce { return }
            if rule.cooldownMs > 0, let last = last,
               env.now().timeIntervalSince(last) * 1000 < Double(rule.cooldownMs) { return }
            guard let triggerKey = rule.triggerKey else { return }
            let result = env.resolveTrigger(triggerKey)
            guard result.show, let resolved = result.paywall else { return }
            // Follow-ups are not part of the target trigger's experiment exposure: drop the
            // variant/experiment attribution, keep the originating user binding.
            target = PaywallData(
                id: resolved.id, name: resolved.name, html: resolved.html,
                productIds: resolved.productIds, products: resolved.products,
                triggerKey: triggerKey, abVariant: nil, experimentContext: nil,
                attributionUserId: session.paywall.attributionUserId,
                attributionScope: session.paywall.attributionScope
            )
            preventRepeat = rule.preventRepeatPaywall

        case .legacy(let paywallId):
            guard depth == 1, let mp = env.manifest()?.paywalls[paywallId] else { return }
            target = PaywallData(
                id: mp.id, name: mp.name, html: mp.html,
                productIds: mp.productIds, products: mp.products,
                triggerKey: session.paywall.triggerKey, abVariant: nil, experimentContext: nil,
                attributionUserId: session.paywall.attributionUserId,
                attributionScope: session.paywall.attributionScope
            )
            preventRepeat = true
        }

        if preventRepeat && session.chain.contains(target.id) { return }

        lock.lock()
        let stillLive = session.epoch == epoch
        lock.unlock()
        guard stillLive else { return }

        if present(FollowUpPresentation(paywall: target, depth: depth, chain: session.chain + [target.id])) {
            lock.lock()
            firedKeys.insert(key)
            lastFired[key] = env.now()
            lock.unlock()
        }
    }
}

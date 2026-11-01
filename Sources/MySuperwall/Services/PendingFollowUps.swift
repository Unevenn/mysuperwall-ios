import Foundation

/// Durable follow-up policies; presentation and billing closures remain in the current host.
final class PendingFollowUps {
    struct Offer: Codable {
        let id: String, source: String, event: String
        let rule: ManifestFollowUpRule
        let created: Double, active: Double
        let session: Int, foreground: Int, depth: Int
        let seen: [String]
    }
    struct Store: Codable { var jobs: [Offer] = []; var usage: [String: [Double]] = [:] }
    private var state = Store()
    private let defaults: UserDefaults, key: String
    init(defaults: UserDefaults, scope: String) {
        self.defaults = defaults; key = "mysuperwall.offers.v1." + scope
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Store.self, from: data) { state = saved }
    }
    func enqueue(source: String, event: String, rule: ManifestFollowUpRule, metrics: LifecycleHistory.Snapshot,
                 depth: Int, seen: [String], now: Double = Date().timeIntervalSince1970) {
        let id = [source,event,rule.triggerKey ?? ""].joined(separator: "|")
        if state.jobs.contains(where: { $0.id == id && $0.rule == rule }) { return }
        state.jobs.removeAll { $0.id == id }
        state.jobs.append(Offer(id: id, source: source, event: event, rule: rule, created: now, active: metrics.active,
            session: metrics.sessions, foreground: metrics.foregrounds, depth: depth, seen: seen)); save()
    }
    func cancelAfterPurchase() { state.jobs.removeAll { $0.rule.cancelOnPurchase != false }; save() }
    func eligible(metrics: LifecycleHistory.Snapshot, premium: Bool,
                  current: (String,String) -> ManifestFollowUpRule?, now: Double = Date().timeIntervalSince1970) -> [Offer] {
        state.jobs.removeAll { now < $0.created || now - $0.created >= Double($0.rule.expiresMinutes ?? 1440) * 60 || current($0.source,$0.event) != $0.rule }
        save()
        return state.jobs.filter { j in
            let r = j.rule
            guard r.actionType.lowercased() == "trigger", r.enabled, r.triggerKey != nil, j.depth < min(5,r.maxChainDepth),
                  !(r.skipIfPremium && premium), metrics.sessions >= (r.minSessions ?? 1),
                  !(r.excludeFirstSession == true && metrics.sessions <= 1),
                  now - metrics.first >= Double(r.minDays ?? 0) * 86400,
                  now - j.created >= Double(r.delayMs) / 1000 else { return false }
            let usage = state.usage[j.id] ?? []
            if usage.filter({ floor($0 / 86400) == floor(now / 86400) }).count >= (r.maxShowsPerDay ?? 1) { return false }
            if let last = usage.last, now - last < Double(r.cooldownMs) / 1000 { return false }
            if r.oncePerSession && usage.contains(where: { $0 >= metrics.sessionStarted }) { return false }
            let wait = Double(r.waitMinutes ?? 10) * 60
            switch r.timingMode {
            case "elapsed": return now - j.created >= wait
            case "active": return metrics.active - j.active >= wait
            case "next_session": return metrics.sessions > j.session
            case "next_foreground": return metrics.foregrounds > j.foreground
            default: return true
            }
        }.sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }
    }
    func shown(_ id: String, now: Double = Date().timeIntervalSince1970) {
        state.jobs.removeAll { $0.id == id }
        state.usage[id] = (state.usage[id] ?? []).filter { now - $0 < 30 * 86400 } + [now]; save()
    }
    private func save() { if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) } }
}

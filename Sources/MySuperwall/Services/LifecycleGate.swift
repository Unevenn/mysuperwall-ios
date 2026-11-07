import Foundation

/// Applies a lifecycle trigger's schedule and limits on the device, so most opens need no request. Main thread only.
final class LifecycleGate {
    private struct Entry: Codable { var shown = 0; var dismissed = 0; var times: [Double] = [] }
    private let defaults: UserDefaults
    private let storageKey: String
    private var entries: [String: Entry]

    init(defaults: UserDefaults, scope: String) {
        self.defaults = defaults
        storageKey = "mysuperwall.lifecycle.gate.v1.\(scope)"
        entries = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func blockReason(_ trigger: ManifestTrigger, sessions: Int, premium: Bool, now: Double) -> String? {
        let limit = trigger.displayLimit
        if let fromOpen = trigger.schedule?.fromOpen, fromOpen > 1, sessions < fromOpen { return "schedule_not_reached" }
        if limit?.hideForPurchasers == true && premium { return "purchased" }
        guard let limit = limit, let entry = entries[trigger.key] else { return nil }
        if let max = limit.maxPerUser, max > 0, entry.shown >= max { return "max_per_user" }
        if let max = limit.stopAfterDismissals, max > 0, entry.dismissed >= max { return "dismissals" }
        if let max = limit.maxPerPeriod, max > 0 {
            let start = now - Double(limit.period == "week" ? 7 : 1) * 86400
            if entry.times.filter({ $0 >= start }).count >= max { return "max_per_period" }
        }
        if let hours = limit.minIntervalHours, hours > 0, let last = entry.times.last, last + Double(hours) * 3600 > now { return "min_interval" }
        return nil
    }

    func remainingDelay(_ trigger: ManifestTrigger, readyAt: Double, now: Double) -> Double {
        max(0, readyAt + Double(trigger.schedule?.delaySeconds ?? 0) - now)
    }

    func recordShown(_ key: String, now: Double) {
        var entry = entries[key] ?? Entry()
        entry.shown += 1
        entry.times = Array((entry.times + [now]).suffix(50))
        entries[key] = entry
        save()
    }

    func recordDismissed(_ key: String) {
        var entry = entries[key] ?? Entry()
        entry.dismissed += 1
        entries[key] = entry
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: storageKey) }
    }
}

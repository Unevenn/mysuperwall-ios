import Foundation

/// Device-local lifecycle journal. Access on the main queue only.
final class LifecycleHistory {
    struct Interval: Codable { var start: Double; var end: Double; var from: Double; var to: Double }
    struct Snapshot: Codable {
        var intervals: [Interval] = []
        var first: Double
        var version: String
        var sessionStarted: Double = 0
        var foregrounds = 0
        var sessions = 0
        var active: Double = 0
        var pending: [String: Double] = [:]
        var completed: Set<String> = []
    }
    static let retention: Double = 30 * 86400
    private let defaults: UserDefaults
    private let key: String
    private(set) var state: Snapshot
    private var baseline: Double?
    private var background: Double?

    init(defaults: UserDefaults, scope: String, version: String, now: Double = Date().timeIntervalSince1970) {
        self.defaults = defaults; key = "mysuperwall.lifecycle.v1." + scope
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
           saved.first > 0, saved.first <= now, saved.active.isFinite, saved.active >= 0, saved.sessions > 0, saved.sessions <= 1000000 {
            state = saved
        } else { state = Snapshot(first: now, version: version) }
        if state.sessions == 0 { add("mysuperwall.install", at: state.first) }
        if state.version != version {
            state.completed.remove("mysuperwall.update")
            state.pending["mysuperwall.update"] = now
        }
        state.version = version
        newSession(now); save()
    }
    private func add(_ key: String, at: Double) {
        if !state.completed.contains(key), state.pending[key] == nil { state.pending[key] = at }
    }
    private func newSession(_ now: Double) {
        state.sessions = min(1000000,state.sessions + 1); state.sessionStarted = now; state.pending["mysuperwall.session"] = now
        add("mysuperwall.session_\(state.sessions)", at: now)
    }
    func resume(now: Double = Date().timeIntervalSince1970) {
        guard baseline == nil else { return }
        if let away = background, now - away >= 1800 { newSession(now) }
        background = nil; baseline = now; state.foregrounds += 1; state.pending["mysuperwall.foreground"] = now; save()
    }
    func pause(now: Double = Date().timeIntervalSince1970) {
        tick(keys: [], now: now); baseline = nil; background = now; save()
    }
    func tick(keys: [String], now: Double = Date().timeIntervalSince1970) {
        let previous = state.active
        if let start = baseline {
            let delta = max(0,now - start)
            if let last = state.intervals.last, last.end == start {
                state.intervals[state.intervals.count-1].end = now; state.intervals[state.intervals.count-1].to = previous + delta
            } else if delta > 0 { state.intervals.append(Interval(start: start,end: now,from: previous,to: previous + delta)) }
            state.active += delta; baseline = now
        }
        state.intervals.removeAll { now - $0.end >= Self.retention }
        for key in keys where key.hasPrefix("mysuperwall.active_minutes_") {
            if let minute = Int(key.dropFirst("mysuperwall.active_minutes_".count)), minute > 0, minute <= 43200 {
                let value = Double(minute) * 60
                if let interval = state.intervals.first(where: { $0.from < value && $0.to >= value }) { add(key,at: interval.start + value - interval.from) }
            }
        }
        for key in keys where key.hasPrefix("mysuperwall.day_") {
            if let day = Int(key.dropFirst("mysuperwall.day_".count)), day > 0, day <= 43200 {
                let at = state.first + Double(day) * 86400
                if at <= now { add(key, at: at) }
            }
        }
        for (key, at) in state.pending where now - at >= Self.retention {
            state.pending.removeValue(forKey: key)
            if !Self.repeating(key) { state.completed.insert(key) }
        }
        save()
    }
    func candidates(priorities: [String: Int]) -> [String] {
        state.pending.keys.filter { priorities[$0] != nil }.sorted {
            if priorities[$0] != priorities[$1] { return (priorities[$0] ?? 0) > (priorities[$1] ?? 0) }
            if state.pending[$0] != state.pending[$1] { return (state.pending[$0] ?? 0) < (state.pending[$1] ?? 0) }
            return $0 < $1
        }
    }
    func shown(_ key: String, occurrence: Double) {
        guard state.pending[key] == occurrence else { return }
        state.pending.removeValue(forKey: key)
        if !Self.repeating(key) { state.completed.insert(key) }; save()
    }
    private static func repeating(_ key: String) -> Bool { key == "mysuperwall.session" || key == "mysuperwall.foreground" }
    private func save() { if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) } }
}

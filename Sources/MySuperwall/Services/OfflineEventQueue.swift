import Foundation

public final class OfflineEventQueue {
    private let userDefaults: UserDefaults
    private let session: URLSession
    private let queueKey = "mysuperwall_offline_event_queue_v1"
    private let lock = NSLock()
    private var isFlushing = false

    public init(userDefaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.userDefaults = userDefaults
        self.session = session
    }

    /// Enqueue an analytics event to disk.
    public func enqueue(event: [String: Any], scope: ManifestScope? = nil) {
        let key = scope.map { "mysuperwall_events_v2_" + $0.cacheKey } ?? queueKey
        lock.lock()
        defer { lock.unlock() }

        var list = loadRawQueue(key: key)
        var mutableEvent = event
        if mutableEvent["eventId"] == nil { mutableEvent["eventId"] = UUID().uuidString }
        if mutableEvent["timestamp"] == nil {
            mutableEvent["timestamp"] = ISO8601DateFormatter().string(from: Date())
        }
        list.append(mutableEvent)

        // Keep maximum 200 events
        if list.count > 200 {
            list = Array(list.suffix(200))
        }

        saveRawQueue(list, key: key)
    }

    /// Flushes queued events to POST /paywall/events/batch
    public func flush(baseUrl: String, appKey: String?, bundleId: String?, completion: ((Int) -> Void)? = nil) {
        let scope = ManifestScope(baseURL: baseUrl, appKey: appKey, appIdentifier: bundleId, platform: "ios", lang: "en")
        let key = "mysuperwall_events_v2_" + scope.cacheKey
        lock.lock()
        if isFlushing {
            lock.unlock()
            completion?(0)
            return
        }
        isFlushing = true
        let list = loadRawQueue(key: key)
        lock.unlock()

        guard !list.isEmpty else {
            lock.lock()
            isFlushing = false
            lock.unlock()
            completion?(0)
            return
        }

        let batch = Array(list.prefix(100))
        guard let url = URL(string: "\(baseUrl)paywall/events/batch") else {
            lock.lock()
            isFlushing = false
            lock.unlock()
            completion?(0)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "platform": "ios",
            "events": batch
        ]
        if let ak = appKey, !ak.isEmpty { body["appKey"] = ak }
        if let bid = bundleId, !bid.isEmpty { body["bundleId"] = bid }

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            lock.lock()
            isFlushing = false
            lock.unlock()
            completion?(0)
            return
        }
        request.httpBody = httpBody

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            self.lock.lock()
            defer {
                self.isFlushing = false
                self.lock.unlock()
            }

            guard error == nil, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                completion?(0)
                return
            }

            // Remove sent batch
            var current = self.loadRawQueue(key: key)
            let sentIds = Set(batch.compactMap { $0["eventId"] as? String })
            current.removeAll { event in
                guard let id = event["eventId"] as? String else { return false }
                return sentIds.contains(id)
            }
            self.saveRawQueue(current, key: key)
            completion?(batch.count)
        }
        task.resume()
    }

    private func loadRawQueue(key: String? = nil) -> [[String: Any]] {
        let key = key ?? queueKey
        guard let data = userDefaults.data(forKey: key),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        var upgraded = list
        var changed = false
        for index in upgraded.indices where upgraded[index]["eventId"] == nil {
            upgraded[index]["eventId"] = UUID().uuidString
            changed = true
        }
        if changed { saveRawQueue(upgraded, key: key) }
        return upgraded
    }

    private func saveRawQueue(_ list: [[String: Any]], key: String? = nil) {
        if let data = try? JSONSerialization.data(withJSONObject: list) {
            userDefaults.set(data, forKey: key ?? queueKey)
        }
    }
}

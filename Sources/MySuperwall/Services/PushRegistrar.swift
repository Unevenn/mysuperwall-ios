import Foundation

/// Sends one JSON body to a MySuperwall SDK endpoint (for example `paywall/push-token`); `true` when accepted.
protocol PushTransport {
    func post(path: String, body: [String: Any], completion: @escaping (Bool) -> Void)
}

struct URLSessionPushTransport: PushTransport {
    let baseUrl: () -> String
    var session: URLSession = .shared

    func post(path: String, body: [String: Any], completion: @escaping (Bool) -> Void) {
        let base = baseUrl()
        guard let url = URL(string: base.hasSuffix("/") ? base + path : base + "/" + path),
              let data = try? JSONSerialization.data(withJSONObject: body) else { completion(false); return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        session.dataTask(with: request) { _, response, _ in
            completion((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
        }.resume()
    }
}

/// What the server needs to know about this install; read when a request is made.
struct PushIdentity {
    var appKey: String?
    var bundleId: String?
    var userId: String?
    var locale: String?
    var appVersion: String?
    var utcOffsetMinutes: Int
}

/// Registers the app's FCM token with MySuperwall so notifications can reach the device. The SDK has no
/// Firebase dependency: the app reads the token and hands it over with `MySuperwall.setPushToken(_:)`.
final class PushRegistrar {
    private let defaults: UserDefaults
    private let transport: PushTransport
    private let queue: DispatchQueue
    private let now: () -> Date
    private let lock = NSLock()
    private static let tokenKey = "mysuperwall_push_token_v1"
    private static let syncKey = "mysuperwall_push_sync_v1"

    init(defaults: UserDefaults, transport: PushTransport, queue: DispatchQueue = DispatchQueue(label: "mysuperwall.push"), now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.transport = transport
        self.queue = queue
        self.now = now
    }

    var savedToken: String? {
        defaults.string(forKey: Self.tokenKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult
    func set(_ token: String, identity: PushIdentity) -> Bool {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        lock.lock(); defaults.set(value, forKey: Self.tokenKey); lock.unlock()
        sync(identity: identity, force: true)
        return true
    }

    /// Registers the saved token for the current user, language and app version; at most once a day unless forced.
    func sync(identity: PushIdentity, force: Bool = false) {
        guard let token = savedToken, let userId = identity.userId else { return }
        let signature = [token, userId, identity.locale ?? "", identity.appVersion ?? "", String(identity.utcOffsetMinutes)].joined(separator: "|")
        if !force, let saved = defaults.string(forKey: Self.syncKey) {
            let parts = saved.components(separatedBy: "@")
            if parts.count == 2, parts[1] == signature, let stamp = Double(parts[0]), now().timeIntervalSince1970 - stamp < 86_400 { return }
        }
        var body = base(identity)
        body["userId"] = userId
        body["token"] = token
        body["platform"] = "ios"
        body["utcOffsetMinutes"] = identity.utcOffsetMinutes
        if let locale = identity.locale { body["locale"] = locale }
        if let version = identity.appVersion { body["appVersion"] = version }
        queue.async { [weak self] in
            self?.transport.post(path: "paywall/push-token", body: body) { ok in
                guard ok, let self = self else { return }
                self.lock.lock()
                self.defaults.set("\(self.now().timeIntervalSince1970)@\(signature)", forKey: Self.syncKey)
                self.lock.unlock()
            }
        }
    }

    /// Stops notifications for this device (the user turned them off, or logged out).
    func clear(identity: PushIdentity) {
        let token = savedToken
        lock.lock(); defaults.removeObject(forKey: Self.tokenKey); defaults.removeObject(forKey: Self.syncKey); lock.unlock()
        guard let token = token else { return }
        var body = base(identity)
        body["token"] = token
        queue.async { [weak self] in self?.transport.post(path: "paywall/push-token/remove", body: body) { _ in } }
    }

    func reportOpened(jobId: String, identity: PushIdentity) {
        guard let userId = identity.userId else { return }
        var body = base(identity)
        body["userId"] = userId
        body["jobId"] = jobId
        body["platform"] = "ios"
        if let version = identity.appVersion { body["appVersion"] = version }
        queue.async { [weak self] in self?.transport.post(path: "paywall/notification-opened", body: body) { _ in } }
    }

    private func base(_ identity: PushIdentity) -> [String: Any] {
        var body: [String: Any] = [:]
        if let key = identity.appKey, !key.isEmpty { body["appKey"] = key }
        if let bundle = identity.bundleId, !bundle.isEmpty { body["bundleId"] = bundle }
        return body
    }
}

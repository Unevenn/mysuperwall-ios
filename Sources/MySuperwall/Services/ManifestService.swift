import Foundation

public enum ManifestSyncError: Error, Equatable {
    /// The scope (baseURL/appKey/app id/platform/lang) changed while the request was in flight.
    case staleScope
}

public final class ManifestService {
    private let userDefaults: UserDefaults
    private let session: URLSession
    /// Pre-scoping cache key. Never read: it cannot be attributed to a scope.
    private let legacyStorageKey = "mysuperwall_cached_manifest_v1"

    private let lock = NSLock()
    private var _manifest: PaywallManifest?
    private var _scope: ManifestScope?
    /// Bumped on every scope change; in-flight requests compare it before applying anything.
    private var _generation = 0
    private var inFlight: URLSessionDataTask?

    public func dispose() {
        lock.lock(); defer { lock.unlock() }
        _generation += 1
        inFlight?.cancel(); inFlight = nil
        _manifest = nil; _scope = nil
    }

    public var manifest: PaywallManifest? {
        lock.lock(); defer { lock.unlock() }
        return _manifest
    }

    public var scope: ManifestScope? {
        lock.lock(); defer { lock.unlock() }
        return _scope
    }

    public init(userDefaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.userDefaults = userDefaults
        self.session = session
    }

    /// Switches to `scope`. On a change, the in-memory manifest is dropped first, in-flight
    /// work is invalidated, and only that scope's own disk entry is loaded. Returns true when
    /// the scope changed.
    @discardableResult
    public func activate(scope newScope: ManifestScope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _scope == newScope { return false }
        _generation += 1
        _manifest = nil
        inFlight?.cancel()
        inFlight = nil
        _scope = newScope
        _manifest = readDisk(for: newScope)
        userDefaults.removeObject(forKey: legacyStorageKey)
        return true
    }

    /// Synchronously (re)loads the active scope's cached manifest from disk (0 ms latency).
    @discardableResult
    public func loadFromDisk() -> PaywallManifest? {
        lock.lock(); defer { lock.unlock() }
        guard let scope = _scope else { return nil }
        let decoded = readDisk(for: scope)
        if let decoded = decoded { _manifest = decoded }
        return decoded
    }

    /// Persists manifest to disk under the active scope.
    public func saveToDisk(_ manifest: PaywallManifest) {
        lock.lock(); defer { lock.unlock() }
        guard let scope = _scope else { _manifest = manifest; return }
        _manifest = manifest
        writeDisk(manifest, for: scope)
    }

    private func readDisk(for scope: ManifestScope) -> PaywallManifest? {
        guard let data = userDefaults.data(forKey: scope.cacheKey) else { return nil }
        do {
            return try JSONDecoder().decode(PaywallManifest.self, from: data)
        } catch {
            MySuperwallLogging.warning("Failed to decode cached manifest from disk: \(error)")
            return nil
        }
    }

    private func writeDisk(_ manifest: PaywallManifest, for scope: ManifestScope) {
        do {
            userDefaults.set(try JSONEncoder().encode(manifest), forKey: scope.cacheKey)
        } catch {
            MySuperwallLogging.warning("Failed to persist manifest to disk: \(error)")
        }
    }

    /// Background ETag / SHA-256 sync with backend. The request is bound to the scope it was
    /// started for; if the scope changes meanwhile, the response (including a 304) is discarded
    /// and nothing is written to memory or disk.
    public func syncInBackground(
        baseUrl: String,
        appKey: String?,
        bundleId: String?,
        lang: String? = nil,
        substitutionData: [String: Any] = [:],
        completion: ((Result<PaywallManifest?, Error>) -> Void)? = nil
    ) {
        let requested = ManifestScope(baseURL: baseUrl, appKey: appKey, appIdentifier: bundleId, platform: "ios",
                                      lang: lang ?? LocaleSupport.deviceLanguage(), priceFingerprint: ManifestScope.fingerprint(substitutionData))
        activate(scope: requested)

        let normalizedBase = baseUrl.hasSuffix("/") ? baseUrl : "\(baseUrl)/"
        guard let url = URL(string: "\(normalizedBase)paywall/manifest") else {
            completion?(.failure(URLError(.badURL)))
            return
        }

        lock.lock()
        let generation = _generation
        let currentHash = _manifest?.hash
        lock.unlock()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let h = currentHash, !h.isEmpty {
            request.setValue("\"\(h)\"", forHTTPHeaderField: "If-None-Match")
        }

        var body: [String: Any] = ["platform": "ios", "lang": requested.lang]
        body["substitutionData"] = substitutionData
        if let ak = appKey, !ak.isEmpty { body["appKey"] = ak }
        if let bid = bundleId, !bid.isEmpty { body["bundleId"] = bid }
        if let h = currentHash, !h.isEmpty { body["hash"] = h }

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            completion?(.failure(URLError(.cannotDecodeContentData)))
            return
        }
        request.httpBody = httpBody

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            // Stale check happens before the result is interpreted or delivered.
            func current() -> Bool { self.lock.lock(); defer { self.lock.unlock() }; return self._generation == generation }

            if let error = error {
                completion?(.failure(current() ? error : ManifestSyncError.staleScope as Error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion?(.failure(URLError(.badServerResponse)))
                return
            }

            if httpResponse.statusCode == 304 {
                completion?(current() ? .success(self.manifest) : .failure(ManifestSyncError.staleScope))
                return
            }
            guard (200...299).contains(httpResponse.statusCode), let data = data else {
                completion?(current() ? .success(self.manifest) : .failure(ManifestSyncError.staleScope))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(PaywallManifest.self, from: data)

                self.lock.lock()
                guard self._generation == generation, let scope = self._scope else {
                    self.lock.unlock()
                    completion?(.failure(ManifestSyncError.staleScope))
                    return
                }
                if decoded.notModified == true {
                    let existing = self._manifest
                    self.lock.unlock()
                    completion?(.success(existing))
                    return
                }
                // Memory and disk are updated atomically with the generation check.
                self._manifest = decoded
                self.writeDisk(decoded, for: scope)
                self.lock.unlock()
                completion?(.success(decoded))
            } catch {
                completion?(.failure(current() ? error : ManifestSyncError.staleScope as Error))
            }
        }

        lock.lock()
        if _generation == generation {
            inFlight?.cancel()
            inFlight = task
            lock.unlock()
            task.resume()
        } else {
            lock.unlock()
            completion?(.failure(ManifestSyncError.staleScope))
        }
    }
}

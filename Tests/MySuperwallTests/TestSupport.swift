import Foundation
import XCTest
@testable import MySuperwall

/// URLProtocol that parks requests until the test decides when/how to answer them.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _pending: [StubURLProtocol] = []
    private static var _bodies: [[String: Any]] = []

    static var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return _pending.count }
    static var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _bodies }

    static func reset() {
        lock.lock(); _pending = []; _bodies = []; lock.unlock()
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Answers the oldest unanswered request.
    static func respondNext(status: Int = 200, body: Data = Data()) {
        lock.lock()
        let next = _pending.isEmpty ? nil : _pending.removeFirst()
        lock.unlock()
        guard let proto = next else { return }
        let response = HTTPURLResponse(url: proto.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { proto.client?.urlProtocol(proto, didLoad: body) }
        proto.client?.urlProtocolDidFinishLoading(proto)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                collected.append(buffer, count: n)
            }
            stream.close()
            data = collected
        }
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        StubURLProtocol.lock.lock()
        StubURLProtocol._pending.append(self)
        StubURLProtocol._bodies.append(json)
        StubURLProtocol.lock.unlock()
    }

    override func stopLoading() {}
}

func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

func freshDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

func manifestJSON(hash: String, paywallIds: [String] = ["pw1"], extra: String = "") -> Data {
    let paywalls = paywallIds.map {
        "\"\($0)\": {\"id\": \"\($0)\", \"name\": \"\($0)\", \"templateKey\": \"t\", \"html\": \"<html/>\"}"
    }.joined(separator: ",")
    return """
    {"ok": true, "hash": "\(hash)", "triggers": [], "paywalls": {\(paywalls)}\(extra)}
    """.data(using: .utf8)!
}

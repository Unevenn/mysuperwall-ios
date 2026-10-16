import Foundation

public enum MySuperwallLogLevel: String { case all, warning, error, none }
public enum PaywallState: String { case idle, loading, ready, presenting, visible, dismissed, failed }

public enum MySuperwallLogging {
    private static let lock = NSLock()
    private static var configuredLevel = MySuperwallLogLevel.warning
    public static var level: MySuperwallLogLevel {
        get { lock.lock(); defer { lock.unlock() }; return configuredLevel }
        set { lock.lock(); configuredLevel = newValue; lock.unlock() }
    }
    static func warning(_ message: String) {
        let current = level
        if current == .all || current == .warning { print("[MySuperwall] \(message)") }
    }
    static func error(_ message: String) {
        if level != .none { print("[MySuperwall] \(message)") }
    }
}

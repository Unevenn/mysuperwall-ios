import Foundation

/// Decides whether a paywall prepared off-screen may be shown for a fresh resolution.
enum PrewarmPolicy {
    /// Only the exact same paywall with the exact same rendered HTML (language, prices) is
    /// reused; attribution fields are taken from the fresh resolution at presentation time.
    static func canReuse(prepared: PaywallData, for resolved: PaywallData) -> Bool {
        prepared.id == resolved.id && prepared.html == resolved.html
    }
}

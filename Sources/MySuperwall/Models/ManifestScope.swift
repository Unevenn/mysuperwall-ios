import Foundation
import CryptoKit

/// Language / region helpers. Language and country are independent: the manifest `lang`
/// is a normalized language tag, while country (used for audience rules) comes
/// from the device region unless explicitly overridden.
public enum LocaleSupport {
    /// Reduces a BCP-47 / POSIX locale identifier ("pt-BR", "pt_BR", "EN") to a lowercase
    /// language tag ("pt-br", "en"). Returns nil for blank or malformed input.
    public static func normalizeLanguage(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: "_", with: "-").lowercased()
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first, (2...3).contains(language.count),
              language.allSatisfy({ $0.isASCII && $0.isLetter }),
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.count <= 8 && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) }) else { return nil }
        return normalized
    }

    /// Normalizes an ISO 3166-1 alpha-2 region ("us" -> "US"). Nil for invalid input.
    public static func normalizeCountry(_ raw: String?) -> String? {
        guard let upper = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              upper.count == 2,
              upper.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return nil }
        return upper
    }

    /// Primary language subtag: "tr-tr" -> "tr", "pt-br" -> "pt".
    public static func baseLanguage(_ tag: String) -> String {
        String(tag.split(separator: "-", maxSplits: 1).first ?? Substring(tag))
    }

    /// True when `requested` is a bare language ("tr") that `current` ("tr-tr") already
    /// satisfies, so switching would only lose the cache without changing the paywall language.
    static func isSatisfied(requested: String, by current: String) -> Bool {
        !requested.contains("-") && baseLanguage(current) == requested
    }

    /// Device preferred language, falling back to the current locale and finally "en".
    public static func deviceLanguage() -> String {
        if let preferred = normalizeLanguage(Locale.preferredLanguages.first) { return preferred }
        if let code = normalizeLanguage(Locale.current.languageCode) { return code }
        return "en"
    }

    /// Device region (independent of the language).
    public static func deviceCountry() -> String? {
        normalizeCountry(Locale.current.regionCode)
    }
}

/// Identifies which manifest a cache entry / network response belongs to.
public struct ManifestScope: Equatable, Hashable {
    public let baseURL: String
    public let appKey: String
    public let appIdentifier: String
    public let platform: String
    public let priceFingerprint: String
    public let lang: String

    public init(baseURL: String, appKey: String?, appIdentifier: String?, platform: String, lang: String, priceFingerprint: String = "") {
        self.baseURL = ManifestScope.normalizeBaseURL(baseURL)
        self.appKey = (appKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.appIdentifier = (appIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.priceFingerprint = priceFingerprint
        self.platform = platform.lowercased()
        self.lang = LocaleSupport.normalizeLanguage(lang) ?? "en"
    }

    /// Same app, platform and prices; only a regional variant of the same language differs.
    func isLanguageVariant(of other: ManifestScope) -> Bool {
        baseURL == other.baseURL && appKey == other.appKey && appIdentifier == other.appIdentifier
            && platform == other.platform && priceFingerprint == other.priceFingerprint
            && lang != other.lang && LocaleSupport.baseLanguage(lang) == LocaleSupport.baseLanguage(other.lang)
    }

    static func fingerprint(_ products: [String: Any]) -> String {
        guard !products.isEmpty, let data = try? JSONSerialization.data(withJSONObject: products, options: [.sortedKeys]) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercases scheme/host, drops default ports, query, fragment and trailing slashes.
    static func normalizeBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed), comps.host != nil else {
            return trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        comps.scheme = comps.scheme?.lowercased()
        comps.host = comps.host?.lowercased()
        if (comps.scheme == "https" && comps.port == 443) || (comps.scheme == "http" && comps.port == 80) {
            comps.port = nil
        }
        comps.query = nil
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path
        return comps.string ?? trimmed
    }

    private struct Canonical: Codable {
        let v: Int
        let baseURL: String
        let appKey: String
        let appIdentifier: String
        let platform: String
        let lang: String
    }

    /// Cache key: SHA-256 over canonical (sorted-key) JSON of the whole scope. JSON string
    /// encoding is unambiguous, so differing scopes cannot collide by concatenation, and the
    /// raw appKey never appears in the key.
    public var cacheKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Canonical(v: 1, baseURL: baseURL, appKey: appKey,
                                                   appIdentifier: appIdentifier, platform: platform, lang: lang))) ?? Data()
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "mysuperwall_manifest_v2_\(hex)" + (priceFingerprint.isEmpty ? "" : "_prices_" + priceFingerprint)
    }
}

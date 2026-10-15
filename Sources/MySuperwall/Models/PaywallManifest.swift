import Foundation

public struct ManifestCondition: Codable, Equatable {
    public let field: String
    public let `operator`: String
    public let value: AnyCodableValue?

    public init(field: String, `operator`: String, value: AnyCodableValue?) {
        self.field = field
        self.`operator` = `operator`
        self.value = value
    }
}

public struct ManifestVariant: Codable, Equatable {
    public let variantId: String?
    public let variantLabel: String?
    public let variant: String
    public let weight: Int
    public let paywallId: String?

    public init(variant: String, weight: Int, paywallId: String?, variantId: String? = nil, variantLabel: String? = nil) {
        self.variantId = variantId
        self.variantLabel = variantLabel
        self.variant = variant
        self.weight = weight
        self.paywallId = paywallId
    }
}

public struct ManifestRule: Codable, Equatable {
    public let experimentId: String?
    public let experimentVersion: String?
    public let audienceId: String?
    public let id: String
    public let name: String
    public let priority: Int
    public let matchType: String
    public let conditions: [ManifestCondition]
    public let holdoutPercentage: Int
    public let paywallId: String?
    public let variants: [ManifestVariant]

    public init(
        id: String,
        name: String,
        priority: Int = 0,
        matchType: String = "all",
        conditions: [ManifestCondition] = [],
        holdoutPercentage: Int = 0,
        paywallId: String? = nil,
        variants: [ManifestVariant] = [],
        experimentId: String? = nil,
        experimentVersion: String? = nil,
        audienceId: String? = nil
    ) {
        self.experimentId = experimentId
        self.experimentVersion = experimentVersion
        self.audienceId = audienceId
        self.id = id
        self.name = name
        self.priority = priority
        self.matchType = matchType
        self.conditions = conditions
        self.holdoutPercentage = holdoutPercentage
        self.paywallId = paywallId
        self.variants = variants
    }
}

public struct ManifestDismissAction: Codable, Equatable {
    public let type: String
    public let followUpPaywallId: String?

    public init(type: String = "none", followUpPaywallId: String? = nil) {
        self.type = type
        self.followUpPaywallId = followUpPaywallId
    }
}

public struct ManifestTrigger: Codable, Equatable {
    public let experimentId: String?
    public let experimentVersion: String?
    public let audienceId: String?
    public let id: String
    public let key: String
    public let prewarmPriority: Int?
    public let holdoutPercentage: Int?
    public let paywallId: String?
    public let variants: [ManifestVariant]
    public let rules: [ManifestRule]
    public let dismissAction: ManifestDismissAction?

    public init(
        id: String,
        key: String,
        prewarmPriority: Int? = 0,
        holdoutPercentage: Int? = 0,
        paywallId: String? = nil,
        variants: [ManifestVariant] = [],
        rules: [ManifestRule] = [],
        dismissAction: ManifestDismissAction? = nil,
        experimentId: String? = nil,
        experimentVersion: String? = nil,
        audienceId: String? = nil
    ) {
        self.experimentId = experimentId
        self.experimentVersion = experimentVersion
        self.audienceId = audienceId
        self.id = id
        self.key = key
        self.prewarmPriority = prewarmPriority
        self.holdoutPercentage = holdoutPercentage
        self.paywallId = paywallId
        self.variants = variants
        self.rules = rules
        self.dismissAction = dismissAction
    }
}

public struct ManifestPaywallProduct: Codable, Equatable {
    public let productId: String
    public let variableName: String?

    public init(productId: String, variableName: String? = nil) {
        self.productId = productId
        self.variableName = variableName
    }
}

/// Automatic follow-up configuration carried in a paywall's `contentJson.followUpRules`.
/// Only `actionType == "trigger"` is supported; other action types are ignored.
public struct ManifestFollowUpRule: Codable, Equatable {
    public let enabled: Bool
    public let actionType: String
    public let triggerKey: String?
    public let delayMs: Int
    public let oncePerSession: Bool
    public let cooldownMs: Int
    public let maxChainDepth: Int
    public let skipIfPremium: Bool
    public let preventRepeatPaywall: Bool

    public init(
        enabled: Bool = false,
        actionType: String = "trigger",
        triggerKey: String? = nil,
        delayMs: Int = 0,
        oncePerSession: Bool = true,
        cooldownMs: Int = 0,
        maxChainDepth: Int = 2,
        skipIfPremium: Bool = false,
        preventRepeatPaywall: Bool = true
    ) {
        self.enabled = enabled
        self.actionType = actionType
        self.triggerKey = triggerKey
        self.delayMs = min(10000, max(0, delayMs))
        self.oncePerSession = oncePerSession
        self.cooldownMs = min(86400000, max(0, cooldownMs))
        self.maxChainDepth = min(5, max(1, maxChainDepth))
        self.skipIfPremium = skipIfPremium
        self.preventRepeatPaywall = preventRepeatPaywall
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, actionType, triggerKey, delayMs, oncePerSession
        case cooldownMs, maxChainDepth, skipIfPremium, preventRepeatPaywall
    }

    /// Tolerant decoding: JSON numbers may arrive as Int or Double, missing keys take defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys, _ fallback: Int) -> Int {
            if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
            if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
            return fallback
        }
        func bool(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? fallback
        }
        self.init(
            enabled: bool(.enabled, false),
            actionType: ((try? c.decodeIfPresent(String.self, forKey: .actionType)) ?? nil) ?? "trigger",
            triggerKey: (try? c.decodeIfPresent(String.self, forKey: .triggerKey)) ?? nil,
            delayMs: max(0, int(.delayMs, 0)),
            oncePerSession: bool(.oncePerSession, true),
            cooldownMs: max(0, int(.cooldownMs, 0)),
            maxChainDepth: max(0, int(.maxChainDepth, 2)),
            skipIfPremium: bool(.skipIfPremium, false),
            preventRepeatPaywall: bool(.preventRepeatPaywall, true)
        )
    }
}

/// Decodes one rule without letting a malformed rule invalidate the whole manifest.
private struct LossyFollowUpRule: Codable {
    let rule: ManifestFollowUpRule?
    init(_ rule: ManifestFollowUpRule) { self.rule = rule }
    init(from decoder: Decoder) throws { rule = try? ManifestFollowUpRule(from: decoder) }
    func encode(to encoder: Encoder) throws { try rule?.encode(to: encoder) }
}

private struct PaywallContentJson: Codable {
    let followUpRules: [String: LossyFollowUpRule]?
}

public struct ManifestPaywall: Codable, Equatable {
    public let publishedVersion: Int?
    public let id: String
    public let name: String
    public let templateKey: String
    public let html: String
    public let productIds: [String]
    public let products: [ManifestPaywallProduct]
    /// Keyed by `onDismiss` / `onPurchase` / `onPurchaseFailed` / `onRestore`.
    public let followUpRules: [String: ManifestFollowUpRule]

    public init(
        id: String,
        name: String,
        templateKey: String,
        html: String,
        productIds: [String] = [],
        products: [ManifestPaywallProduct] = [],
        publishedVersion: Int? = nil,
        followUpRules: [String: ManifestFollowUpRule] = [:]
    ) {
        self.publishedVersion = publishedVersion
        self.id = id
        self.name = name
        self.templateKey = templateKey
        self.html = html
        self.productIds = productIds
        self.products = products
        self.followUpRules = followUpRules
    }

    private enum CodingKeys: String, CodingKey {
        case publishedVersion, id, name, templateKey, html, productIds, products, contentJson
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        publishedVersion = try c.decodeIfPresent(Int.self, forKey: .publishedVersion)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        templateKey = try c.decode(String.self, forKey: .templateKey)
        html = try c.decode(String.self, forKey: .html)
        productIds = try c.decodeIfPresent([String].self, forKey: .productIds) ?? []
        products = try c.decodeIfPresent([ManifestPaywallProduct].self, forKey: .products) ?? []
        let content = (try? c.decodeIfPresent(PaywallContentJson.self, forKey: .contentJson)) ?? nil
        followUpRules = (content?.followUpRules ?? [:]).compactMapValues { $0.rule }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(publishedVersion, forKey: .publishedVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(templateKey, forKey: .templateKey)
        try c.encode(html, forKey: .html)
        try c.encode(productIds, forKey: .productIds)
        try c.encode(products, forKey: .products)
        if !followUpRules.isEmpty {
            try c.encode(PaywallContentJson(followUpRules: followUpRules.mapValues(LossyFollowUpRule.init)), forKey: .contentJson)
        }
    }
}

public struct PaywallManifest: Codable, Equatable {
    public let ok: Bool
    public let notModified: Bool?
    public let hash: String?
    public let appId: String?
    public let triggers: [ManifestTrigger]
    public let paywalls: [String: ManifestPaywall]

    public init(
        ok: Bool,
        notModified: Bool? = false,
        hash: String? = nil,
        appId: String? = nil,
        triggers: [ManifestTrigger] = [],
        paywalls: [String: ManifestPaywall] = [:]
    ) {
        self.ok = ok
        self.notModified = notModified
        self.hash = hash
        self.appId = appId
        self.triggers = triggers
        self.paywalls = paywalls
    }

    public func findTrigger(_ key: String) -> ManifestTrigger? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return triggers.first {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }
}

/// Helper for Codable dynamic values (String, Int, Double, Bool, Array)
public enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else if let arrVal = try? container.decode([AnyCodableValue].self) {
            self = .array(arrVal)
        } else {
            self = .string("")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        }
    }

    public var rawValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map { $0.rawValue }
        }
    }

    public var stringValue: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .array(let a): return a.map { $0.stringValue }.joined(separator: ",")
        }
    }
}

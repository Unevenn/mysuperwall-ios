import Foundation
import CryptoKit

public struct RuleEngineResolution: Equatable {
    public let show: Bool
    public let paywallId: String?
    public let abVariant: String?
    public let matchedRuleName: String?
    public let matchedRuleId: String?
    public let isHoldout: Bool
    public let reason: String

    public init(
        show: Bool,
        paywallId: String? = nil,
        abVariant: String? = nil,
        matchedRuleName: String? = nil,
        matchedRuleId: String? = nil,
        isHoldout: Bool = false,
        reason: String = ""
    ) {
        self.show = show
        self.paywallId = paywallId
        self.abVariant = abVariant
        self.matchedRuleName = matchedRuleName
        self.matchedRuleId = matchedRuleId
        self.isHoldout = isHoldout
        self.reason = reason
    }
}

public final class LocalRuleEngine {
    public init() {}

    /// Deterministic sticky bucket from 0 to 99 matching backend SHA256 logic.
    public func getDeterministicBucket(userId: String?, salt: String = "") -> Int {
        guard let userId = userId, !userId.isEmpty else {
            return Int.random(in: 0..<100)
        }
        let input = "\(userId):\(salt)"
        guard let data = input.data(using: .utf8) else { return 0 }
        let digest = SHA256.hash(data: data)
        let bytes = Array(digest)
        guard bytes.count >= 4 else { return 0 }
        let u32 = (UInt32(bytes[0]) << 24) |
                  (UInt32(bytes[1]) << 16) |
                  (UInt32(bytes[2]) << 8)  |
                  UInt32(bytes[3])
        return Int(u32 % 100)
    }

    /// Compares two semantic version strings (e.g. "1.2.0" vs "1.2.1").
    public func compareVersions(_ v1: String?, _ v2: String?) -> Int {
        let clean1 = (v1 ?? "").replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        let clean2 = (v2 ?? "").replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        let p1 = clean1.split(separator: ".").compactMap { Int($0) }
        let p2 = clean2.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(p1.count, p2.count)
        for i in 0..<maxLen {
            let n1 = i < p1.count ? p1[i] : 0
            let n2 = i < p2.count ? p2[i] : 0
            if n1 > n2 { return 1 }
            if n1 < n2 { return -1 }
        }
        return 0
    }

    /// Resolves nested fields like "metadata.tier" or direct "platform".
    public func resolveContextValue(field: String, context: [String: Any]) -> Any? {
        if let direct = context[field] { return direct }
        let parts = field.split(separator: ".").map { String($0) }
        var current: Any? = context
        for part in parts {
            if let dict = current as? [String: Any] {
                current = dict[part]
            } else {
                return nil
            }
        }
        return current
    }

    /// Evaluates a single condition.
    public func evaluateCondition(condition: ManifestCondition, context: [String: Any]) -> Bool {
        let actual = resolveContextValue(field: condition.field, context: context)
        let op = condition.operator.lowercased()
        let target = condition.value

        switch op {
        case "equals", "eq":
            if let a = actual, let t = target {
                return String(describing: a).lowercased() == t.stringValue.lowercased()
            }
            return actual == nil && target == nil

        case "not_equals", "neq":
            if let a = actual, let t = target {
                return String(describing: a).lowercased() != t.stringValue.lowercased()
            }
            return !(actual == nil && target == nil)

        case "contains":
            guard let a = actual, let t = target else { return false }
            return String(describing: a).lowercased().contains(t.stringValue.lowercased())

        case "not_contains":
            guard let a = actual, let t = target else { return true }
            return !String(describing: a).lowercased().contains(t.stringValue.lowercased())

        case "gt", "gte", "lt", "lte":
            guard let a = actual, let t = target else { return false }
            guard let aNum = Double(String(describing: a)), let tNum = Double(t.stringValue) else {
                return false
            }
            switch op {
            case "gt": return aNum > tNum
            case "gte": return aNum >= tNum
            case "lt": return aNum < tNum
            case "lte": return aNum <= tNum
            default: return false
            }

        case "in_list", "in":
            guard let a = actual, let t = target else { return false }
            let aStr = String(describing: a).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch t {
            case .array(let arr):
                return arr.contains { $0.stringValue.lowercased() == aStr }
            default:
                let parts = t.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                return parts.contains(aStr)
            }

        case "not_in_list", "not_in":
            guard let a = actual, let t = target else { return true }
            let aStr = String(describing: a).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch t {
            case .array(let arr):
                return !arr.contains { $0.stringValue.lowercased() == aStr }
            default:
                let parts = t.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                return !parts.contains(aStr)
            }

        case "version_gt":
            guard let a = actual, let t = target else { return false }
            return compareVersions(String(describing: a), t.stringValue) > 0

        case "version_gte":
            guard let a = actual, let t = target else { return false }
            return compareVersions(String(describing: a), t.stringValue) >= 0

        case "version_lt":
            guard let a = actual, let t = target else { return false }
            return compareVersions(String(describing: a), t.stringValue) < 0

        case "version_lte":
            guard let a = actual, let t = target else { return false }
            return compareVersions(String(describing: a), t.stringValue) <= 0

        default:
            return false
        }
    }

    /// Checks if a rule matches given context.
    public func matchesRule(rule: ManifestRule, context: [String: Any]) -> Bool {
        if rule.conditions.isEmpty { return true }
        let isAny = rule.matchType.lowercased() == "any"
        if isAny {
            return rule.conditions.contains { evaluateCondition(condition: $0, context: context) }
        } else {
            return rule.conditions.allSatisfy { evaluateCondition(condition: $0, context: context) }
        }
    }

    /// Deterministically selects a variant respecting holdout.
    public func selectDeterministicVariant(
        userId: String?,
        salt: String,
        variants: [ManifestVariant],
        fallbackPaywallId: String?,
        holdoutPercentage: Int
    ) -> (paywallId: String?, abVariant: String?, isHoldout: Bool) {
        if holdoutPercentage > 0 {
            let holdoutBucket = getDeterministicBucket(userId: userId, salt: "\(salt):holdout")
            if holdoutBucket < holdoutPercentage {
                return (nil, nil, true)
            }
        }

        let validVariants = variants.filter { $0.paywallId != nil && !$0.paywallId!.isEmpty }
        if validVariants.isEmpty {
            return (fallbackPaywallId, "A", false)
        }

        let totalWeight = validVariants.reduce(0) { $0 + max(1, $1.weight) }
        if totalWeight <= 0 {
            let first = validVariants.first!
            return (first.paywallId, first.variant, false)
        }

        let bucket = getDeterministicBucket(userId: userId, salt: "\(salt):variant")
        let target = (bucket * totalWeight) / 100
        var cumulative = 0

        for v in validVariants {
            cumulative += max(1, v.weight)
            if target < cumulative {
                return (v.paywallId, v.variant, false)
            }
        }

        let last = validVariants.last!
        return (last.paywallId, last.variant, false)
    }

    /// Resolves a trigger in-memory with 0 ms latency.
    public func resolveTrigger(
        trigger: ManifestTrigger,
        userId: String?,
        context: [String: Any]
    ) -> RuleEngineResolution {
        // 1. Check priority-ordered audience rules
        let activeRules = trigger.rules.sorted { $0.priority > $1.priority }
        for rule in activeRules {
            if matchesRule(rule: rule, context: context) {
                let selection = selectDeterministicVariant(
                    userId: userId,
                    salt: rule.id,
                    variants: rule.variants,
                    fallbackPaywallId: rule.paywallId ?? trigger.paywallId,
                    holdoutPercentage: rule.holdoutPercentage
                )

                if selection.isHoldout {
                    return RuleEngineResolution(
                        show: false,
                        paywallId: nil,
                        abVariant: nil,
                        matchedRuleName: rule.name,
                        matchedRuleId: rule.id,
                        isHoldout: true,
                        reason: "rule_holdout"
                    )
                }

                if let pwId = selection.paywallId {
                    return RuleEngineResolution(
                        show: true,
                        paywallId: pwId,
                        abVariant: selection.abVariant ?? "A",
                        matchedRuleName: rule.name,
                        matchedRuleId: rule.id,
                        isHoldout: false,
                        reason: "rule_matched"
                    )
                }
            }
        }

        // 2. Fall back to root trigger variants & holdout
        let rootSelection = selectDeterministicVariant(
            userId: userId,
            salt: trigger.key,
            variants: trigger.variants,
            fallbackPaywallId: trigger.paywallId,
            holdoutPercentage: trigger.holdoutPercentage ?? 0
        )

        if rootSelection.isHoldout {
            return RuleEngineResolution(
                show: false,
                paywallId: nil,
                abVariant: nil,
                matchedRuleName: nil,
                isHoldout: true,
                reason: "root_holdout"
            )
        }

        if let pwId = rootSelection.paywallId {
            return RuleEngineResolution(
                show: true,
                paywallId: pwId,
                abVariant: rootSelection.abVariant ?? "A",
                matchedRuleName: nil,
                isHoldout: false,
                reason: "root_variant"
            )
        }

        return RuleEngineResolution(
            show: false,
            paywallId: nil,
            abVariant: nil,
            matchedRuleName: nil,
            isHoldout: false,
            reason: "no_paywall_mapped"
        )
    }
}

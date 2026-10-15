import Foundation

public struct ExperimentContext: Codable, Equatable {
    public let experimentId: String
    public let experimentVersion: String
    public let audienceId: String
    public let variantId: String
    public let variantLabel: String
    public let paywallId: String
    public let paywallVersion: Int

    public var dictionary: [String: Any] {
        return ["experimentId": experimentId, "experimentVersion": experimentVersion,
                "audienceId": audienceId, "variantId": variantId, "variantLabel": variantLabel,
                "paywallId": paywallId, "paywallVersion": paywallVersion]
    }
}

public struct PaywallData: Codable, Equatable {
    public let id: String
    public let name: String
    public let html: String
    public let productIds: [String]
    public let products: [ManifestPaywallProduct]
    public let triggerKey: String?
    public let abVariant: String?
    public let experimentContext: ExperimentContext?
    public let attributionUserId: String?
    public let attributionScope: String?

    public init(
        id: String,
        name: String,
        html: String,
        productIds: [String] = [],
        products: [ManifestPaywallProduct] = [],
        triggerKey: String? = nil,
        abVariant: String? = nil,
        experimentContext: ExperimentContext? = nil,
        attributionUserId: String? = nil,
        attributionScope: String? = nil
    ) {
        self.id = id
        self.name = name
        self.html = html
        self.productIds = productIds
        self.products = products
        self.triggerKey = triggerKey
        self.abVariant = abVariant
        self.experimentContext = experimentContext
        self.attributionUserId = attributionUserId
        self.attributionScope = attributionScope
    }
}

public struct PaywallResult: Codable, Equatable {
    public let show: Bool
    public let paywall: PaywallData?
    public let reason: String?

    public init(show: Bool, paywall: PaywallData? = nil, reason: String? = nil) {
        self.show = show
        self.paywall = paywall
        self.reason = reason
    }
}

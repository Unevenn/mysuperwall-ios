import XCTest
@testable import MySuperwall

final class LocalRuleEngineTests: XCTestCase {
    var engine: LocalRuleEngine!

    override func setUp() {
        super.setUp()
        engine = LocalRuleEngine()
    }

    func testDeterministicBucketConsistency() {
        let b1 = engine.getDeterministicBucket(userId: "user_abc", salt: "rule_1")
        let b2 = engine.getDeterministicBucket(userId: "user_abc", salt: "rule_1")
        let b3 = engine.getDeterministicBucket(userId: "user_abc", salt: "rule_2")

        XCTAssertEqual(b1, b2, "Same user and salt must yield identical bucket")
        XCTAssertTrue((0..<100).contains(b1))
        XCTAssertTrue((0..<100).contains(b3))
    }

    func testSemanticVersionComparison() {
        XCTAssertEqual(engine.compareVersions("1.2.0", "1.2.0"), 0)
        XCTAssertEqual(engine.compareVersions("1.2.1", "1.2.0"), 1)
        XCTAssertEqual(engine.compareVersions("1.1.9", "1.2.0"), -1)
        XCTAssertEqual(engine.compareVersions("2.0.0", "1.99.99"), 1)
        XCTAssertEqual(engine.compareVersions("1.0", "1.0.0"), 0)
    }

    func testConditionEvaluation() {
        let context: [String: Any] = [
            "platform": "ios",
            "appVersion": "2.5.0",
            "user": [
                "level": 10,
                "tier": "gold"
            ]
        ]

        // Equals
        let cond1 = ManifestCondition(field: "platform", operator: "equals", value: .string("ios"))
        XCTAssertTrue(engine.evaluateCondition(condition: cond1, context: context))

        let cond2 = ManifestCondition(field: "platform", operator: "equals", value: .string("android"))
        XCTAssertFalse(engine.evaluateCondition(condition: cond2, context: context))

        // Nested field & numeric gt
        let cond3 = ManifestCondition(field: "user.level", operator: "gte", value: .int(10))
        XCTAssertTrue(engine.evaluateCondition(condition: cond3, context: context))

        // Version comparison
        let cond4 = ManifestCondition(field: "appVersion", operator: "version_gte", value: .string("2.0.0"))
        XCTAssertTrue(engine.evaluateCondition(condition: cond4, context: context))

        let cond5 = ManifestCondition(field: "appVersion", operator: "version_lt", value: .string("2.0.0"))
        XCTAssertFalse(engine.evaluateCondition(condition: cond5, context: context))

        // In list
        let cond6 = ManifestCondition(field: "user.tier", operator: "in_list", value: .array([.string("silver"), .string("gold")]))
        XCTAssertTrue(engine.evaluateCondition(condition: cond6, context: context))
    }

    func testRuleMatchingAndResolution() {
        let trigger = ManifestTrigger(
            id: "trig_1",
            key: "onboarding_complete",
            paywallId: "pw_standard",
            rules: [
                ManifestRule(
                    id: "rule_high_value",
                    name: "VIP Users",
                    priority: 10,
                    conditions: [
                        ManifestCondition(field: "isVip", operator: "equals", value: .bool(true))
                    ],
                    paywallId: "pw_vip"
                )
            ]
        )

        // Non-VIP context
        let res1 = engine.resolveTrigger(
            trigger: trigger,
            userId: "u123",
            context: ["isVip": false]
        )
        XCTAssertTrue(res1.show)
        XCTAssertEqual(res1.paywallId, "pw_standard")

        // VIP context
        let res2 = engine.resolveTrigger(
            trigger: trigger,
            userId: "u123",
            context: ["isVip": true]
        )
        XCTAssertTrue(res2.show)
        XCTAssertEqual(res2.paywallId, "pw_vip")
        XCTAssertEqual(res2.matchedRuleName, "VIP Users")
    }

    func testHoldoutAllocation() {
        let trigger = ManifestTrigger(
            id: "trig_holdout",
            key: "feature_gate",
            holdoutPercentage: 100, // 100% holdout for testing
            paywallId: "pw_gate"
        )

        let res = engine.resolveTrigger(
            trigger: trigger,
            userId: "user_sample",
            context: [:]
        )
        XCTAssertFalse(res.show)
        XCTAssertTrue(res.isHoldout)
        XCTAssertEqual(res.reason, "root_holdout")
    }

    func testManifestDecoding() throws {
        let json = """
        {
            "ok": true,
            "hash": "abc123hash",
            "appId": "app_999",
            "triggers": [
                {
                    "id": "t1",
                    "key": "launch",
                    "paywallId": "pw1",
                    "variants": [
                        { "variant": "A", "weight": 50, "paywallId": "pw1" },
                        { "variant": "B", "weight": 50, "paywallId": "pw2" }
                    ],
                    "rules": []
                }
            ],
            "paywalls": {
                "pw1": {
                    "id": "pw1",
                    "name": "Holiday Special",
                    "templateKey": "tpl_holiday",
                    "html": "<html><body>Sale!</body></html>",
                    "productIds": ["com.app.pro.annual"],
                    "products": [
                        { "productId": "com.app.pro.annual", "variableName": "annual" }
                    ]
                }
            }
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(PaywallManifest.self, from: json)
        XCTAssertTrue(manifest.ok)
        XCTAssertEqual(manifest.hash, "abc123hash")
        XCTAssertEqual(manifest.triggers.count, 1)
        XCTAssertEqual(manifest.paywalls["pw1"]?.name, "Holiday Special")
        XCTAssertEqual(manifest.findTrigger("launch")?.id, "t1")
    }
}

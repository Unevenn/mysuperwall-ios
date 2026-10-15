# MySuperwall iOS SDK (Swift / SPM)

Native Swift SDK for [MySuperwall](https://mysuperwall.com). Remotely configure, evaluate, and display dynamic paywalls in your iOS apps using cached, on-device rule evaluation.

## Features

- **⚡ Local rule evaluation:** Evaluates audience rules and deterministic A/B variants locally in-memory on the device.
- **💾 Offline Cache:** Automatically caches active paywall manifests in `UserDefaults` for instant cold starts without network wait.
- **🔄 ETag / 304 Synchronization:** Background sync fetches updates with zero bandwidth waste when rules haven't changed.
- **🎨 HTML/CSS Dynamic Paywalls:** High-performance `WKWebView` rendering with native JavaScript-to-Swift bridge.
- **📊 Offline Event Queue:** Fire-and-forget analytics event batching to `POST /paywall/events/batch`.

## Installation

### Swift Package Manager

In Xcode, choose **File → Add Package Dependencies**, paste the URL below, and
select **Up to Next Major Version** starting at **1.2.0**:

```text
https://github.com/Unevenn/mysuperwall-ios
```

Add the `MySuperwall` library to your app target. In a Swift package manifest:

```swift
.package(url: "https://github.com/Unevenn/mysuperwall-ios", from: "1.2.0")
```

The target dependency is `.product(name: "MySuperwall", package: "mysuperwall-ios")`.
Requires iOS 14+ and Swift tools 5.9+. The SDK has no external package dependencies.
This public repository contains SDK source and tests, with a separate release history.
Existing local snapshot installations remain supported; use only one SDK installation.

## Quick Start

### 1. Initialize on App Launch

In your `AppDelegate` or SwiftUI `App`:

```swift
import MySuperwall

@main
struct MyApp: App {
    init() {
        MySuperwall.initialize(appKey: "YOUR_APP_KEY")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

### 2. Trigger a Paywall

Present a paywall over any `UIViewController` with zero network delay:

```swift
MySuperwall.shared.handleTrigger(
    presentingController: self,
    triggerKey: "onboarding_finish",
    onPurchase: { productId in
        print("User requested purchase for: \(productId)")
        // Call your StoreKit 2 / RevenueCat purchase flow here
    },
    onRestore: {
        print("User requested restore")
    },
    onDismiss: {
        print("Paywall dismissed")
    }
)
```

### 3. User Attributes & Identification

```swift
// Identify registered users
MySuperwall.shared.identify(userId: "user_12345")

// Set custom attributes for audience targeting
MySuperwall.shared.setUserAttributes([
    "tier": "gold",
    "level": 12,
    "isSubscriber": false
])
```


### Experiment attribution

Manifest resolution retains optional server-issued experiment, audience, variant and
published-paywall version identifiers. Older manifests remain usable without this
context. Fetching or resolving alone does not record an impression. Built-in UI
records `paywall_shown` after the page loads while displayed; custom presenters
must call `trackPaywallEvent` when they actually show the paywall.

Purchase and restore button requests record `purchase_started` and
`restore_started`, not successful transactions. After your billing provider confirms
a purchase, pass the **original displayed paywall** to the SDK:

```
MySuperwall.shared.trackPaywallEvent(type: "purchase_success", paywall: displayedPaywall, productId: productId)
```

Do not resolve the trigger again to attribute a completed purchase. An identity
change invalidates attribution from the previous user's paywall. Offline retries
retain the original event ID and context; events are removed by acknowledged ID.
Verified revenue remains a separate backend/provider concern.

## Language, country and cache isolation

```swift
MySuperwall.initialize(appKey: "KEY", locale: "tr")   // optional; default = device language
MySuperwall.shared.setLocale("pt-BR")                 // -> lang "pt-br"; nil = device language
MySuperwall.shared.setCountry("DE")                   // audience-rule country only; nil = device region
```

- `lang` (sent in the `POST /paywall/manifest` body) is the normalized lowercase language tag.
  Country is a separate value used for audience rules and never changes the language or cache.
- The manifest cache is keyed by SHA-256 of a canonical JSON of
  `baseURL / appKey / bundle id / platform / lang` (the raw app key is never stored in a key).
  Changing any of them clears the in-memory manifest first and loads only that scope's entry.
  The old unscoped cache entry is never read (and is removed).
- `setLocale` and a repeated `initialize` cancel pending follow-ups, reload the matching cache and
  refresh in the background. Responses (including `304`) that return after the scope changed are
  discarded and cannot write memory or disk.
- Limitation: the offline analytics event queue is shared across scopes (events are not
  re-targeted if `initialize` is called with a different app key).

## Automatic follow-up paywalls

Follow-ups are read from the manifest only; nothing extra is fetched.

1. **Per-paywall rules** (`contentJson.followUpRules`: `onDismiss`, `onPurchase`,
   `onPurchaseFailed`, `onRestore`). Only `actionType: "trigger"` is supported; other action
   types are ignored. Fields: `enabled`, `triggerKey`, `delayMs`, `oncePerSession`, `cooldownMs`,
   `maxChainDepth` (default 2, hard cap 5), `skipIfPremium`, `preventRepeatPaywall` (default true).
2. **Legacy root `Trigger.dismissAction`** `{type: "follow_up_paywall", followUpPaywallId}`: used
   only for the dismissal of a root paywall, when no enabled `onDismiss` rule exists. It presents
   at most one fallback and never the paywall that was just dismissed.

Behaviour:

- Presentation happens only after the previous paywall UI is actually gone and the presenting
  controller is still on screen with nothing else presented; otherwise the follow-up is dropped.
  `onDismiss` is invoked exactly once per presented paywall.
- Purchase/restore rules react only to **host-confirmed** events passed to
  `trackPaywallEvent(type:paywall:)`: `purchase`, `purchase_success`, `purchase_failed`,
  `restore`, `restore_success`. Button taps (`purchase_started`, `restore_started`) never fire
  them. The signal is recorded for the paywall currently shown by the SDK and acted on once
  that paywall is dismissed, so UI never stacks. Call `trackPaywallEvent` **before** closing
  (e.g. before `dismissActivePaywall()`); a signal for an already-closed paywall is ignored.
  A confirmed purchase/restore with no rule does not trigger the dismiss fallback.
- Delay (`delayMs`) is counted from the actual dismissal. Rules are re-checked when the delay
  elapses (premium status, session/cooldown limits, chain depth).
- `skipIfPremium` uses `MySuperwall.shared.setSubscriptionStatus(.active / .inactive / .unknown)`,
  which you must call from your billing layer. It resets to `.unknown` when the user changes.
- Identity change (`identify` with a different id), scope change, `setLocale` and re-`initialize`
  cancel delayed follow-ups and reset session counters.
- Follow-up paywalls carry no A/B variant or experiment context (no false attribution), keep the
  original user binding, and do not record a synthetic `paywall_shown`; the built-in UI records it
  only when the follow-up is actually displayed.
- Not supported: non-`trigger` action types, scheduled publications, follow-ups for paywalls
  you present with your own UI, and the exact Flutter defaults for fields omitted from a rule
  (the defaults above are this SDK's own).

Offline analytics queues are isolated by server and app scope. Unscoped legacy queues
are retained on disk but never sent under a new app identity.

## Localized store prices (1.2.0+)

This SDK does not query StoreKit, Google Play Billing or RevenueCat products itself.
Initialize the existing billing provider and fetch its products first. Build a map
keyed by the exact store product ID. Each value must contain `displayPrice`,
`priceString` and `currencyCode` from the store. Supply `subscriptionPeriod` and
store-derived `pricePerDayText`, `pricePerWeekText`, `pricePerMonthText`,
`pricePerYearText` where the template uses them. Never convert a USD catalog price
using device locale or exchange rates. Storefront determines the currency.

Call `setProductData` after SDK initialization and before presenting. Await its
completion (Promise on React Native, callback on native platforms) and refresh it
when store product prices change. Missing live product data is not proof that
catalog/default prices are localized. Wait for successful manifest loading on a
first installation. Existing displayed paywalls are not silently replaced.

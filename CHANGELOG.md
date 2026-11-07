## 1.7.0 — 2026-11-07

- Add `trackPurchaseSuccess`, `trackPurchaseFailed`, `trackPurchaseCancelled` and
  `trackRestoreSuccess`. `onPurchase` only carries a product ID, so reporting used to
  need a paywall object that automatic paywalls never provided. The SDK now attributes
  results to the paywall whose button was tapped. Passing a store transaction ID lets
  the server count one purchase once. `trackPaywallEvent` keeps working.
- Apply dashboard display limits to custom triggers on the device. These limits
  were not enforced by this SDK before. `handleTrigger` now returns
  `display_limit` without a request when a limit is reached.
- Apply lifecycle trigger schedules and display limits on the device: start
  open, wait, repeat interval, total and period caps, closes without buying and
  hiding from subscribers. Blocked opens make no request. The manifest refreshes
  at most every 10 minutes instead of every minute, a trigger that did not show
  is not retried on every tick, and `lifecycle_status` diagnostics are limited to
  eligible triggers plus one daily activity signal.

## 1.6.0 — 2026-11-01

- Add persistent automatic lifecycle signals, readiness gating, foreground-only
  active time and 30-day deferred evaluation, with visibility-based completion.
- Add durable minute/session/foreground follow-up policies and lifecycle debugger reasons.
- Distinguish purchase cancellation, preserve disabled-rule intent, and guard overlapping delivery.
- Add shared presentation configuration, smooth custom transitions, reduced motion and instant open/close.
- Keep existing billing APIs and document updated-source integration separately from published releases.
- Device billing, motion smoothness and long-running timed delivery remain unverified.

## 1.5.1 - 2026-10-30

- Revalidate before presentation/prewarming and stop cached or native fallback delivery when a trigger/paywall is disabled or the server cannot be reached.
- Keep current handleTrigger call syntax; its immediate result is validation_pending. Observe the final result via onResult; React Native also provides handleTriggerAsync.
- Pause hidden/backgrounded CSS/Web Animations, animation-frame loops and media without blocking SDK paint readiness. Preserve host/presenter lifecycle and reject stale requests after identity, locale or product-data changes.

# Changelog

## 1.5.0 - 2026-10-26

- Add optional push notifications: `setPushToken(_:)` / `clearPushToken()` register the app's FCM token for the current user and language (no Firebase dependency in the SDK), `trackNotificationOpened(userInfo:)` reports a tap and returns the trigger to open, and `handleNotificationOpened(presentingController:userInfo:)` also presents it.

## 1.4.0 - 2026-10-18

- Add `prewarm(triggerKey:metadata:)`: one paywall is resolved and loaded off-screen so the next
  matching `handleTrigger` presents instantly. Single slot, rebuilt after manifest, locale,
  product-data or user changes and after use, released on memory warnings, `dispose()` and
  `releasePrewarmedPaywall()`. Reused only for the same paywall id and rendered HTML.
- `setLocale` no longer drops the manifest for the same app language: a bare language covered by
  the active one ("tr" while "tr-tr") is a no-op, and a regional variant without a cache keeps
  serving the current manifest until its own sync succeeds (previously `handleTrigger` could
  return `show: false` until the network refresh finished).
- `setProductData` with an unchanged payload no longer starts a manifest request; the completion
  receives the current manifest.
- Document "prepare once at startup": `initialize(locale:)`, `setProductData` once, `prewarm`.

## 1.3.0

- Add configurable SDK log levels, defaulting to warnings and errors.
- Remove the public custom base URL initialization option; use the fixed MySuperWall service endpoint.
- Add per-trigger paywall lifecycle state observation.
- Guard against duplicate presentations and stale visibility callbacks.
- Count impressions once per displayed session after WebView paint readiness and foreground visibility checks.
- Add explicit SDK cleanup for pending recovery and manifest work.

## 1.2.0 - 2026-10-15

- Add setProductData for real localized billing prices and currency.
- Scope rendered HTML caches by the exact price payload, rejecting late responses from previous price contexts.
- Keep existing billing and store purchase flows owned by the host application.

## 1.1.0

- Break the WebKit message-handler retain cycle with a weak forwarding handler.
- Restrict purchase messages to the main frame and reject empty product identifiers.
- Include the MIT license.

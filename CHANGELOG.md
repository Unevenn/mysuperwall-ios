# Changelog

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

## 1.3.0

- Add configurable SDK log levels, defaulting to warnings and errors.
- Remove the public custom base URL initialization option; use the fixed MySuperWall service endpoint.
- Add per-trigger paywall lifecycle state observation.
- Guard against duplicate presentations and stale visibility callbacks.
- Count impressions once per displayed session after WebView paint readiness and foreground visibility checks.
- Add explicit SDK cleanup for pending recovery and manifest work.

# Changelog

## 1.2.0 - 2026-10-15

- Add setProductData for real localized billing prices and currency.
- Scope rendered HTML caches by the exact price payload, rejecting late responses from previous price contexts.
- Keep existing billing and store purchase flows owned by the host application.

## 1.1.0

- Break the WebKit message-handler retain cycle with a weak forwarding handler.
- Restrict purchase messages to the main frame and reject empty product identifiers.
- Include the MIT license.

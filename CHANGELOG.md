# Changelog

## 1.2.0 - 2026-10-15

- Add setProductData for real localized billing prices and currency.
- Scope rendered HTML caches by the exact price payload, rejecting late responses from previous price contexts.
- Keep existing billing and store purchase flows owned by the host application.

## 1.1.0

- Break the WebKit message-handler retain cycle with a weak forwarding handler.
- Restrict purchase messages to the main frame and reject empty product identifiers.
- Include the MIT license.

#if canImport(UIKit)
import UIKit
import WebKit

public protocol PaywallDelegate: AnyObject {
    func paywallDidRequestPurchase(productId: String)
    func paywallDidRequestRestore()
    func paywallDidDismiss()
    func paywallDidOpenUrl(url: URL)
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

public final class PaywallWebViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
    public weak var delegate: PaywallDelegate?
    public let paywall: PaywallData

    private var webView: WKWebView!
    private var didTrackShown = false
    private var didTrackDismiss = false
    private var didNotifyDismiss = false
    private var htmlLoaded = false
    private let messageHandlerName = "MySuperWall"

    public init(paywall: PaywallData, delegate: PaywallDelegate? = nil) {
        self.paywall = paywall
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebView()
        loadPaywallHtml()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        trackShownIfReady()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Covers dismissals not initiated by the page's close action (host code, system).
        // Merely being covered by another presentation is not a dismissal.
        guard isBeingDismissed || isMovingFromParent else { return }
        DispatchQueue.main.async { [weak self] in self?.notifyDismissedOnce() }
    }

    /// Tracks the dismissal and informs the delegate exactly once, after the UI is gone.
    private func notifyDismissedOnce() {
        guard !didNotifyDismiss else { return }
        didNotifyDismiss = true
        if !didTrackDismiss && didTrackShown {
            didTrackDismiss = true
            MySuperwall.shared.trackPaywallEvent(type: "paywall_dismissed", paywall: paywall)
        }
        delegate?.paywallDidDismiss()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        htmlLoaded = true
        trackShownIfReady()
    }

    private func trackShownIfReady() {
        guard htmlLoaded, view.window != nil, !didTrackShown else { return }
        didTrackShown = true
        MySuperwall.shared.trackPaywallEvent(type: "paywall_shown", paywall: paywall)
    }

    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        // Inject bridge script so window.MySuperWall.postMessage works identical to Flutter
        let bridgeJs = """
        window.MySuperWall = {
            postMessage: function(message) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.MySuperWall) {
                    window.webkit.messageHandlers.MySuperWall.postMessage(message);
                }
            }
        };
        """
        let userScript = WKUserScript(
            source: bridgeJs,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(userScript)
        contentController.add(WeakScriptMessageHandler(self), name: messageHandlerName)
        configuration.userContentController = contentController

        webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false

        view.addSubview(webView)
    }

    private func loadPaywallHtml() {
        webView.loadHTMLString(paywall.html, baseURL: URL(string: "https://mysuperwall.com"))
    }

    // MARK: - WKScriptMessageHandler
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == messageHandlerName, message.frameInfo.isMainFrame else { return }

        var payload: [String: Any]?
        if let dict = message.body as? [String: Any] {
            payload = dict
        } else if let str = message.body as? String,
                  let data = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = json
        }

        guard let payload = payload else { return }
        let type = ((payload["action"] as? String) ?? (payload["type"] as? String) ?? "").lowercased()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch type {
            case "purchase":
                let productId = (payload["productId"] as? String) ??
                                (payload["product_id"] as? String) ?? ""
                guard !productId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                MySuperwall.shared.trackPaywallEvent(type: "purchase_started", paywall: self.paywall, productId: productId)
                self.delegate?.paywallDidRequestPurchase(productId: productId)

            case "restore":
                MySuperwall.shared.trackPaywallEvent(type: "restore_started", paywall: self.paywall)
                self.delegate?.paywallDidRequestRestore()

            case "close", "dismiss":
                guard !self.didTrackDismiss, !self.didNotifyDismiss else { return }
                self.didTrackDismiss = true
                MySuperwall.shared.trackPaywallEvent(type: "paywall_dismissed", paywall: self.paywall)
                self.dismiss(animated: true) {
                    self.notifyDismissedOnce()
                }

            case "open_url", "openurl":
                if let urlStr = payload["url"] as? String, let url = URL(string: urlStr) {
                    self.delegate?.paywallDidOpenUrl(url: url)
                }

            default:
                break
            }
        }
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
    }
}
#endif

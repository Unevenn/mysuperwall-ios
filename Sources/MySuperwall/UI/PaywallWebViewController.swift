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
    public private(set) var paywall: PaywallData

    private var webView: WKWebView!
    private var didTrackShown = false
    private var didTrackDismiss = false
    private var didNotifyDismiss = false
    private var htmlLoaded = false
    private var appeared = false
    private var loadFailed = false
    private var navigationFinished = false
    /// Loaded off-screen by `MySuperwall.prewarm`; reports no state and handles no page actions
    /// until `activatePrewarmed` hands it to a real presentation.
    private var isPrewarming = false
    private var foregroundObserver: NSObjectProtocol?

    private let messageHandlerName = "MySuperWall"

    public convenience init(paywall: PaywallData, delegate: PaywallDelegate? = nil) {
        self.init(paywall: paywall, delegate: delegate, prewarmed: false)
    }

    init(paywall: PaywallData, delegate: PaywallDelegate?, prewarmed: Bool) {
        self.paywall = paywall
        self.delegate = delegate
        self.isPrewarming = prewarmed
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    /// A prepared controller that loaded without error and was never handed out.
    var isReusablePrewarm: Bool {
        isPrewarming && !loadFailed && presentingViewController == nil && parent == nil
    }

    /// Hands a prewarmed controller to a presentation. `paywall` carries this presentation's
    /// attribution (trigger, variant, user, scope); its id and HTML match the loaded page.
    func activatePrewarmed(paywall: PaywallData, delegate: PaywallDelegate?) {
        guard isPrewarming else { return }
        self.paywall = paywall
        self.delegate = delegate
        isPrewarming = false
        report(.loading)
        if navigationFinished { report(.ready) }
    }

    private func report(_ state: PaywallState) {
        guard !isPrewarming else { return }
        MySuperwall.shared.updatePaywallState(paywall, state)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebView()
        loadPaywallHtml()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.trackShownIfReady() }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        // A page loaded off-screen may not have painted yet; probe again now that it is visible.
        if navigationFinished && !htmlLoaded { requestPaintSignal() }
        trackShownIfReady()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        appeared = false
        // Covers dismissals not initiated by the page's close action (host code, system).
        // Merely being covered by another presentation is not a dismissal.
        guard isBeingDismissed || isMovingFromParent else { return }
        DispatchQueue.main.async { [weak self] in self?.notifyDismissedOnce() }
    }

    /// Tracks the dismissal and informs the delegate exactly once, after the UI is gone.
    private func notifyDismissedOnce() {
        guard !didNotifyDismiss else { return }
        didNotifyDismiss = true
        report(.dismissed)
        if !didTrackDismiss && didTrackShown {
            didTrackDismiss = true
            MySuperwall.shared.trackPaywallEvent(type: "paywall_dismissed", paywall: paywall)
        }
        delegate?.paywallDidDismiss()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !loadFailed else { return }
        navigationFinished = true
        report(.ready)
        requestPaintSignal()
    }

    private func requestPaintSignal() {
        webView.evaluateJavaScript("requestAnimationFrame(function(){requestAnimationFrame(function(){window.webkit.messageHandlers.MySuperWall.postMessage({action:'__msw_painted'});});});")
    }

    private func trackShownIfReady() {
        guard !isPrewarming, htmlLoaded, appeared, !loadFailed, !didNotifyDismiss,
              !isBeingDismissed, presentedViewController == nil,
              UIApplication.shared.applicationState == .active,
              view.window != nil, !didTrackShown else { return }
        didTrackShown = true
        MySuperwall.shared.updatePaywallState(paywall, .visible)
        MySuperwall.shared.trackPaywallEvent(type: "paywall_shown", paywall: paywall)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failLoad() }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failLoad() }
    private func failLoad() {
        loadFailed = true
        report(.failed)
        MySuperwallLogging.warning("Paywall navigation failed.")
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
        report(.loading)
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
            guard !self.didNotifyDismiss else { return }
            // Off-screen pages may only signal paint; actions need a real presentation.
            guard !self.isPrewarming || type == "__msw_painted" else { return }
            switch type {
            case "__msw_painted":
                self.htmlLoaded = true
                self.trackShownIfReady()
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
        if let observer = foregroundObserver { NotificationCenter.default.removeObserver(observer) }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
    }
}
#endif

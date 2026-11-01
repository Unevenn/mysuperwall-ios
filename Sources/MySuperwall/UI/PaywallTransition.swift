#if canImport(UIKit)
import UIKit

final class PaywallTransition: NSObject, UIViewControllerAnimatedTransitioning {
    let config: PaywallPresentation
    let opening: Bool
    init(_ config: PaywallPresentation, opening: Bool) { self.config = config; self.opening = opening }
    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        config.style == "none" || UIAccessibility.isReduceMotionEnabled ? 0 : Double(config.durationMs)/1000
    }
    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewKey = opening ? .to : .from
        guard let view = context.view(forKey: key) else { context.completeTransition(false); return }
        if opening {
            guard let controller = context.viewController(forKey: .to) else { context.completeTransition(false); return }
            context.containerView.addSubview(view); view.frame = context.finalFrame(for: controller)
        }
        if transitionDuration(using: context) == 0 { view.transform = .identity; view.alpha = 1; context.completeTransition(true); return }
        let style = config.style
        let fade = ["fade","scale_up","scale_down","fade_slide_up"].contains(style)
        var transform = CGAffineTransform.identity
        switch style {
        case "slide_up": transform = CGAffineTransform(translationX: 0,y: context.containerView.bounds.height)
        case "slide_down": transform = CGAffineTransform(translationX: 0,y: -context.containerView.bounds.height * 0.12)
        case "slide_left": transform = CGAffineTransform(translationX: context.containerView.bounds.width * 0.12,y: 0)
        case "from_left": transform = CGAffineTransform(translationX: -context.containerView.bounds.width * 0.12,y: 0)
        case "fade_slide_up": transform = CGAffineTransform(translationX: 0,y: 24)
        case "scale_up": transform = CGAffineTransform(scaleX: 0.96,y: 0.96)
        case "scale_down": transform = CGAffineTransform(scaleX: 1.035,y: 1.035)
        default: break
        }
        if transitionDuration(using: context) == 0 { transform = .identity }
        view.transform = opening ? transform : .identity
        view.alpha = opening && fade ? 0 : 1
        let points: (CGPoint,CGPoint)
        switch config.curve {
        case "smooth": points = (CGPoint(x:0.22,y:1),CGPoint(x:0.36,y:1))
        case "easeInOutCubic": points = (CGPoint(x:0.65,y:0),CGPoint(x:0.35,y:1))
        case "linear": points = (CGPoint(x:0,y:0),CGPoint(x:1,y:1))
        case "easeInOut": points = (CGPoint(x:0.42,y:0),CGPoint(x:0.58,y:1))
        case "easeOutQuart": points = (CGPoint(x:0.25,y:1),CGPoint(x:0.5,y:1))
        case "easeOutBack": points = (CGPoint(x:0.175,y:0.885),CGPoint(x:0.32,y:1.275))
        case "easeOut": points = (CGPoint(x:0,y:0),CGPoint(x:0.58,y:1))
        default: points = (CGPoint(x:0.215,y:0.61),CGPoint(x:0.355,y:1))
        }
        let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context),timingParameters: UICubicTimingParameters(controlPoint1: points.0,controlPoint2: points.1))
        animator.addAnimations { view.transform = self.opening ? .identity : transform; view.alpha = !self.opening && fade ? 0 : 1 }
        animator.addCompletion { _ in
            let success = !context.transitionWasCancelled
            if !success { view.transform = .identity; view.alpha = 1 }
            context.completeTransition(success)
        }
        animator.startAnimation()
    }
}
extension PaywallWebViewController: UIViewControllerTransitioningDelegate {
    public func animationController(forPresented presented: UIViewController,presenting: UIViewController,source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard let config = paywall.presentation, config.style != "system" else { return nil }
        return PaywallTransition(config,opening: true)
    }
    public func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard let config = paywall.presentation, config.style != "system" else { return nil }
        return PaywallTransition(config,opening: false)
    }
}
#endif

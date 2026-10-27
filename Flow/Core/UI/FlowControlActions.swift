import UIKit

/// Closure-backed target/action for any `UIControl`, not just `UIButton`.
///
/// Several screens build their rows and chips programmatically and want to attach behaviour
/// without keeping a selector on the class. The closure is retained by the control through an
/// associated object, so it lives exactly as long as the control does.
final class FlowControlClosure {

    private let closure: () -> Void

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }

    @objc func run() {
        closure()
    }
}

extension UIControl {

    /// Adds a closure-backed action for `controlEvents`. The action is retained by the control.
    func addClosureAction(for controlEvents: UIControl.Event, _ closure: @escaping () -> Void) {
        let action = FlowControlClosure(closure)
        addTarget(action, action: #selector(FlowControlClosure.run), for: controlEvents)
        objc_setAssociatedObject(self, Unmanaged.passUnretained(action).toOpaque(), action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

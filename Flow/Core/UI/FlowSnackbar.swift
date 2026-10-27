import UIKit

/// A Material 3 snackbar: a short message on the inverse surface with one action, shown above the
/// mini player and dismissed on its own after a few seconds. Queued so two actions in a row do not
/// lose the first message.
final class FlowSnackbar {

    static let shared = FlowSnackbar()

    private var queue: [(message: String, actionTitle: String?, action: (() -> Void)?)] = []
    private var current: UIView?
    private var dismissWorkItem: DispatchWorkItem?
    private let lock = NSLock()

    private init() {}

    /// Shows `message`, optionally with an action. A second call while one is visible queues.
    static func show(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        shared.enqueue(message: message, actionTitle: actionTitle, action: action)
    }

    /// Shows a message for an action that failed, with no action button.
    static func showError(_ message: String) {
        shared.enqueue(message: message, actionTitle: nil, action: nil)
    }

    private func enqueue(message: String, actionTitle: String?, action: (() -> Void)?) {
        lock.lock()
        queue.append((message, actionTitle, action))
        let shouldPresent = current == nil
        lock.unlock()
        if shouldPresent {
            presentNext()
        }
    }

    private func presentNext() {
        lock.lock()
        guard current == nil, !queue.isEmpty else {
            lock.unlock()
            return
        }
        let item = queue.removeFirst()
        lock.unlock()

        guard let host = FlowSnackbar.topViewController() else {
            lock.lock()
            current = nil
            lock.unlock()
            return
        }

        let scheme = FlowTheme.shared.scheme
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = scheme.inverseSurface
        bar.layer.cornerRadius = FlowShapes.extraSmall
        bar.layer.masksToBounds = true
        bar.alpha = 0.0

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = item.message
        label.font = FlowTypography.bodyMedium
        label.textColor = scheme.inverseOnSurface
        label.numberOfLines = 3

        bar.addSubview(label)

        var trailingAnchorView: UIView = label
        var actionButton: UIButton?

        if let actionTitle = item.actionTitle, !actionTitle.isEmpty {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitle(actionTitle, for: .normal)
            button.setTitleColor(scheme.inversePrimary, for: .normal)
            button.titleLabel?.font = FlowTypography.labelLarge
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            bar.addSubview(button)
            actionButton = button
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -FlowSpacing.md),
                button.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
                button.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: FlowSpacing.md),
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 40.0),
            ])
            trailingAnchorView = button
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: FlowSpacing.xl),
            label.topAnchor.constraint(equalTo: bar.topAnchor, constant: FlowSpacing.lg),
            label.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -FlowSpacing.lg),
            label.trailingAnchor.constraint(equalTo: trailingAnchorView.leadingAnchor, constant: -FlowSpacing.md),
            bar.trailingAnchor.constraint(equalTo: trailingAnchorView.trailingAnchor, constant: FlowSpacing.md),
        ])

        host.view.addSubview(bar)
        let bottomInset: CGFloat = host.tabBarController != nil ? 8.0 : 16.0
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: FlowSpacing.screenMargin),
            bar.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -FlowSpacing.screenMargin),
            bar.bottomAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.bottomAnchor, constant: -bottomInset),
        ])

        if let button = actionButton {
            let action = item.action
            button.addClosureAction(for: .touchUpInside) { [weak self] in
                self?.dismissCurrent()
                action?()
            }
        }

        lock.lock()
        current = bar
        lock.unlock()

        FlowMotion.animateEmphasized({
            bar.alpha = 1.0
        }, completion: nil)

        let work = DispatchWorkItem { [weak self] in
            self?.dismissCurrent()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (actionButton == nil ? 3.0 : 5.0), execute: work)
    }

    /// Dismisses the visible snackbar and shows the next queued one.
    private func dismissCurrent() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        lock.lock()
        let bar = current
        current = nil
        lock.unlock()
        guard let visible = bar else {
            presentNext()
            return
        }
        FlowMotion.animate({
            visible.alpha = 0.0
        }, completion: { _ in
            visible.removeFromSuperview()
            self.presentNext()
        })
    }

    /// The controller a snackbar can be attached to.
    private static func topViewController() -> UIViewController? {
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else { return nil }
        var controller = delegate.window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        if let navigation = controller as? UINavigationController {
            controller = navigation.visibleViewController ?? navigation
        }
        return controller
    }
}

/// A `UIButton` target that runs a closure, so snackbar actions do not need a selector on an object
/// that must outlive the button.
final class ClosureAction: NSObject {
    private let closure: () -> Void

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
        super.init()
    }

    @objc func run() {
        closure()
    }
}


import UIKit

/// A Material 3 bottom sheet for iOS 12, where `UISheetPresentationController` does not exist.
///
/// The sheet is a child view controller with its own dimming view, a drag handle, a detent
/// (peek or full) and a grabber the user can drag. It is presented over the current context so it
/// works from any screen, including over a player.
final class FlowSheet: UIViewController, UIGestureRecognizerDelegate {

    /// How tall the sheet opens.
    enum Detent {
        /// Roughly half the screen, for a short menu.
        case medium
        /// The whole safe area, for a list.
        case large
        /// Exactly this fraction of the screen height, clamped to 0.2...1.0.
        case fraction(CGFloat)
    }

    /// The content the caller supplies. It is pinned inside the sheet's content area.
    private let contentView: UIView
    private let detent: Detent
    private let showsGrabber: Bool

    private let dimmingView = UIView()
    private let sheetView = UIView()
    private let grabber = UIView()
    private let scrollView = UIScrollView()
    private var sheetHeight: NSLayoutConstraint?
    private var sheetBottom: NSLayoutConstraint?
    private var panGesture: UIPanGestureRecognizer?
    private var dragStartConstant: CGFloat = 0.0

    /// Called after the sheet has dismissed itself.
    var onDismiss: (() -> Void)?

    /// The title shown above the content, when the caller wants one.
    private(set) var titleText: String?

    // MARK: - Construction

    /// Creates a sheet around `contentView`.
    init(content: UIView, title: String? = nil, detent: Detent = .medium, showsGrabber: Bool = true) {
        contentView = content
        self.detent = detent
        self.showsGrabber = showsGrabber
        titleText = title
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overCurrentContext
        modalTransitionStyle = .crossDissolve
        definesPresentationContext = false
    }

    required init?(coder: NSCoder) {
        contentView = UIView()
        detent = .medium
        showsGrabber = true
        super.init(coder: coder)
        modalPresentationStyle = .overCurrentContext
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        dimmingView.alpha = 0.0
        view.addSubview(dimmingView)
        NSLayoutConstraint.activate([
            dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleDimmingTap))
        dimmingView.addGestureRecognizer(tap)

        sheetView.translatesAutoresizingMaskIntoConstraints = false
        sheetView.layer.cornerRadius = FlowShapes.sheet
        sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheetView.layer.masksToBounds = true
        view.addSubview(sheetView)

        sheetBottom = sheetView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        sheetBottom?.isActive = true
        NSLayoutConstraint.activate([
            sheetView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheetView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        if showsGrabber {
            grabber.translatesAutoresizingMaskIntoConstraints = false
            grabber.layer.cornerRadius = 2.0
            grabber.layer.masksToBounds = true
            sheetView.addSubview(grabber)
            NSLayoutConstraint.activate([
                grabber.centerXAnchor.constraint(equalTo: sheetView.centerXAnchor),
                grabber.topAnchor.constraint(equalTo: sheetView.topAnchor, constant: FlowSpacing.md),
                grabber.widthAnchor.constraint(equalToConstant: 32.0),
                grabber.heightAnchor.constraint(equalToConstant: 4.0),
            ])
        }

        var topAnchorForContent = sheetView.topAnchor
        var topInset: CGFloat = showsGrabber ? FlowSpacing.xxl : FlowSpacing.lg

        if let title = titleText, !title.isEmpty {
            let titleLabel = UILabel()
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.text = title
            titleLabel.font = FlowTypography.titleLarge
            titleLabel.numberOfLines = 2
            sheetView.addSubview(titleLabel)
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: FlowSpacing.xl),
                titleLabel.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -FlowSpacing.xl),
                titleLabel.topAnchor.constraint(equalTo: sheetView.topAnchor, constant: topInset),
            ])
            topAnchorForContent = titleLabel.bottomAnchor
            topInset = FlowSpacing.md
        }

        sheetView.addSubviewForAutoLayout(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchorForContent, constant: topInset),
            contentView.bottomAnchor.constraint(equalTo: sheetView.safeAreaLayoutGuide.bottomAnchor),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        sheetView.addGestureRecognizer(pan)
        panGesture = pan

        applyTheme()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard sheetHeight == nil else { return }
        let available = view.bounds.height - view.safeAreaInsets.top
        let height: CGFloat
        switch detent {
        case .medium:
            height = min(available, view.bounds.height * 0.55)
        case .large:
            height = available
        case .fraction(let fraction):
            height = min(available, view.bounds.height * min(max(fraction, 0.2), 1.0))
        }
        let constraint = sheetView.heightAnchor.constraint(equalToConstant: height)
        constraint.priority = .defaultHigh
        constraint.isActive = true
        sheetHeight = constraint
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.layoutIfNeeded()
        sheetBottom?.constant = sheetView.bounds.height + 40.0
        view.layoutIfNeeded()
        sheetBottom?.constant = 0.0
        FlowMotion.animateEmphasized({
            self.dimmingView.alpha = 1.0
            self.view.layoutIfNeeded()
        }, completion: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: sheetView)
    }

    // MARK: - Presentation

    /// Presents the sheet from `presenter` (or the top-most controller when nil).
    func present(from presenter: UIViewController? = nil, animated: Bool = true) {
        let host = presenter ?? FlowSheet.topViewController()
        host?.present(self, animated: animated, completion: nil)
    }

    /// Dismisses the sheet, running `onDismiss` afterwards.
    func dismissSheet(animated: Bool = true) {
        guard presentingViewController != nil else {
            onDismiss?()
            return
        }
        if !animated {
            dismiss(animated: false) { [weak self] in
                self?.onDismiss?()
            }
            return
        }
        sheetBottom?.constant = sheetView.bounds.height + 40.0
        FlowMotion.animateEmphasized({
            self.dimmingView.alpha = 0.0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.dismiss(animated: false) { [weak self] in
                self?.onDismiss?()
            }
        })
    }

    /// Repaints the sheet in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        sheetView.backgroundColor = scheme.surfaceContainerLow
        grabber.backgroundColor = scheme.outlineVariant
        for subview in sheetView.subviews {
            if let label = subview as? UILabel, subview !== grabber {
                label.textColor = scheme.onSurface
            }
        }
    }

    // MARK: - Gestures

    @objc private func handleDimmingTap() {
        dismissSheet()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view).y
        switch recognizer.state {
        case .began:
            dragStartConstant = sheetBottom?.constant ?? 0.0
        case .changed:
            let proposed = dragStartConstant + translation
            sheetBottom?.constant = max(0.0, proposed)
            let progress = min(max(proposed / max(sheetView.bounds.height, 1.0), 0.0), 1.0)
            dimmingView.alpha = 1.0 - progress * 0.8
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: view).y
            let current = sheetBottom?.constant ?? 0.0
            let shouldDismiss = velocity > 900.0 || current > sheetView.bounds.height * 0.3
            if shouldDismiss {
                dismissSheet()
            } else {
                sheetBottom?.constant = 0.0
                FlowMotion.animateEmphasized({
                    self.dimmingView.alpha = 1.0
                    self.view.layoutIfNeeded()
                }, completion: nil)
            }
        default:
            break
        }
    }

    /// Lets the sheet's drag coexist with a scroll view that is already at the top.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGesture else { return true }
        let location = gestureRecognizer.location(in: sheetView)
        let scroll = scrollViewAt(point: location, in: sheetView)
        if let found = scroll, found.contentOffset.y > 0 {
            return false
        }
        return true
    }

    private func scrollViewAt(point: CGPoint, in root: UIView) -> UIScrollView? {
        for subview in root.subviews {
            if let scroll = subview as? UIScrollView {
                let converted = scroll.convert(point, from: root)
                if scroll.bounds.contains(converted) { return scroll }
            }
            if let nested = scrollViewAt(point: point, in: subview) {
                return nested
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// The top-most controller to present from.
    static func topViewController() -> UIViewController? {
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else { return nil }
        var controller = delegate.window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        if let navigation = controller as? UINavigationController {
            return navigation.visibleViewController ?? navigation
        }
        return controller
    }
}

/// A ready-made sheet content view: a vertical list of labelled actions, each with an optional icon
/// and an optional destructive tint. This is the "more" menu used across the app.
final class FlowActionSheetContent: UIView {

    /// One row of the menu.
    struct Action {
        let title: String
        let icon: FlowIcon?
        let isDestructive: Bool
        let handler: () -> Void

        init(title: String, icon: FlowIcon? = nil, isDestructive: Bool = false, handler: @escaping () -> Void) {
            self.title = title
            self.icon = icon
            self.isDestructive = isDestructive
            self.handler = handler
        }
    }

    private let stack = UIStackView()
    private let scrollView = UIScrollView()
    private var rows: [UIControl] = []

    /// Called after an action runs, so the sheet can close itself.
    var onActionSelected: (() -> Void)?

    init(actions: [Action]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = 0.0
        scrollView.addSubviewForAutoLayout(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
        for action in actions {
            let row = makeRow(action)
            rows.append(row)
            stack.addArrangedSubview(row)
        }
        applyTheme()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeRow(_ action: Action) -> UIControl {
        let row = UIControl()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52.0).isActive = true

        let iconView = FlowIconView()
        iconView.iconSize = 22.0
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 22.0).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 22.0).isActive = true
        if let glyph = action.icon {
            iconView.icon = glyph
            row.addSubview(iconView)
        } else {
            iconView.isHidden = true
        }

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = action.title
        label.font = FlowTypography.bodyLarge
        label.numberOfLines = 2
        row.addSubview(label)

        if action.icon != nil {
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: FlowSpacing.xl),
                iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: FlowSpacing.lg),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: FlowSpacing.xl),
            ])
        }
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -FlowSpacing.xl),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: FlowSpacing.lg),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -FlowSpacing.lg),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52.0),
        ])

        row.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            action.handler()
            self?.onActionSelected?()
        }
        row.accessibilityTraits = .button
        row.accessibilityLabel = action.title
        row.isAccessibilityElement = true

        let scheme = FlowTheme.shared.scheme
        label.textColor = action.isDestructive ? scheme.error : scheme.onSurface
        iconView.iconColor = action.isDestructive ? scheme.error : scheme.onSurfaceVariant
        return row
    }

    /// Repaints the rows in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        for row in rows {
            for subview in row.subviews {
                if let label = subview as? UILabel {
                    let isDestructive = row.accessibilityLabel.map { FlowActionSheetContent.destructiveTitles.contains($0) } ?? false
                    label.textColor = isDestructive ? scheme.error : scheme.onSurface
                }
                if let icon = subview as? FlowIconView {
                    icon.iconColor = scheme.onSurfaceVariant
                }
            }
        }
    }

    /// Titles that should read as destructive. Kept so `applyTheme` can restore the tint.
    private static var destructiveTitles: Set<String> = [
        "Delete", "Remove", "Remove from playlist", "Remove download", "Clear history",
        "Delete playlist", "Unsubscribe", "Block channel", "Clear cache", "Reset",
    ]
}

/// A `UIControl` target that runs a closure, for rows built in code.
final class ControlClosure: NSObject {
    private let closure: () -> Void

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
        super.init()
    }

    @objc func run() {
        closure()
    }
}

extension UIControl {
    /// Adds a closure-backed action, retained by the control for its lifetime.
    func addClosureActionForControl(for controlEvents: UIControl.Event, _ closure: @escaping () -> Void) {
        let action = ControlClosure(closure)
        addTarget(action, action: #selector(ControlClosure.run), for: controlEvents)
        objc_setAssociatedObject(self, Unmanaged.passUnretained(action).toOpaque(), action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

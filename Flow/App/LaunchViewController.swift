import UIKit

/// The splash: the Flow mark drawn with bezier paths, the wordmark under it, and a shimmer that
/// runs while the shell finishes coming up.
///
/// There is no launch storyboard — `Info.plist` deliberately omits `UILaunchStoryboardName` — so
/// this is the first thing the app draws. It holds for a short minimum so the mark is not a flash,
/// then fades into the tab bar once `FlowApp` reports it is ready. A deep link that arrives during
/// the hold is queued and opened after the hand-off, so it is not pushed underneath the splash.
final class LaunchViewController: UIViewController {

    /// Called once the splash has dismissed itself.
    var onFinished: (() -> Void)?

    /// How long the mark stays up at minimum. Long enough to read, short enough not to annoy.
    private static let minimumDisplay: TimeInterval = 0.9

    private let markView = FlowMarkView()
    private let wordmark = UILabel()
    private let tagline = UILabel()
    private let shimmer = FlowShimmerView.make(height: 3.0, radius: 1.5)

    /// The palette observer. Held so the splash repaints if the theme is restored while it is up.
    private var themeToken: ObservationToken?

    private var shownAt = Date()
    private var hasDismissed = false
    private var pendingRoute: Route?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildSubviews()
        applyTheme()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
    }

    deinit {
        themeToken?.cancelObservation()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        shownAt = Date()
        shimmer.startAnimating()
        markView.startPulse()
        scheduleHandOff()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Construction

    private func buildSubviews() {
        markView.translatesAutoresizingMaskIntoConstraints = false
        markView.isAccessibilityElement = true
        markView.accessibilityLabel = "Flow"
        view.addSubview(markView)

        wordmark.translatesAutoresizingMaskIntoConstraints = false
        wordmark.text = "Flow"
        wordmark.font = FlowTypography.displaySmall
        wordmark.textAlignment = .center
        wordmark.isAccessibilityElement = false
        view.addSubview(wordmark)

        tagline.translatesAutoresizingMaskIntoConstraints = false
        tagline.text = "Private by design"
        tagline.font = FlowTypography.bodyMedium
        tagline.textAlignment = .center
        tagline.numberOfLines = 2
        tagline.isAccessibilityElement = false
        view.addSubview(tagline)

        view.addSubview(shimmer)

        NSLayoutConstraint.activate([
            markView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            markView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -48.0),
            markView.widthAnchor.constraint(equalToConstant: 96.0),
            markView.heightAnchor.constraint(equalToConstant: 96.0),

            wordmark.topAnchor.constraint(equalTo: markView.bottomAnchor, constant: FlowSpacing.xl),
            wordmark.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.xxl),
            wordmark.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.xxl),

            tagline.topAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: FlowSpacing.sm),
            tagline.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.xxl),
            tagline.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.xxl),

            shimmer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shimmer.topAnchor.constraint(equalTo: tagline.bottomAnchor, constant: FlowSpacing.xxl),
            shimmer.widthAnchor.constraint(equalToConstant: 96.0),
        ])
    }

    /// Repaints the splash in the current palette. The mark keeps the palette's primary, so the
    /// splash already looks like the theme the viewer chose.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        markView.markColor = scheme.primary
        wordmark.textColor = scheme.onBackground
        tagline.textColor = scheme.onSurfaceVariant
        shimmer.applyTheme()
    }

    // MARK: - Hand-off

    /// Queues a route that arrived while the splash was up.
    func enqueue(_ route: Route) {
        pendingRoute = route
    }

    /// Waits out the minimum display time, then dismisses if the container is ready. The container
    /// is bootstrapped synchronously by the delegate, so in practice this is a pure delay; the
    /// readiness check keeps the hand-off correct if that ever changes.
    private func scheduleHandOff() {
        let elapsed = Date().timeIntervalSince(shownAt)
        let remaining = max(LaunchViewController.minimumDisplay - elapsed, 0.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            self?.finishIfReady()
        }
    }

    private func finishIfReady() {
        guard !hasDismissed else { return }
        guard FlowApp.shared.isBootstrapped else {
            // Not ready yet: check again shortly rather than handing over to a half-built shell.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.finishIfReady()
            }
            return
        }
        hasDismissed = true
        shimmer.stopAnimating()
        markView.stopPulse()

        let route = pendingRoute
        pendingRoute = nil

        // The route opens after the splash has gone, so it lands on the shell's stack rather than
        // being pushed underneath a modal that is about to dismiss.
        onFinished?()
        if let route = route {
            DispatchQueue.main.async {
                Router.shared.open(route)
            }
        }
    }
}

/// The Flow mark: a rounded play triangle inside a ring, drawn with `UIBezierPath` so it needs no
/// asset and scales to any size.
final class FlowMarkView: UIView {

    /// The colour of the ring and the triangle.
    var markColor: UIColor = FlowTheme.shared.primary {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let origin = CGPoint(x: bounds.midX - side / 2.0, y: bounds.midY - side / 2.0)

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)

        // Everything is authored in a 96-point box and scaled to the view's size.
        let scale = side / 96.0
        context.scaleBy(x: scale, y: scale)

        markColor.setStroke()
        markColor.setFill()

        // The ring: an open arc with a gap at the lower right, the app's "flow" gesture.
        let ring = UIBezierPath()
        ring.addArc(
            withCenter: CGPoint(x: 48.0, y: 48.0),
            radius: 40.0,
            startAngle: CGFloat(-0.35 * Double.pi),
            endAngle: CGFloat(1.62 * Double.pi),
            clockwise: true
        )
        ring.lineWidth = 7.0
        ring.lineCapStyle = .round
        ring.stroke()

        // The play triangle, rounded at the corners so it matches the app's shape scale.
        let triangle = UIBezierPath()
        triangle.move(to: CGPoint(x: 39.0, y: 32.0))
        triangle.addLine(to: CGPoint(x: 66.0, y: 48.0))
        triangle.addLine(to: CGPoint(x: 39.0, y: 64.0))
        triangle.close()
        triangle.lineWidth = 6.0
        triangle.lineJoinStyle = .round
        triangle.lineCapStyle = .round
        triangle.fill()
        triangle.stroke()

        context.restoreGState()
    }

    /// A slow breath while the shell loads. Held still when Reduce Motion is on.
    func startPulse() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.55
        animation.duration = 1.1
        animation.autoreverses = true
        animation.repeatCount = .greatestFiniteMagnitude
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "flowMarkPulse")
    }

    /// Stops the breath and restores full opacity.
    func stopPulse() {
        layer.removeAnimation(forKey: "flowMarkPulse")
        alpha = 1.0
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopPulse()
        }
    }
}

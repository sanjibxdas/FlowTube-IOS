import UIKit

/// A skeleton block that sweeps a highlight across itself while content loads. Replaces the
/// Android app's shimmer placeholders without a gradient layer — a moving band of the container
/// colour, which keeps the anti-slop rule ("no gradients") intact while still reading as loading.
final class FlowShimmerView: UIView {

    private let band = UIView()
    private var bandLeading: NSLayoutConstraint?
    private var isAnimating = false

    /// The corner radius of the placeholder shape.
    var shapeRadius: CGFloat = FlowShapes.extraSmall {
        didSet { layer.cornerRadius = shapeRadius }
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
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        layer.cornerRadius = shapeRadius
        band.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        addSubviewForAutoLayout(band)
        bandLeading = band.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -80.0)
        bandLeading?.isActive = true
        NSLayoutConstraint.activate([
            band.widthAnchor.constraint(equalToConstant: 80.0),
            band.topAnchor.constraint(equalTo: topAnchor),
            band.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme()
    }

    /// Creates a shimmer block of a given size.
    static func make(width: CGFloat? = nil, height: CGFloat, radius: CGFloat = FlowShapes.extraSmall) -> FlowShimmerView {
        let view = FlowShimmerView()
        view.shapeRadius = radius
        view.layer.cornerRadius = radius
        if let width = width {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    /// Repaints the block in the current palette.
    func applyTheme() {
        backgroundColor = FlowTheme.shared.scheme.surfaceContainerHigh
        band.backgroundColor = FlowTheme.shared.scheme.surfaceContainerHighest.withAlphaComponent(0.7)
    }

    /// Starts the sweep. Honours Reduce Motion by holding a static block instead.
    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        bandLeading?.constant = -80.0
        layoutIfNeeded()
        loop()
    }

    private func loop() {
        guard isAnimating else { return }
        bandLeading?.constant = bounds.width + 80.0
        UIView.animate(withDuration: 1.1, delay: 0.0, options: [.curveLinear], animations: {
            self.layoutIfNeeded()
        }, completion: { [weak self] finished in
            guard let self = self, finished, self.isAnimating else { return }
            self.bandLeading?.constant = -80.0
            self.layoutIfNeeded()
            self.loop()
        })
    }

    /// Stops the sweep.
    func stopAnimating() {
        isAnimating = false
        band.layer.removeAllAnimations()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopAnimating()
        } else if isAnimating {
            loop()
        }
    }
}

/// A row of skeleton placeholders shaped like a video card, shown while a list loads.
final class FlowShimmerCard: UIView {

    private let thumbnail = FlowShimmerView.make(height: 135.0, radius: FlowShapes.thumbnail)
    private let titleLine = FlowShimmerView.make(height: 14.0, radius: 4.0)
    private let subtitleLine = FlowShimmerView.make(height: 12.0, radius: 4.0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        addSubviewForAutoLayout(thumbnail)
        addSubviewForAutoLayout(titleLine)
        addSubviewForAutoLayout(subtitleLine)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnail.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbnail.topAnchor.constraint(equalTo: topAnchor),
            thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor, multiplier: 9.0 / 16.0),

            titleLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLine.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.85),
            titleLine.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: FlowSpacing.md),

            subtitleLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            subtitleLine.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.55),
            subtitleLine.topAnchor.constraint(equalTo: titleLine.bottomAnchor, constant: FlowSpacing.sm),
            subtitleLine.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Starts every placeholder's sweep.
    func startAnimating() {
        thumbnail.startAnimating()
        titleLine.startAnimating()
        subtitleLine.startAnimating()
    }

    /// Stops every placeholder's sweep.
    func stopAnimating() {
        thumbnail.stopAnimating()
        titleLine.stopAnimating()
        subtitleLine.stopAnimating()
    }

    /// Repaints the placeholders in the current palette.
    func applyTheme() {
        thumbnail.applyTheme()
        titleLine.applyTheme()
        subtitleLine.applyTheme()
    }
}

/// A full-screen loading state: a grid of skeleton cards, used before the first page arrives.
final class FlowShimmerGrid: UIView {

    private let stack = UIStackView()
    private var cards: [FlowShimmerCard] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = FlowSpacing.xl
        addSubviewForAutoLayout(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.screenMargin),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.xl),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        isUserInteractionEnabled = false
        setRowCount(3)
    }

    /// Replaces the skeleton with `count` rows.
    func setRowCount(_ count: Int) {
        for card in cards {
            stack.removeArrangedSubview(card)
            card.removeFromSuperview()
        }
        cards = []
        for _ in 0..<max(0, count) {
            let card = FlowShimmerCard()
            cards.append(card)
            stack.addArrangedSubview(card)
        }
    }

    /// Starts every card's sweep.
    func startAnimating() {
        for card in cards {
            card.startAnimating()
        }
    }

    /// Stops every card's sweep.
    func stopAnimating() {
        for card in cards {
            card.stopAnimating()
        }
    }

    /// Repaints every card.
    func applyTheme() {
        for card in cards {
            card.applyTheme()
        }
    }
}

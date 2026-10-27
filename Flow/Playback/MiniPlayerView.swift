import UIKit

/// The mini player that sits above the tab bar on every screen.
///
/// It is a single instance owned by the root tab bar controller, so playback survives moving between
/// tabs without the player being rebuilt. The layout mirrors the Android mini player: a circular
/// artwork ring with a progress arc, the title and artist, and a transport button, all inside a
/// surface-coloured bar with a hairline top edge.
///
/// Dragging down dismisses it (and stops playback), tapping expands to the full player, and swiping
/// left or right skips through the queue.
final class MiniPlayerView: UIView {

    /// Called when the bar is tapped.
    var onExpand: (() -> Void)?
    /// Called when the viewer drags the bar away.
    var onDismiss: (() -> Void)?
    /// Called when the play/pause button is tapped.
    var onPlayPause: (() -> Void)?
    /// Called when the viewer swipes to the next or previous track.
    var onSkip: ((Bool) -> Void)?

    // MARK: - Views

    private let artworkRing = MiniArtworkRing()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let playButton = FlowIconButton()
    private let progressLine = UIView()
    private let progressFill = UIView()
    private var progressWidth: NSLayoutConstraint?
    private let hairline = UIView.hairline()

    // MARK: - State

    private var bag = ObservationBag()
    private var service: PlaybackService?
    private var currentItem: PlaybackQueueItem?
    private var panStartCenter: CGPoint = .zero
    private var marqueeOffset: CGFloat = 0.0
    private var marqueeTimer: Timer?
    private var titleWidth: CGFloat = 0.0
    private var titleContainerWidth: CGFloat = 0.0

    /// The height the bar occupies in a tab bar layout.
    static let barHeight: CGFloat = FlowSpacing.miniPlayerHeight
    /// The diameter of the artwork ring.
    static let ringDiameter: CGFloat = 52.0
    /// The diameter of the artwork inside the ring.
    static let artworkDiameter: CGFloat = 43.0
    /// The width of the progress ring.
    static let ringWidth: CGFloat = 2.5

    // MARK: - Init

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
        layer.masksToBounds = false
        applyTheme()

        artworkRing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(artworkRing)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmallEmphasized
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byClipping
        titleLabel.clipsToBounds = true

        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        artistLabel.font = FlowTypography.bodySmall
        artistLabel.numberOfLines = 1
        artistLabel.lineBreakMode = .byTruncatingTail

        let textStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 0.0
        textStack.alignment = .leading
        addSubview(textStack)

        playButton.configure(icon: .play, color: FlowTheme.shared.onSurface, size: 26.0)
        playButton.accessibilityLabel = "Play"
        playButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onPlayPause?()
        }
        addSubviewForAutoLayout(playButton)

        progressLine.translatesAutoresizingMaskIntoConstraints = false
        progressLine.backgroundColor = FlowTheme.shared.outlineVariant
        addSubview(progressLine)

        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressFill.backgroundColor = FlowTheme.shared.primary
        progressLine.addSubview(progressFill)

        addSubview(hairline)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: MiniPlayerView.barHeight),

            artworkRing.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.sm),
            artworkRing.centerYAnchor.constraint(equalTo: centerYAnchor),
            artworkRing.widthAnchor.constraint(equalToConstant: MiniPlayerView.ringDiameter),
            artworkRing.heightAnchor.constraint(equalToConstant: MiniPlayerView.ringDiameter),

            textStack.leadingAnchor.constraint(equalTo: artworkRing.trailingAnchor, constant: FlowSpacing.lg),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -FlowSpacing.md),

            playButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.sm),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 44.0),
            playButton.heightAnchor.constraint(equalToConstant: 44.0),

            progressLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressLine.heightAnchor.constraint(equalToConstant: 2.0),

            progressFill.leadingAnchor.constraint(equalTo: progressLine.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressLine.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressLine.bottomAnchor),

            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor),
        ])
        progressWidth = progressFill.widthAnchor.constraint(equalToConstant: 0.0)
        progressWidth?.isActive = true
    }

    // MARK: - Binding

    /// Binds the bar to the playback service.
    func bind(to service: PlaybackService) {
        self.service = service
        bag.cancelAll()
        bag = ObservationBag()
        bag.add(service.state.observe { [weak self] snapshot in
            self?.render(snapshot)
        })
        bag.add(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
    }

    private func render(_ snapshot: PlaybackSnapshot) {
        guard let item = snapshot.item else {
            isHidden = true
            stopMarquee()
            return
        }
        isHidden = false
        playButton.setIcon(snapshot.isPlaying ? .pause : .play)
        playButton.accessibilityLabel = snapshot.isPlaying ? "Pause" : "Play"

        if currentItem?.videoId != item.videoId {
            currentItem = item
            setTitle(item.title)
            artistLabel.text = item.channelName
            artworkRing.setImageURL(item.thumbnailUrl)
            startMarqueeIfNeeded()
        }

        let fraction = CGFloat(snapshot.progress)
        progressWidth?.constant = max(bounds.width * fraction, 0.0)
        artworkRing.setProgress(fraction)
        layoutIfNeeded()
    }

    private func setTitle(_ title: String) {
        titleLabel.text = title
        titleLabel.sizeToFit()
        titleWidth = titleLabel.intrinsicContentSize.width
        titleContainerWidth = max(bounds.width - MiniPlayerView.ringDiameter - 44.0 - FlowSpacing.sm * 2 - FlowSpacing.lg - FlowSpacing.md, 120.0)
        marqueeOffset = 0.0
        titleLabel.transform = .identity
    }

    // MARK: - Marquee

    /// Scrolls a title that is too long for the bar, the way the Android mini player does. The
    /// animation is a slow leftward drift with a pause at each end, not a continuous bounce.
    private func startMarqueeIfNeeded() {
        stopMarquee()
        guard titleWidth > titleContainerWidth + 8.0 else { return }
        let overflow = titleWidth - titleContainerWidth + 16.0
        marqueeTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let target = self.marqueeOffset == 0 ? -overflow : 0
            self.marqueeOffset = target
            UIView.animate(
                withDuration: 3.0,
                delay: 0.0,
                options: [.curveEaseInOut, .beginFromCurrentState],
                animations: {
                    self.titleLabel.transform = CGAffineTransform(translationX: target, y: 0)
                },
                completion: nil
            )
        }
    }

    private func stopMarquee() {
        marqueeTimer?.invalidate()
        marqueeTimer = nil
        titleLabel.transform = .identity
        marqueeOffset = 0.0
    }

    // MARK: - Gestures

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)
        if playButton.frame.contains(location) { return }
        onExpand?()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: superview)
        switch recognizer.state {
        case .changed:
            if abs(translation.x) > abs(translation.y) {
                // A horizontal swipe previews the skip by sliding the bar slightly.
                transform = CGAffineTransform(translationX: translation.x * 0.25, y: 0)
                alpha = max(1.0 - abs(translation.x) / 400.0, 0.4)
            } else if translation.y > 0 {
                transform = CGAffineTransform(translationX: 0, y: translation.y)
                alpha = max(1.0 - translation.y / 120.0, 0.2)
            }
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: superview)
            if abs(translation.x) > 80.0 && abs(translation.x) > abs(translation.y) {
                onSkip?(translation.x < 0)
                resetPosition()
            } else if translation.y > 80.0 || velocity.y > 900.0 {
                dismiss()
            } else {
                resetPosition()
            }
        default:
            break
        }
    }

    private func resetPosition() {
        FlowMotion.animate {
            self.transform = .identity
            self.alpha = 1.0
        }
    }

    /// Slides the bar away and reports the dismissal.
    private func dismiss() {
        FlowMotion.animate({
            self.transform = CGAffineTransform(translationX: 0, y: MiniPlayerView.barHeight)
            self.alpha = 0.0
        }, completion: { _ in
            self.transform = .identity
            self.alpha = 1.0
            self.isHidden = true
            self.onDismiss?()
        })
    }

    // MARK: - Theme

    /// Repaints the bar in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = scheme.surfaceContainer
        titleLabel.textColor = scheme.onSurface
        artistLabel.textColor = scheme.onSurfaceVariant
        playButton.setIconColor(scheme.onSurface)
        progressLine.backgroundColor = scheme.outlineVariant
        progressFill.backgroundColor = scheme.primary
        artworkRing.applyTheme()
        layer.cornerRadius = 0.0
    }
}

/// The circular artwork with a progress arc around it.
final class MiniArtworkRing: UIView {

    private let imageView = AsyncImageView()
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private var progress: CGFloat = 0.0

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
        backgroundColor = .clear

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.applyCornerRadius(MiniPlayerView.artworkDiameter / 2.0)
        addSubview(imageView)

        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.lineWidth = MiniPlayerView.ringWidth
        layer.addSublayer(trackLayer)

        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.lineWidth = MiniPlayerView.ringWidth
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0.0
        layer.addSublayer(progressLayer)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: MiniPlayerView.artworkDiameter),
            imageView.heightAnchor.constraint(equalToConstant: MiniPlayerView.artworkDiameter),
        ])
        applyTheme()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = MiniPlayerView.ringWidth / 2.0
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = UIBezierPath(ovalIn: rect)
        trackLayer.frame = bounds
        trackLayer.path = path.cgPath
        progressLayer.frame = bounds
        progressLayer.path = path.cgPath
        // Start the arc at twelve o'clock rather than three.
        progressLayer.transform = CATransform3DMakeRotation(-CGFloat.pi / 2.0, 0, 0, 1)
    }

    /// Sets the artwork.
    func setImageURL(_ urlString: String) {
        imageView.setImage(url: urlString, placeholder: FlowTheme.shared.scheme.surfaceContainerHighest)
    }

    /// Sets the arc's progress, 0...1.
    func setProgress(_ value: CGFloat) {
        progress = min(max(value, 0.0), 1.0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        progressLayer.strokeEnd = progress
        CATransaction.commit()
    }

    /// Repaints the ring in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        trackLayer.strokeColor = scheme.outlineVariant.cgColor
        progressLayer.strokeColor = scheme.primary.cgColor
        imageView.placeholderColor = scheme.surfaceContainerHighest
    }
}

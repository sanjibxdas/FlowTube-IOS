import UIKit

/// The video player's controls.
///
/// The view draws the whole chrome — top bar, centre transport, scrubber, chapter bar and the
/// bottom action row — and reports what the viewer did through closures. It owns no playback state:
/// `VideoPlayerViewController` feeds it a snapshot and it renders that, which keeps the auto-hide
/// timer and the gesture layer from fighting over who is in charge.
///
/// Everything is laid out in code with Auto Layout, and the controls scale down in a compact
/// (landscape, short) layout by hiding the labels and shrinking the paddings.
final class PlayerControlsView: UIView {

    /// The actions the controls can report.
    enum Action {
        case back
        case playPause
        case previous
        case next
        case seekBegan
        case seek(to: TimeInterval)
        case settings
        case quality
        case speed
        case subtitles
        case chapters
        case queue
        case fullscreen
        case pictureInPicture
        case sleepTimer
        case sponsorBlock
    }

    // MARK: - Subviews

    private let topBar = UIView()
    private let backButton = FlowIconButton()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let pipButton = FlowIconButton()
    private let settingsButton = FlowIconButton()

    private let centreRow = UIStackView()
    private let previousButton = FlowIconButton()
    private let playButton = FlowIconButton()
    private let nextButton = FlowIconButton()

    private let bottomBar = UIView()
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let scrubber = UISlider()
    private let chapterBar = ChapterBarView()
    private let actionRow = UIStackView()
    private let qualityButton = UIButton(type: .custom)
    private let speedButton = UIButton(type: .custom)
    private let subtitlesButton = FlowIconButton()
    private let chaptersButton = FlowIconButton()
    private let queueButton = FlowIconButton()
    private let fullscreenButton = FlowIconButton()
    private let sleepButton = FlowIconButton()
    private let sponsorButton = FlowIconButton()

    private let bufferingIndicator = UIActivityIndicatorView(style: .whiteLarge)
    private let errorLabel = UILabel()
    private let errorRetryButton = FlowButton.make("Retry", style: .tonal)

    private let scrimTop = GradientScrim(direction: .top)
    private let scrimBottom = GradientScrim(direction: .bottom)

    // MARK: - State

    /// Called for every control action.
    var onAction: ((Action) -> Void)?

    /// Whether the controls are currently visible.
    private(set) var isVisible = true

    /// Whether the viewer is dragging the scrubber. While true, position updates are ignored so the
    /// thumb does not jump back under the finger.
    private var isScrubbing = false

    /// The duration the scrubber maps to.
    private var duration: TimeInterval = 0

    /// Whether the layout is the compact one (landscape on a phone).
    private var isCompact = false

    /// The retry action shown with an error.
    var onRetry: (() -> Void)?

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
        backgroundColor = .clear
        buildTopBar()
        buildCentreRow()
        buildBottomBar()
        buildOverlays()
        applyTheme()
        setVisible(true, animated: false)
    }

    // MARK: - Construction

    private func buildTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBar)

        backButton.configure(icon: .back, color: .white, size: 22.0)
        backButton.accessibilityLabel = "Back"
        backButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onAction?(.back)
        }
        topBar.addSubviewForAutoLayout(backButton)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleMedium
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        topBar.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = FlowTypography.bodySmall
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        subtitleLabel.numberOfLines = 1
        topBar.addSubview(subtitleLabel)

        pipButton.configure(icon: .pip, color: .white, size: 22.0)
        pipButton.accessibilityLabel = "Picture in picture"
        pipButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onAction?(.pictureInPicture)
        }
        topBar.addSubviewForAutoLayout(pipButton)

        settingsButton.configure(icon: .settings, color: .white, size: 22.0)
        settingsButton.accessibilityLabel = "Player settings"
        settingsButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onAction?(.settings)
        }
        topBar.addSubviewForAutoLayout(settingsButton)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.topAnchor.constraint(equalTo: topAnchor),

            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: FlowSpacing.md),
            backButton.topAnchor.constraint(equalTo: topBar.safeAreaLayoutGuide.topAnchor, constant: FlowSpacing.sm),
            backButton.widthAnchor.constraint(equalToConstant: 44.0),
            backButton.heightAnchor.constraint(equalToConstant: 44.0),

            settingsButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -FlowSpacing.md),
            settingsButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 44.0),
            settingsButton.heightAnchor.constraint(equalToConstant: 44.0),

            pipButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -FlowSpacing.xs),
            pipButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            pipButton.widthAnchor.constraint(equalToConstant: 44.0),
            pipButton.heightAnchor.constraint(equalToConstant: 44.0),

            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: FlowSpacing.md),
            titleLabel.trailingAnchor.constraint(equalTo: pipButton.leadingAnchor, constant: -FlowSpacing.md),
            titleLabel.topAnchor.constraint(equalTo: backButton.topAnchor, constant: 5.0),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1.0),
            subtitleLabel.bottomAnchor.constraint(equalTo: backButton.bottomAnchor, constant: -5.0),
        ])
    }

    private func buildCentreRow() {
        centreRow.translatesAutoresizingMaskIntoConstraints = false
        centreRow.axis = .horizontal
        centreRow.alignment = .center
        centreRow.spacing = FlowSpacing.xxl
        addSubview(centreRow)

        previousButton.configure(icon: .previous, color: .white, size: 32.0)
        previousButton.accessibilityLabel = "Previous"
        previousButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onAction?(.previous)
        }

        playButton.configure(icon: .play, color: .white, size: 44.0)
        playButton.accessibilityLabel = "Play"
        playButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onAction?(.playPause)
        }

        nextButton.configure(icon: .next, color: .white, size: 32.0)
        nextButton.accessibilityLabel = "Next"
        nextButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onAction?(.next)
        }

        centreRow.addArrangedSubview(previousButton)
        centreRow.addArrangedSubview(playButton)
        centreRow.addArrangedSubview(nextButton)

        NSLayoutConstraint.activate([
            centreRow.centerXAnchor.constraint(equalTo: centerXAnchor),
            centreRow.centerYAnchor.constraint(equalTo: centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 56.0),
            previousButton.heightAnchor.constraint(equalToConstant: 56.0),
            playButton.widthAnchor.constraint(equalToConstant: 72.0),
            playButton.heightAnchor.constraint(equalToConstant: 72.0),
            nextButton.widthAnchor.constraint(equalToConstant: 56.0),
            nextButton.heightAnchor.constraint(equalToConstant: 56.0),
        ])
    }

    private func buildBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBar)

        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        currentTimeLabel.font = FlowTypography.labelMedium
        currentTimeLabel.textColor = .white
        currentTimeLabel.text = "0:00"
        currentTimeLabel.setContentHuggingPriority(.required, for: .horizontal)
        currentTimeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = FlowTypography.labelMedium
        durationLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        durationLabel.text = "0:00"
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)
        durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.minimumTrackTintColor = FlowTheme.shared.primary
        scrubber.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.32)
        scrubber.setThumbImage(PlayerControlsView.makeThumb(), for: .normal)
        scrubber.addTarget(self, action: #selector(scrubberTouchDown), for: .touchDown)
        scrubber.addTarget(self, action: #selector(scrubberChanged), for: .valueChanged)
        scrubber.addTarget(self, action: #selector(scrubberTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        scrubber.accessibilityLabel = "Playback position"

        chapterBar.translatesAutoresizingMaskIntoConstraints = false
        chapterBar.onChapterSelected = { [weak self] time in
            self?.onAction?(.seek(to: time))
        }

        bottomBar.addSubview(currentTimeLabel)
        bottomBar.addSubview(durationLabel)
        bottomBar.addSubview(scrubber)
        bottomBar.addSubview(chapterBar)

        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionRow.axis = .horizontal
        actionRow.alignment = .center
        actionRow.distribution = .equalSpacing
        bottomBar.addSubview(actionRow)

        configureTextButton(qualityButton, title: "Auto", accessibility: "Quality")
        qualityButton.addTarget(self, action: #selector(qualityTapped), for: .touchUpInside)
        configureTextButton(speedButton, title: "1x", accessibility: "Playback speed")
        speedButton.addTarget(self, action: #selector(speedTapped), for: .touchUpInside)

        subtitlesButton.configure(icon: .subtitles, color: .white, size: 22.0)
        subtitlesButton.accessibilityLabel = "Subtitles"
        subtitlesButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onAction?(.subtitles)
        }

        chaptersButton.configure(icon: .chapter, color: .white, size: 22.0)
        chaptersButton.accessibilityLabel = "Chapters"
        chaptersButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onAction?(.chapters)
        }

        queueButton.configure(icon: .queue, color: .white, size: 22.0)
        queueButton.accessibilityLabel = "Queue"
        queueButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onAction?(.queue)
        }

        sleepButton.configure(icon: .clock, color: .white, size: 22.0)
        sleepButton.accessibilityLabel = "Sleep timer"
        sleepButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onAction?(.sleepTimer)
        }

        sponsorButton.configure(icon: .check, color: .white, size: 22.0)
        sponsorButton.accessibilityLabel = "SponsorBlock"
        sponsorButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onAction?(.sponsorBlock)
        }

        fullscreenButton.configure(icon: .fullscreen, color: .white, size: 22.0)
        fullscreenButton.accessibilityLabel = "Full screen"
        fullscreenButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onAction?(.fullscreen)
        }

        for control in [qualityButton, speedButton, subtitlesButton, chaptersButton, queueButton, sleepButton, sponsorButton, fullscreenButton] {
            control.translatesAutoresizingMaskIntoConstraints = false
            actionRow.addArrangedSubview(control)
        }

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),

            currentTimeLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: FlowSpacing.xl),
            currentTimeLabel.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: FlowSpacing.md),

            durationLabel.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -FlowSpacing.xl),
            durationLabel.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),

            scrubber.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: FlowSpacing.md),
            scrubber.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -FlowSpacing.md),
            scrubber.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),

            chapterBar.leadingAnchor.constraint(equalTo: scrubber.leadingAnchor),
            chapterBar.trailingAnchor.constraint(equalTo: scrubber.trailingAnchor),
            chapterBar.topAnchor.constraint(equalTo: scrubber.bottomAnchor, constant: -2.0),

            actionRow.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: FlowSpacing.md),
            actionRow.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -FlowSpacing.md),
            actionRow.topAnchor.constraint(equalTo: chapterBar.bottomAnchor, constant: FlowSpacing.xs),
            actionRow.bottomAnchor.constraint(equalTo: bottomBar.safeAreaLayoutGuide.bottomAnchor, constant: -FlowSpacing.sm),
            actionRow.heightAnchor.constraint(equalToConstant: 44.0),
        ])
    }

    private func buildOverlays() {
        scrimTop.translatesAutoresizingMaskIntoConstraints = false
        scrimTop.isUserInteractionEnabled = false
        addSubview(scrimTop)

        scrimBottom.translatesAutoresizingMaskIntoConstraints = false
        scrimBottom.isUserInteractionEnabled = false
        addSubview(scrimBottom)

        bufferingIndicator.translatesAutoresizingMaskIntoConstraints = false
        bufferingIndicator.color = .white
        bufferingIndicator.hidesWhenStopped = true
        addSubview(bufferingIndicator)

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = FlowTypography.bodyMedium
        errorLabel.textColor = .white
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 4
        errorLabel.isHidden = true
        addSubview(errorLabel)

        errorRetryButton.translatesAutoresizingMaskIntoConstraints = false
        errorRetryButton.isHidden = true
        errorRetryButton.onTap = { [weak self] in
            self?.onRetry?()
        }
        addSubview(errorRetryButton)

        NSLayoutConstraint.activate([
            scrimTop.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrimTop.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrimTop.topAnchor.constraint(equalTo: topAnchor),
            scrimTop.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.28),

            scrimBottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrimBottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrimBottom.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrimBottom.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.42),

            bufferingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            bufferingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20.0),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: FlowSpacing.xxl),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -FlowSpacing.xxl),
            errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420.0),

            errorRetryButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorRetryButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: FlowSpacing.lg),
        ])
    }

    private func configureTextButton(_ button: UIButton, title: String, accessibility: String) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = FlowTypography.labelLarge
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        button.accessibilityLabel = accessibility
    }

    private static func makeThumb() -> UIImage {
        let size = CGSize(width: 14.0, height: 14.0)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        let context = UIGraphicsGetCurrentContext()
        context?.setFillColor(UIColor.white.cgColor)
        context?.fillEllipse(in: CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }

    // MARK: - Rendering

    /// Applies a snapshot.
    func render(snapshot: PlaybackSnapshot, isFullscreen: Bool, hasChapters: Bool, hasSponsorSegments: Bool) {
        titleLabel.text = snapshot.item?.title
        subtitleLabel.text = snapshot.item?.channelName
        subtitleLabel.isHidden = (snapshot.item?.channelName ?? "").isEmpty

        let playing = snapshot.isPlaying
        playButton.setIcon(playing ? .pause : .play)
        playButton.accessibilityLabel = playing ? "Pause" : "Play"

        duration = snapshot.duration
        scrubber.maximumValue = Float(max(snapshot.duration, 1.0))
        if !isScrubbing {
            scrubber.value = Float(min(max(snapshot.position, 0.0), max(snapshot.duration, 1.0)))
            currentTimeLabel.text = Formatters.playbackTime(snapshot.position)
        }
        durationLabel.text = snapshot.duration > 0 ? Formatters.playbackTime(snapshot.duration) : "Live"
        chapterBar.setPosition(snapshot.position)

        speedButton.setTitle(Formatters.playbackSpeed(Double(snapshot.rate)), for: .normal)
        fullscreenButton.setIcon(isFullscreen ? .fullscreen : .fullscreen)
        fullscreenButton.accessibilityLabel = isFullscreen ? "Exit full screen" : "Full screen"
        chaptersButton.isHidden = !hasChapters
        sponsorButton.isHidden = !hasSponsorSegments
        pipButton.isHidden = !PiPController.isSupported

        if snapshot.isBuffering && snapshot.error == nil {
            bufferingIndicator.startAnimating()
        } else {
            bufferingIndicator.stopAnimating()
        }

        if let error = snapshot.error {
            errorLabel.text = error
            errorLabel.isHidden = false
            errorRetryButton.isHidden = false
            bufferingIndicator.stopAnimating()
        } else {
            errorLabel.isHidden = true
            errorRetryButton.isHidden = true
        }
    }

    /// Sets the quality label the menu button shows.
    func setQualityLabel(_ label: String) {
        qualityButton.setTitle(label, for: .normal)
    }

    /// Sets the chapter bar's content.
    func setChapters(_ chapters: [ChapterBarView.ChapterSegment], segments: [SponsorBlockSegment], duration: TimeInterval) {
        chapterBar.setChapters(chapters, duration: duration)
        chapterBar.setSegments(segments)
    }

    /// Whether the sleep timer is running, shown as a tinted clock.
    func setSleepTimerActive(_ active: Bool) {
        sleepButton.setIconColor(active ? FlowTheme.shared.primary : .white)
        sleepButton.accessibilityLabel = active ? "Sleep timer active" : "Sleep timer"
    }

    /// Shows or hides the whole chrome.
    func setVisible(_ visible: Bool, animated: Bool) {
        isVisible = visible
        let target: CGFloat = visible ? 1.0 : 0.0
        let work = {
            self.topBar.alpha = target
            self.bottomBar.alpha = target
            self.centreRow.alpha = target
            self.scrimTop.alpha = target
            self.scrimBottom.alpha = target
        }
        if animated {
            FlowMotion.animate(work)
        } else {
            work()
        }
        topBar.isUserInteractionEnabled = visible
        bottomBar.isUserInteractionEnabled = visible
        centreRow.isUserInteractionEnabled = visible
        // The error and the spinner stay visible even when the chrome hides, so a stalled video
        // still tells the viewer what is happening.
        if !visible {
            bufferingIndicator.isHidden = false
        }
    }

    /// Repaints the chrome in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        scrubber.minimumTrackTintColor = scheme.primary
        chapterBar.applyTheme()
        errorRetryButton.applyTheme()
        titleLabel.textColor = .white
        currentTimeLabel.textColor = .white
    }

    /// Switches between the normal and compact layouts.
    func setCompact(_ compact: Bool) {
        guard compact != isCompact else { return }
        isCompact = compact
        subtitleLabel.isHidden = compact || (subtitleLabel.text ?? "").isEmpty
        centreRow.spacing = compact ? FlowSpacing.xl : FlowSpacing.xxl
        actionRow.spacing = compact ? FlowSpacing.xs : 0.0
        for control in [subtitlesButton, chaptersButton, queueButton, sleepButton, sponsorButton] {
            control.isHidden = compact && control !== subtitlesButton
        }
        setNeedsLayout()
    }

    // MARK: - Scrubber

    @objc private func scrubberTouchDown() {
        isScrubbing = true
        onAction?(.seekBegan)
    }

    @objc private func scrubberChanged() {
        let time = TimeInterval(scrubber.value)
        currentTimeLabel.text = Formatters.playbackTime(time)
        chapterBar.setPosition(time)
    }

    @objc private func scrubberTouchUp() {
        isScrubbing = false
        onAction?(.seek(to: TimeInterval(scrubber.value)))
    }

    @objc private func qualityTapped() {
        onAction?(.quality)
    }

    @objc private func speedTapped() {
        onAction?(.speed)
    }
}

/// A vertical gradient used behind the player's chrome so white controls stay readable over a bright
/// frame. It is the one gradient the player uses, and it fades to transparent rather than to a
/// colour, so it never tints the video.
final class GradientScrim: UIView {

    enum Direction {
        case top
        case bottom
    }

    private let gradient = CAGradientLayer()
    private let direction: Direction

    init(direction: Direction) {
        self.direction = direction
        super.init(frame: .zero)
        gradient.colors = [
            UIColor.black.withAlphaComponent(0.62).cgColor,
            UIColor.black.withAlphaComponent(0.0).cgColor,
        ]
        switch direction {
        case .top:
            gradient.startPoint = CGPoint(x: 0.5, y: 0.0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1.0)
        case .bottom:
            gradient.startPoint = CGPoint(x: 0.5, y: 1.0)
            gradient.endPoint = CGPoint(x: 0.5, y: 0.0)
        }
        layer.addSublayer(gradient)
    }

    required init?(coder: NSCoder) {
        direction = .top
        super.init(coder: coder)
        layer.addSublayer(gradient)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}

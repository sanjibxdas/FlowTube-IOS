import UIKit
import AVFoundation

/// The video player screen.
///
/// It is the whole of the watch page's video half: the layer, the chrome, the gesture layer, the
/// subtitle overlay, PiP and the sheets the controls open. The playback itself belongs to
/// `PlaybackService`; this screen observes the service's snapshot and renders it, which is what
/// lets the mini player keep playing when the viewer leaves.
///
/// Rotation is handled by overriding `supportedInterfaceOrientations` and asking UIKit to rotate.
/// iOS 12's Info.plist lists only portrait for iPhone, so the full-screen button uses
/// `UIDevice.setValue(_:forKey:)` on the orientation key, the supported route before iOS 16's
/// `requestGeometryUpdate`.
final class VideoPlayerViewController: UIViewController {

    // MARK: - Dependencies

    private let service: PlaybackService
    private let bag = ObservationBag()

    /// The video the screen is showing.
    private(set) var videoId: String

    /// Called when the viewer taps back. The watch screen dismisses or pops.
    var onBack: (() -> Void)?

    /// Called when the viewer taps the title or the metadata button.
    var onOpenDetails: (() -> Void)?

    // MARK: - Views

    private let layerView = PlayerLayerView()
    private let controls = PlayerControlsView()
    private let subtitleRenderer = SubtitleRenderer()
    private let hud = PlayerHUD()
    private let doubleTapIndicator = DoubleTapSeekIndicator()
    private let tapShield = UIControl()

    // MARK: - Controllers

    private let gestures = PlayerGestureController()
    private let pip = PiPController()

    // MARK: - State

    /// Whether the chrome is showing.
    private var controlsVisible = true
    /// The auto-hide work item.
    private var hideWorkItem: DispatchWorkItem?
    /// Whether the viewer is scrubbing, which suspends auto-hide.
    private var isScrubbing = false
    /// Whether the screen is in full screen.
    private(set) var isFullscreen = false
    /// The chapters of the current video.
    private var chapters: [ChapterBarView.ChapterSegment] = []
    /// The loaded subtitle track.
    private var subtitleTrack: SubtitleTrack?
    /// The caption track the viewer picked, kept across quality changes.
    private var selectedCaption: CaptionTrack?
    /// The quality label the menu shows.
    private var qualityLabel = "Auto"
    /// Whether this screen has already applied the initial autoplay.
    private var hasStarted = false

    /// How long the chrome stays up after a tap, matching the Android player's three seconds.
    static let autoHideDelay: TimeInterval = 3.0

    // MARK: - Init

    init(videoId: String, service: PlaybackService = .shared) {
        self.videoId = videoId
        self.service = service
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        videoId = ""
        service = .shared
        super.init(coder: coder)
    }

    deinit {
        hideWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
        if let observer = timeObserverToken {
            service.player.removeTimeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildViews()
        wireControls()
        wireGestures()
        wirePiP()
        observeService()
        observeTheme()
        updateChapters()
        applyQualityLabel()
        showControls(autoHide: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        service.player.play()
        attachTimeObserver()
        applySubtitleStyle()
        if let caption = selectedCaption {
            loadSubtitle(caption)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hideWorkItem?.cancel()
        detachTimeObserver()
        if isMovingFromParent || isBeingDismissed {
            if pip.isActive {
                pip.stop()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasStarted {
            hasStarted = true
            service.play()
        }
    }

    override var prefersStatusBarHidden: Bool {
        return isFullscreen || !controlsVisible
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        return .fade
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return isFullscreen ? .allButUpsideDown : .portrait
    }

    override var shouldAutorotate: Bool {
        return true
    }

    // MARK: - Construction

    private func buildViews() {
        layerView.translatesAutoresizingMaskIntoConstraints = false
        layerView.player = service.player
        view.addSubview(layerView)

        tapShield.translatesAutoresizingMaskIntoConstraints = false
        tapShield.backgroundColor = .clear
        view.addSubview(tapShield)

        subtitleRenderer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subtitleRenderer)

        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)

        doubleTapIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(doubleTapIndicator)

        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        NSLayoutConstraint.activate([
            layerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            layerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            layerView.topAnchor.constraint(equalTo: view.topAnchor),
            layerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            tapShield.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tapShield.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tapShield.topAnchor.constraint(equalTo: view.topAnchor),
            tapShield.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            subtitleRenderer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subtitleRenderer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            subtitleRenderer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -72.0),
            subtitleRenderer.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.4),

            hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hud.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            hud.widthAnchor.constraint(equalToConstant: 168.0),

            doubleTapIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            doubleTapIndicator.widthAnchor.constraint(equalToConstant: 132.0),
            doubleTapIndicator.heightAnchor.constraint(equalToConstant: 132.0),

            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.topAnchor.constraint(equalTo: view.topAnchor),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func wireControls() {
        controls.onAction = { [weak self] action in
            self?.handle(action)
        }
        controls.onRetry = { [weak self] in
            guard let self = self else { return }
            self.service.load(videoId: self.videoId, autoplay: true, completion: nil)
        }
    }

    private func wireGestures() {
        gestures.attach(to: tapShield, service: service)
        gestures.onSingleTap = { [weak self] in
            self?.toggleControls()
        }
        gestures.onFeedback = { [weak self] feedback in
            self?.show(feedback: feedback)
        }
        gestures.onSeekBegan = { [weak self] in
            self?.isScrubbing = true
            self?.showControls(autoHide: false)
        }
        gestures.onSeekCommitted = { [weak self] time in
            guard let self = self else { return }
            self.isScrubbing = false
            self.service.seek(to: time)
            self.showControls(autoHide: true)
        }
        gestures.onDoubleTapSeek = { [weak self] delta in
            self?.doubleTapIndicator.show(delta: delta)
        }
    }

    private func wirePiP() {
        pip.attach(to: layerView.playerLayer)
        pip.onActiveChanged = { [weak self] active in
            guard let self = self else { return }
            self.controls.isHidden = active
            self.subtitleRenderer.isHidden = active
            if active {
                self.hideWorkItem?.cancel()
            }
        }
        pip.onRestoreRequested = { [weak self] in
            self?.onBack?()
        }
    }

    private func observeService() {
        bag.add(service.state.observe { [weak self] snapshot in
            self?.render(snapshot)
        })
        bag.add(service.addItemObserver { [weak self] item in
            guard let self = self else { return }
            if let item = item, item.videoId != self.videoId {
                self.videoId = item.videoId
            }
            self.updateChapters()
            self.applyQualityLabel()
        })
        service.onSegmentSkipped = { [weak self] _ in
            self?.showControls(autoHide: true)
        }
    }

    private func observeTheme() {
        bag.add(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
    }

    private func applyTheme() {
        controls.applyTheme()
        subtitleRenderer.reloadStyleFromPreferences()
    }

    // MARK: - Rendering

    private func render(_ snapshot: PlaybackSnapshot) {
        controls.render(
            snapshot: snapshot,
            isFullscreen: isFullscreen,
            hasChapters: !chapters.isEmpty,
            hasSponsorSegments: !service.sponsorSegments.isEmpty
        )
        controls.setChapters(chapters, segments: visibleSegments(), duration: snapshot.duration)
        controls.setSleepTimerActive(SleepTimer.shared.isActive)
        gestures.duration = snapshot.duration
        if snapshot.item?.videoId != videoId {
            videoId = snapshot.item?.videoId ?? videoId
        }
        updateChaptersIfNeeded()
    }

    private func visibleSegments() -> [SponsorBlockSegment] {
        guard PrefsStore.shared.bool(for: .sponsorBlockShowOnSeekBar, fallback: true) else { return [] }
        let enabled = Set(PrefsStore.shared.sponsorBlockCategories)
        return service.sponsorSegments.filter { enabled.contains($0.category) }
    }

    private func updateChapters() {
        let page = service.currentPage
        let duration = service.currentDuration
        var result: [ChapterBarView.ChapterSegment] = []
        if let page = page {
            for (index, chapter) in page.chapters.enumerated() {
                let fallback: TimeInterval
                if index + 1 < page.chapters.count {
                    fallback = page.chapters[index + 1].startTime
                } else {
                    fallback = duration > 0 ? duration : chapter.startTime + 60.0
                }
                result.append(ChapterBarView.ChapterSegment(chapter: chapter, fallbackEnd: fallback))
            }
        }
        chapters = result
        controls.setChapters(chapters, segments: visibleSegments(), duration: duration)
    }

    private func updateChaptersIfNeeded() {
        let pageChapters = service.currentPage?.chapters.count ?? 0
        if pageChapters != chapters.count {
            updateChapters()
        }
    }

    private func applyQualityLabel() {
        let stored = PrefsStore.shared.string(for: .playbackQuality) ?? "auto"
        if stored == "auto" {
            qualityLabel = "Auto"
        } else if let page = service.currentPage,
                  let match = PlayerItemFactory.qualities(for: page).first(where: { $0.value == stored }) {
            qualityLabel = match.label
        } else {
            qualityLabel = stored
        }
        controls.setQualityLabel(qualityLabel)
    }

    // MARK: - Controls visibility

    /// Shows the chrome and schedules the auto-hide.
    func showControls(autoHide: Bool) {
        controlsVisible = true
        controls.setVisible(true, animated: true)
        setNeedsStatusBarAppearanceUpdate()
        hideWorkItem?.cancel()
        guard autoHide, service.player.rate > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard !self.isScrubbing, self.controls.isVisible else { return }
            self.controlsVisible = false
            self.controls.setVisible(false, animated: true)
            self.setNeedsStatusBarAppearanceUpdate()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + VideoPlayerViewController.autoHideDelay, execute: item)
    }

    /// Toggles the chrome.
    func toggleControls() {
        if controlsVisible {
            controlsVisible = false
            controls.setVisible(false, animated: true)
            hideWorkItem?.cancel()
            setNeedsStatusBarAppearanceUpdate()
        } else {
            showControls(autoHide: true)
        }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        guard service.player.rate > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isScrubbing else { return }
            self.controlsVisible = false
            self.controls.setVisible(false, animated: true)
            self.setNeedsStatusBarAppearanceUpdate()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + VideoPlayerViewController.autoHideDelay, execute: item)
    }

    // MARK: - Actions

    private func handle(_ action: PlayerControlsView.Action) {
        switch action {
        case .back:
            onBack?()
        case .playPause:
            service.togglePlayPause()
            showControls(autoHide: service.player.rate > 0)
        case .previous:
            service.playPrevious()
            showControls(autoHide: true)
        case .next:
            service.playNext()
            showControls(autoHide: true)
        case .seekBegan:
            isScrubbing = true
            hideWorkItem?.cancel()
        case .seek(let time):
            isScrubbing = false
            service.seek(to: time)
            showControls(autoHide: true)
        case .settings:
            presentSettingsSheet()
        case .quality:
            presentQualitySheet()
        case .speed:
            presentSpeedSheet()
        case .subtitles:
            presentSubtitleSheet()
        case .chapters:
            presentChaptersSheet()
        case .queue:
            presentQueueSheet()
        case .fullscreen:
            toggleFullscreen()
        case .pictureInPicture:
            togglePiP()
        case .sleepTimer:
            presentSleepTimerSheet()
        case .sponsorBlock:
            presentSponsorBlockSheet()
        }
    }

    /// Toggles full screen, rotating the device on a phone.
    func toggleFullscreen() {
        isFullscreen.toggle()
        controls.setCompact(isFullscreen)
        if isFullscreen {
            setNeedsStatusBarAppearanceUpdate()
            requestOrientation(.landscapeRight)
        } else {
            setNeedsStatusBarAppearanceUpdate()
            requestOrientation(.portrait)
        }
        showControls(autoHide: true)
    }

    private func requestOrientation(_ orientation: UIInterfaceOrientation) {
        UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }

    /// Enters or leaves PiP.
    func togglePiP() {
        guard PiPController.isSupported else {
            FlowSnackbar.show("Picture in picture is not available on this device.")
            return
        }
        if pip.isActive {
            pip.stop()
            return
        }
        if !pip.start() {
            FlowSnackbar.show("Picture in picture is not ready yet.")
        }
    }

    // MARK: - Time and subtitles

    private var timeObserverToken: Any?

    private func attachTimeObserver() {
        guard timeObserverToken == nil else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = service.player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            self.subtitleRenderer.update(time: seconds)
        }
    }

    private func detachTimeObserver() {
        if let token = timeObserverToken {
            service.player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    private func applySubtitleStyle() {
        subtitleRenderer.style = SubtitleStyle.current
    }

    /// Loads a caption track and shows it.
    func loadSubtitle(_ track: CaptionTrack) {
        selectedCaption = track
        if let cached = SubtitleLoader.shared.cached(track: track) {
            let loaded = SubtitleTrack(
                languageCode: track.languageCode,
                name: track.name,
                isAutomatic: track.isAutomatic,
                file: cached,
                url: track.baseUrl
            )
            subtitleTrack = loaded
            subtitleRenderer.setTrack(loaded)
            return
        }
        SubtitleLoader.shared.load(track: track) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                FlowSnackbar.showError("Subtitles could not load: " + error.displayMessage)
            case .success(let file):
                let loaded = SubtitleTrack(
                    languageCode: track.languageCode,
                    name: track.name,
                    isAutomatic: track.isAutomatic,
                    file: file,
                    url: track.baseUrl
                )
                self.subtitleTrack = loaded
                self.subtitleRenderer.setTrack(loaded)
            }
        }
    }

    /// Turns subtitles off.
    func clearSubtitles() {
        selectedCaption = nil
        subtitleTrack = nil
        subtitleRenderer.setTrack(nil)
    }

    // MARK: - HUD

    private func show(feedback: PlayerGestureController.Feedback) {
        switch feedback {
        case .none:
            hud.hide()
        case .brightness(let value):
            hud.show(kind: .brightness, value: value)
        case .volume(let value):
            hud.show(kind: .volume, value: value)
        case .seek(let target, let delta):
            hud.showSeek(target: target, delta: delta)
        case .doubleTapSeek:
            break
        }
    }

    // MARK: - Sheets

    private func presentSettingsSheet() {
        let content = PlayerSettingsSheet(
            quality: qualityLabel,
            speed: Double(service.player.rate > 0 ? service.player.rate : PrefsStore.shared.playbackSpeed),
            subtitlesOn: subtitleTrack != nil,
            sleepTimerActive: SleepTimer.shared.isActive,
            sponsorBlockOn: PrefsStore.shared.bool(for: .sponsorBlockEnabled, fallback: true),
            pictureInPictureOn: PrefsStore.shared.bool(for: .pictureInPicture, fallback: true)
        )
        content.onSelect = { [weak self] row in
            guard let self = self else { return }
            switch row {
            case .quality: self.presentQualitySheet()
            case .speed: self.presentSpeedSheet()
            case .subtitles: self.presentSubtitleSheet()
            case .chapters: self.presentChaptersSheet()
            case .sleepTimer: self.presentSleepTimerSheet()
            case .sponsorBlock: self.presentSponsorBlockSheet()
            case .pictureInPicture: self.togglePiP()
            case .details: self.onOpenDetails?()
            }
        }
        let sheet = FlowSheet(content: content, title: "Player settings", detent: .medium)
        sheet.present(from: self)
    }

    private func presentQualitySheet() {
        guard let page = service.currentPage else {
            FlowSnackbar.show("Quality can be changed once the video has loaded.")
            return
        }
        let options = PlayerItemFactory.qualities(for: page)
        let content = ChoiceSheetContent(
            options: options.map { ChoiceSheetContent.Option(title: $0.label, subtitle: $0.value == "auto" ? "Adapts to your connection" : nil, isSelected: $0.value == (PrefsStore.shared.string(for: .playbackQuality) ?? "auto")) }
        )
        content.onSelect = { [weak self] index in
            guard let self = self, let choice = options.element(at: index) else { return }
            PrefsStore.shared.set(choice.value, for: .playbackQuality)
            self.qualityLabel = choice.label
            self.controls.setQualityLabel(choice.label)
            self.service.setQuality(choice.value)
            self.showControls(autoHide: true)
        }
        let sheet = FlowSheet(content: content, title: "Quality", detent: .medium)
        sheet.present(from: self)
    }

    private func presentSpeedSheet() {
        let speeds: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        let current = Double(service.player.rate > 0 ? service.player.rate : PrefsStore.shared.playbackSpeed)
        let content = ChoiceSheetContent(
            options: speeds.map { speed in
                ChoiceSheetContent.Option(
                    title: Formatters.playbackSpeed(speed),
                    subtitle: speed == 1.0 ? "Normal" : nil,
                    isSelected: abs(speed - current) < 0.01
                )
            }
        )
        content.onSelect = { [weak self] index in
            guard let self = self, let speed = speeds.element(at: index) else { return }
            self.service.setPlaybackSpeed(speed)
            self.showControls(autoHide: true)
        }
        let sheet = FlowSheet(content: content, title: "Playback speed", detent: .medium)
        sheet.present(from: self)
    }

    private func presentSubtitleSheet() {
        let tracks = service.captionTracks
        var options: [ChoiceSheetContent.Option] = [
            ChoiceSheetContent.Option(title: "Off", subtitle: nil, isSelected: selectedCaption == nil),
        ]
        for track in tracks {
            let subtitle = track.isAutomatic ? "Auto-generated" : track.languageCode.uppercased()
            options.append(ChoiceSheetContent.Option(
                title: track.name,
                subtitle: subtitle,
                isSelected: selectedCaption?.languageCode == track.languageCode
            ))
        }
        let content = ChoiceSheetContent(options: options)
        content.onSelect = { [weak self] index in
            guard let self = self else { return }
            if index == 0 {
                self.clearSubtitles()
                PrefsStore.shared.set(false, for: .subtitlesEnabled)
                return
            }
            guard let track = tracks.element(at: index - 1) else { return }
            PrefsStore.shared.set(true, for: .subtitlesEnabled)
            PrefsStore.shared.set(track.languageCode, for: .subtitleLanguage)
            self.loadSubtitle(track)
        }
        let sheet = FlowSheet(content: content, title: "Subtitles", detent: tracks.isEmpty ? .medium : .large)
        sheet.present(from: self)
    }

    private func presentChaptersSheet() {
        guard !chapters.isEmpty else {
            FlowSnackbar.show("This video has no chapters.")
            return
        }
        let content = ChapterListView()
        content.setChapters(chapters, currentTime: service.currentPosition)
        content.onSelect = { [weak self] time in
            self?.service.seek(to: time)
            self?.showControls(autoHide: true)
        }
        let sheet = FlowSheet(content: content, title: "Chapters", detent: .large)
        sheet.present(from: self)
    }

    private func presentQueueSheet() {
        let sheet = QueueSheetViewController(service: service)
        sheet.present(from: self)
    }

    private func presentSleepTimerSheet() {
        let sheet = SleepTimerSheetController(
            onStartMinutes: { [weak self] minutes in
                self?.service.startSleepTimer(minutes: minutes)
                self?.showControls(autoHide: true)
            },
            onStartEndOfItem: { [weak self] in
                self?.service.startSleepTimerAtEndOfItem()
                self?.showControls(autoHide: true)
            },
            onCancel: { [weak self] in
                self?.service.cancelSleepTimer()
                self?.showControls(autoHide: true)
            }
        )
        sheet.present(from: self)
    }

    private func presentSponsorBlockSheet() {
        let content = SponsorBlockSheetContent(
            segments: service.sponsorSegments,
            enabledCategories: Set(PrefsStore.shared.sponsorBlockCategories),
            autoSkip: PrefsStore.shared.bool(for: .sponsorBlockAutoSkip, fallback: true),
            onToggleAutoSkip: { enabled in
                PrefsStore.shared.set(enabled, for: .sponsorBlockAutoSkip)
            },
            onSeek: { [weak self] time in
                self?.service.seek(to: time)
                self?.showControls(autoHide: true)
            }
        )
        let sheet = FlowSheet(content: content, title: "SponsorBlock", detent: .medium)
        sheet.present(from: self)
    }
}

// MARK: - HUD

/// The small overlay the gesture layer drives: a brightness or volume bar, or a seek bubble.
final class PlayerHUD: UIView {

    enum Kind {
        case brightness
        case volume
    }

    private let iconView = FlowIconView()
    private let bar = UIView()
    private let fill = UIView()
    private let label = UILabel()
    private var fillWidth: NSLayoutConstraint?
    private var hideWorkItem: DispatchWorkItem?

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
        backgroundColor = UIColor.black.withAlphaComponent(0.72)
        layer.cornerRadius = FlowShapes.medium
        layer.masksToBounds = true
        alpha = 0.0
        isUserInteractionEnabled = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.icon = .volume
        iconView.iconColor = .white
        iconView.iconSize = 20.0
        addSubview(iconView)

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        bar.layer.cornerRadius = 2.0
        bar.layer.masksToBounds = true
        addSubview(bar)

        fill.translatesAutoresizingMaskIntoConstraints = false
        fill.backgroundColor = .white
        bar.addSubview(fill)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FlowTypography.labelMedium
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.lg),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20.0),
            iconView.heightAnchor.constraint(equalToConstant: 20.0),

            bar.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: FlowSpacing.md),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.lg),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 4.0),

            fill.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            fill.topAnchor.constraint(equalTo: bar.topAnchor),
            fill.bottomAnchor.constraint(equalTo: bar.bottomAnchor),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.md),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.md),
            label.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: FlowSpacing.sm),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.sm),

            heightAnchor.constraint(equalToConstant: 56.0),
        ])
        fillWidth = fill.widthAnchor.constraint(equalToConstant: 0.0)
        fillWidth?.isActive = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = FlowShapes.medium
    }

    /// Shows a brightness or volume bar at `value`.
    func show(kind: Kind, value: CGFloat) {
        hideWorkItem?.cancel()
        iconView.icon = kind == .brightness ? .sun : .volume
        label.text = "\(Int((value * 100).rounded()))%"
        layoutIfNeeded()
        fillWidth?.constant = max(bar.bounds.width * min(max(value, 0.0), 1.0), 0.0)
        FlowMotion.animate {
            self.alpha = 1.0
            self.layoutIfNeeded()
        }
    }

    /// Shows a seek bubble with the target time and the delta.
    func showSeek(target: TimeInterval, delta: TimeInterval) {
        hideWorkItem?.cancel()
        iconView.icon = delta >= 0 ? .next : .previous
        label.text = Formatters.playbackTime(target)
        fillWidth?.constant = 0.0
        bar.isHidden = true
        FlowMotion.animate {
            self.alpha = 1.0
        }
    }

    /// Hides the HUD.
    func hide() {
        hideWorkItem?.cancel()
        bar.isHidden = false
        FlowMotion.animate {
            self.alpha = 0.0
        }
    }
}

/// The "+10s" / "-10s" bubble a double tap shows.
final class DoubleTapSeekIndicator: UIView {

    private let iconView = FlowIconView()
    private let label = UILabel()
    private var side: CGFloat = 1.0

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
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        layer.cornerRadius = 66.0
        layer.masksToBounds = true
        alpha = 0.0
        isUserInteractionEnabled = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.icon = .next
        iconView.iconColor = .white
        iconView.iconSize = 28.0
        addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FlowTypography.labelLarge
        label.textColor = .white
        label.textAlignment = .center
        label.text = "10 seconds"
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10.0),
            iconView.widthAnchor.constraint(equalToConstant: 28.0),
            iconView.heightAnchor.constraint(equalToConstant: 28.0),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.md),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.md),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: FlowSpacing.xs),
        ])
    }

    /// Shows the bubble for a forward or backward seek.
    func show(delta: TimeInterval) {
        iconView.icon = delta >= 0 ? .next : .previous
        label.text = delta >= 0 ? "10 seconds" : "10 seconds back"
        alpha = 0.0
        transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        FlowMotion.animate({
            self.alpha = 1.0
            self.transform = .identity
        }, completion: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            FlowMotion.animate({
                self?.alpha = 0.0
            }, completion: nil)
        }
    }
}

// MARK: - Settings sheet

/// The player's settings menu: a list of rows that each open a more specific sheet.
final class PlayerSettingsSheet: UIView {

    enum Row {
        case quality
        case speed
        case subtitles
        case chapters
        case sleepTimer
        case sponsorBlock
        case pictureInPicture
        case details
    }

    private let stack = UIStackView()
    private var rows: [(Row, String, String?, FlowIcon)] = []

    /// Called when a row is chosen.
    var onSelect: ((Row) -> Void)?

    init(
        quality: String,
        speed: Double,
        subtitlesOn: Bool,
        sleepTimerActive: Bool,
        sponsorBlockOn: Bool,
        pictureInPictureOn: Bool
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rows = [
            (.quality, "Quality", quality, .settings),
            (.speed, "Playback speed", Formatters.playbackSpeed(speed), .clock),
            (.subtitles, "Subtitles", subtitlesOn ? "On" : "Off", .subtitles),
            (.chapters, "Chapters", nil, .chapter),
            (.sleepTimer, "Sleep timer", sleepTimerActive ? "Active" : nil, .moon),
            (.sponsorBlock, "SponsorBlock", sponsorBlockOn ? "On" : "Off", .check),
            (.pictureInPicture, "Picture in picture", pictureInPictureOn ? "On" : "Off", .pip),
            (.details, "Video details", nil, .notes),
        ]
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
    }

    private func build() {
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0.0
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for (index, row) in rows.enumerated() {
            let button = makeRow(row)
            button.tag = index
            stack.addArrangedSubview(button)
        }
    }

    private func makeRow(_ row: (Row, String, String?, FlowIcon)) -> UIControl {
        let control = UIControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.heightAnchor.constraint(equalToConstant: 52.0).isActive = true

        let icon = FlowIconView.make(row.3, color: FlowTheme.shared.onSurfaceVariant, size: 20.0)
        icon.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(icon)

        let title = UILabel.flow(row.1, font: FlowTypography.bodyLarge, color: FlowTheme.shared.onSurface)
        control.addSubview(title)

        let value = UILabel.flow(row.2 ?? "", font: FlowTypography.bodyMedium, color: FlowTheme.shared.onSurfaceVariant)
        value.textAlignment = .right
        control.addSubview(value)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: FlowSpacing.xl),
            icon.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20.0),
            icon.heightAnchor.constraint(equalToConstant: 20.0),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: FlowSpacing.lg),
            title.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: FlowSpacing.md),
            value.trailingAnchor.constraint(equalTo: control.trailingAnchor, constant: -FlowSpacing.xl),
            value.centerYAnchor.constraint(equalTo: control.centerYAnchor),
        ])
        control.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onSelect?(row.0)
        }
        control.accessibilityTraits = .button
        control.accessibilityLabel = row.1
        return control
    }
}

// MARK: - Choice sheet

/// A simple list of single-choice rows, used by the quality, speed and subtitle sheets.
final class ChoiceSheetContent: UIView, UITableViewDataSource, UITableViewDelegate {

    struct Option {
        let title: String
        let subtitle: String?
        let isSelected: Bool

        init(title: String, subtitle: String? = nil, isSelected: Bool = false) {
            self.title = title
            self.subtitle = subtitle
            self.isSelected = isSelected
        }
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var options: [Option]

    /// Called with the chosen index.
    var onSelect: ((Int) -> Void)?

    init(options: [Option]) {
        self.options = options
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 56.0
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.register(ChoiceCell.self, forCellReuseIdentifier: ChoiceCell.reuseIdentifier)
        addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        options = []
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return options.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ChoiceCell.reuseIdentifier, for: indexPath)
        guard let choiceCell = cell as? ChoiceCell, let option = options.element(at: indexPath.row) else {
            return cell
        }
        choiceCell.configure(title: option.title, subtitle: option.subtitle, isSelected: option.isSelected)
        return choiceCell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(indexPath.row)
        if let sheet = nearestSheet() {
            sheet.dismissSheet()
        }
    }

    private func nearestSheet() -> FlowSheet? {
        var responder: UIResponder? = self
        while let current = responder {
            if let sheet = current as? FlowSheet { return sheet }
            responder = current.next
        }
        return nil
    }
}

/// A row of a choice sheet: the title, an optional subtitle and a check when selected.
private final class ChoiceCell: UITableViewCell {

    static let reuseIdentifier = "ChoiceCell"

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkView = FlowIconView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        selectionStyle = .default
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.bodyLarge
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = FlowTypography.bodySmall
        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.icon = .check
        checkView.iconSize = 20.0
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(checkView)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xl),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.md),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkView.leadingAnchor, constant: -FlowSpacing.md),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1.0),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkView.leadingAnchor, constant: -FlowSpacing.md),
            checkView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.xl),
            checkView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 20.0),
            checkView.heightAnchor.constraint(equalToConstant: 20.0),
        ])
    }

    func configure(title: String, subtitle: String?, isSelected: Bool) {
        let scheme = FlowTheme.shared.scheme
        titleLabel.text = title
        titleLabel.textColor = isSelected ? scheme.primary : scheme.onSurface
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        subtitleLabel.textColor = scheme.onSurfaceVariant
        checkView.isHidden = !isSelected
        checkView.iconColor = scheme.primary
        accessibilityLabel = title
        accessibilityTraits = isSelected ? [.button, .selected] : .button
    }
}

// MARK: - SponsorBlock sheet

/// The SponsorBlock sheet: the segments in the video, with the auto-skip switch.
final class SponsorBlockSheetContent: UIView {

    private let stack = UIStackView()
    private let autoSkipSwitch = UISwitch()

    init(
        segments: [SponsorBlockSegment],
        enabledCategories: Set<String>,
        autoSkip: Bool,
        onToggleAutoSkip: @escaping (Bool) -> Void,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        let switchRow = UIView()
        switchRow.translatesAutoresizingMaskIntoConstraints = false
        let switchLabel = UILabel.flow("Skip automatically", font: FlowTypography.bodyLarge, color: FlowTheme.shared.onSurface)
        switchRow.addSubview(switchLabel)
        autoSkipSwitch.translatesAutoresizingMaskIntoConstraints = false
        autoSkipSwitch.isOn = autoSkip
        autoSkipSwitch.onTintColor = FlowTheme.shared.primary
        autoSkipSwitch.addTarget(self, action: #selector(autoSkipChanged), for: .valueChanged)
        switchRow.addSubview(autoSkipSwitch)
        NSLayoutConstraint.activate([
            switchLabel.leadingAnchor.constraint(equalTo: switchRow.leadingAnchor),
            switchLabel.centerYAnchor.constraint(equalTo: switchRow.centerYAnchor),
            autoSkipSwitch.trailingAnchor.constraint(equalTo: switchRow.trailingAnchor),
            autoSkipSwitch.centerYAnchor.constraint(equalTo: switchRow.centerYAnchor),
            switchRow.heightAnchor.constraint(equalToConstant: 48.0),
        ])
        self.onToggleAutoSkip = onToggleAutoSkip
        stack.addArrangedSubview(switchRow)

        let visible = segments.filter { enabledCategories.contains($0.category) && !$0.isFullVideo }
        if visible.isEmpty {
            let empty = UILabel.flow(
                "No sponsor segments in this video.",
                font: FlowTypography.bodyMedium,
                color: FlowTheme.shared.onSurfaceVariant,
                lines: 2
            )
            stack.addArrangedSubview(empty)
        } else {
            for segment in visible {
                let row = UIControl()
                row.translatesAutoresizingMaskIntoConstraints = false
                row.heightAnchor.constraint(equalToConstant: 44.0).isActive = true
                let swatch = UIView()
                swatch.translatesAutoresizingMaskIntoConstraints = false
                swatch.backgroundColor = UIColor(hex: UInt32(truncatingIfNeeded: segment.color))
                swatch.layer.cornerRadius = 3.0
                row.addSubview(swatch)
                let label = UILabel.flow(
                    segment.displayName,
                    font: FlowTypography.bodyMedium,
                    color: FlowTheme.shared.onSurface
                )
                row.addSubview(label)
                let time = UILabel.flow(
                    Formatters.playbackTime(TimeInterval(segment.startTime)),
                    font: FlowTypography.labelMedium,
                    color: FlowTheme.shared.onSurfaceVariant
                )
                row.addSubview(time)
                NSLayoutConstraint.activate([
                    swatch.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                    swatch.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    swatch.widthAnchor.constraint(equalToConstant: 6.0),
                    swatch.heightAnchor.constraint(equalToConstant: 20.0),
                    label.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: FlowSpacing.md),
                    label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    time.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                    time.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                ])
                let start = TimeInterval(segment.startTime)
                row.addClosureActionForControl(for: .touchUpInside) {
                    onSeek(start)
                }
                stack.addArrangedSubview(row)
            }
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
    }

    private var onToggleAutoSkip: ((Bool) -> Void)?

    @objc private func autoSkipChanged() {
        onToggleAutoSkip?(autoSkipSwitch.isOn)
    }
}

// MARK: - Sleep timer sheet

/// The sleep timer sheet, shared by the video and music players.
final class SleepTimerSheetController: UIView {

    private let stack = UIStackView()
    private let statusLabel = UILabel()
    private let startButton = FlowButton.make("Start", style: .filled)
    private let endOfItemButton = FlowButton.make("End of current item", style: .outlined)
    private let cancelButton = FlowButton.make("Cancel timer", style: .text)
    private var selectedMinutes = 30

    private let onStartMinutes: (Int) -> Void
    private let onStartEndOfItem: () -> Void
    private let onCancel: () -> Void

    init(
        onStartMinutes: @escaping (Int) -> Void,
        onStartEndOfItem: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onStartMinutes = onStartMinutes
        self.onStartEndOfItem = onStartEndOfItem
        self.onCancel = onCancel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        refreshStatus()
    }

    required init?(coder: NSCoder) {
        onStartMinutes = { _ in }
        onStartEndOfItem = {}
        onCancel = {}
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
    }

    private func build() {
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = FlowSpacing.lg
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = FlowTypography.bodyMedium
        statusLabel.textColor = FlowTheme.shared.onSurfaceVariant
        statusLabel.numberOfLines = 2
        stack.addArrangedSubview(statusLabel)

        let chips = FlowChipRow()
        chips.setTitles(SleepTimer.minuteChoices.map { "\($0) min" }, selectedIndex: 4)
        selectedMinutes = SleepTimer.minuteChoices.element(at: 4) ?? 30
        chips.onSelect = { [weak self] index in
            guard let self = self else { return }
            self.selectedMinutes = SleepTimer.minuteChoices.element(at: index) ?? 30
        }
        stack.addArrangedSubview(chips)

        startButton.onTap = { [weak self] in
            guard let self = self else { return }
            self.onStartMinutes(self.selectedMinutes)
            self.refreshStatus()
        }
        stack.addArrangedSubview(startButton)

        endOfItemButton.onTap = { [weak self] in
            guard let self = self else { return }
            self.onStartEndOfItem()
            self.refreshStatus()
        }
        stack.addArrangedSubview(endOfItemButton)

        cancelButton.onTap = { [weak self] in
            guard let self = self else { return }
            self.onCancel()
            self.refreshStatus()
        }
        stack.addArrangedSubview(cancelButton)
    }

    private func refreshStatus() {
        if let status = SleepTimer.shared.statusText {
            statusLabel.text = "Sleep timer active — " + status
            cancelButton.isHidden = false
        } else {
            statusLabel.text = "Playback stops when the timer ends."
            cancelButton.isHidden = true
        }
    }

    /// Presents the timer controls in a sheet.
    func present(from presenter: UIViewController? = nil) {
        let sheet = FlowSheet(content: self, title: "Sleep timer", detent: .medium)
        sheet.present(from: presenter)
    }
}

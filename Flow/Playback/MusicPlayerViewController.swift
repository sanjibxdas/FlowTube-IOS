import UIKit
import AVFoundation
import MediaPlayer

/// The full-screen music player.
///
/// It is the music half of the app's one player: the same `PlaybackService` that drives the video
/// screen and the mini player, drawn as a now-playing page. The layout follows the Android player:
/// the artwork takes whatever height the controls leave it, the title and artist sit under it, then
/// the seek bar, the transport, and a row of toggles for lyrics, shuffle, repeat, the queue and the
/// sleep timer.
///
/// The artwork is a pager: dragging it sideways pulls the neighbouring track's cover in and a
/// committed drag skips. It also drifts slowly while the music plays, which is the parallax the
/// Android player gets from its motion artwork; the drift is a transform on the image inside a
/// clipping frame, so nothing around it moves.
final class MusicPlayerViewController: UIViewController {

    // MARK: - Dependencies

    private let service: PlaybackService
    private let bag = ObservationBag()

    /// Called when the viewer closes the player.
    var onBack: (() -> Void)?

    // MARK: - Views

    private let background = MusicBackgroundView()
    private let closeButton = FlowIconButton()
    private let moreButton = FlowIconButton()
    private let nowPlayingLabel = UILabel()
    private let playingFromLabel = UILabel()
    private let artwork = MusicArtworkView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let likeButton = FlowIconButton()
    private let downloadButton = FlowIconButton()
    private let progress = MusicProgressView()
    private let previousButton = FlowIconButton()
    private let playButton = FlowIconButton()
    private let nextButton = FlowIconButton()
    private let lyricsButton = MusicToggleButton()
    private let shuffleButton = MusicToggleButton()
    private let repeatButton = MusicToggleButton()
    private let queueButton = MusicToggleButton()
    private let sleepButton = MusicToggleButton()
    private let content = UIView()
    private let spinner = UIActivityIndicatorView(style: .whiteLarge)

    // MARK: - State

    private var currentItem: PlaybackQueueItem?
    private var artworkWidth: NSLayoutConstraint?
    private var isScrubbing = false
    private var hasAppeared = false

    // MARK: - Init

    init(service: PlaybackService = .shared) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        service = .shared
        super.init(coder: coder)
    }

    deinit {
        bag.cancelAll()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildViews()
        wireActions()
        observeService()
        observeTheme()
        applyTheme()
        render(service.state.value)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        artwork.setAnimating(service.state.value.isPlaying)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        updateArtworkWidth()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        artwork.setAnimating(false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateArtworkWidth()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Construction

    private func buildViews() {
        view.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
        ])
        let width = content.widthAnchor.constraint(equalToConstant: 600.0)
        width.priority = .defaultHigh
        width.isActive = true

        buildTopBar()
        buildArtwork()
        buildHeader()
        buildProgress()
        buildTransport()
        buildActionRow()

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        spinner.color = FlowTheme.shared.onSurfaceVariant
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: artwork.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
        ])
    }

    private func buildTopBar() {
        closeButton.configure(icon: .chevronDown, color: FlowTheme.shared.onSurface, size: 26.0)
        closeButton.accessibilityLabel = "Close player"
        content.addSubviewForAutoLayout(closeButton)

        moreButton.configure(icon: .more, color: FlowTheme.shared.onSurface, size: 24.0)
        moreButton.accessibilityLabel = "More options"
        content.addSubviewForAutoLayout(moreButton)

        nowPlayingLabel.translatesAutoresizingMaskIntoConstraints = false
        nowPlayingLabel.font = FlowTypography.titleMediumEmphasized
        nowPlayingLabel.textAlignment = .center
        nowPlayingLabel.text = "NOW PLAYING"
        nowPlayingLabel.accessibilityTraits = .header
        content.addSubview(nowPlayingLabel)

        playingFromLabel.translatesAutoresizingMaskIntoConstraints = false
        playingFromLabel.font = FlowTypography.bodySmall
        playingFromLabel.textAlignment = .center
        playingFromLabel.numberOfLines = 1
        playingFromLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(playingFromLabel)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: FlowSpacing.md),
            closeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: FlowSpacing.xs),
            closeButton.widthAnchor.constraint(equalToConstant: 44.0),
            closeButton.heightAnchor.constraint(equalToConstant: 44.0),

            moreButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -FlowSpacing.md),
            moreButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 44.0),
            moreButton.heightAnchor.constraint(equalToConstant: 44.0),

            nowPlayingLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            nowPlayingLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor, constant: -7.0),
            nowPlayingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: FlowSpacing.md),
            nowPlayingLabel.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -FlowSpacing.md),

            playingFromLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            playingFromLabel.topAnchor.constraint(equalTo: nowPlayingLabel.bottomAnchor, constant: 1.0),
            playingFromLabel.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 72.0),
            playingFromLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -72.0),
        ])
    }

    private func buildArtwork() {
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.onSkipNext = { [weak self] in
            self?.service.playNext()
        }
        artwork.onSkipPrevious = { [weak self] in
            self?.service.playPrevious()
        }
        content.addSubview(artwork)

        NSLayoutConstraint.activate([
            artwork.topAnchor.constraint(equalTo: playingFromLabel.bottomAnchor, constant: FlowSpacing.lg),
            artwork.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            artwork.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: FlowSpacing.playerHorizontalPadding),
            artwork.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -FlowSpacing.playerHorizontalPadding),
            artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor),
        ])
        let width = artwork.widthAnchor.constraint(equalToConstant: 260.0)
        width.priority = .defaultHigh
        width.isActive = true
        artworkWidth = width
    }

    private func buildHeader() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleLargeEmphasized
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.addSubview(titleLabel)

        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        artistLabel.font = FlowTypography.bodyLarge
        artistLabel.numberOfLines = 1
        artistLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(artistLabel)

        likeButton.configure(icon: .heart, color: FlowTheme.shared.onSurfaceVariant, size: 22.0)
        likeButton.accessibilityLabel = "Like"
        content.addSubviewForAutoLayout(likeButton)

        downloadButton.configure(icon: .download, color: FlowTheme.shared.onSurfaceVariant, size: 22.0)
        downloadButton.accessibilityLabel = "Download"
        content.addSubviewForAutoLayout(downloadButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: FlowSpacing.playerHorizontalPadding),
            titleLabel.topAnchor.constraint(equalTo: artwork.bottomAnchor, constant: FlowSpacing.lg),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: downloadButton.leadingAnchor, constant: -FlowSpacing.md),

            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),
            artistLabel.trailingAnchor.constraint(lessThanOrEqualTo: downloadButton.leadingAnchor, constant: -FlowSpacing.md),

            downloadButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -FlowSpacing.playerHorizontalPadding + FlowSpacing.sm),
            downloadButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor, constant: 6.0),
            downloadButton.widthAnchor.constraint(equalToConstant: 44.0),
            downloadButton.heightAnchor.constraint(equalToConstant: 44.0),

            likeButton.trailingAnchor.constraint(equalTo: downloadButton.leadingAnchor, constant: -FlowSpacing.xxs),
            likeButton.centerYAnchor.constraint(equalTo: downloadButton.centerYAnchor),
            likeButton.widthAnchor.constraint(equalToConstant: 44.0),
            likeButton.heightAnchor.constraint(equalToConstant: 44.0),
        ])
    }

    private func buildProgress() {
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.onSeekBegan = { [weak self] in
            self?.isScrubbing = true
        }
        progress.onSeek = { [weak self] time in
            self?.service.seek(to: time)
        }
        progress.onSeekEnded = { [weak self] in
            self?.isScrubbing = false
        }
        content.addSubview(progress)

        NSLayoutConstraint.activate([
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: FlowSpacing.playerHorizontalPadding),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -FlowSpacing.playerHorizontalPadding),
            progress.topAnchor.constraint(equalTo: artistLabel.bottomAnchor, constant: FlowSpacing.xl),
        ])
    }

    private func buildTransport() {
        previousButton.configure(icon: .previous, color: FlowTheme.shared.onSurface, size: 34.0)
        previousButton.accessibilityLabel = "Previous track"
        content.addSubviewForAutoLayout(previousButton)

        playButton.configure(icon: .play, color: FlowTheme.shared.onPrimary, size: 34.0)
        playButton.backgroundColor = FlowTheme.shared.primary
        playButton.layer.cornerRadius = 36.0
        playButton.accessibilityLabel = "Play"
        content.addSubviewForAutoLayout(playButton)

        nextButton.configure(icon: .next, color: FlowTheme.shared.onSurface, size: 34.0)
        nextButton.accessibilityLabel = "Next track"
        content.addSubviewForAutoLayout(nextButton)

        NSLayoutConstraint.activate([
            playButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            playButton.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: FlowSpacing.xl),
            playButton.widthAnchor.constraint(equalToConstant: 72.0),
            playButton.heightAnchor.constraint(equalToConstant: 72.0),

            previousButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -FlowSpacing.xxl),
            previousButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 56.0),
            previousButton.heightAnchor.constraint(equalToConstant: 56.0),

            nextButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: FlowSpacing.xxl),
            nextButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 56.0),
            nextButton.heightAnchor.constraint(equalToConstant: 56.0),
        ])
    }

    private func buildActionRow() {
        let row = UIStackView(arrangedSubviews: [
            lyricsButton, shuffleButton, repeatButton, queueButton, sleepButton,
        ])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = FlowSpacing.xs
        content.addSubview(row)

        lyricsButton.configure(icon: .notes, color: FlowTheme.shared.onSurfaceVariant, size: 20.0)
        lyricsButton.accessibilityLabel = "Lyrics"
        shuffleButton.configure(icon: .shuffle, color: FlowTheme.shared.onSurfaceVariant, size: 20.0)
        shuffleButton.accessibilityLabel = "Shuffle"
        repeatButton.configure(icon: .repeatAll, color: FlowTheme.shared.onSurfaceVariant, size: 20.0)
        repeatButton.accessibilityLabel = "Repeat"
        queueButton.configure(icon: .queue, color: FlowTheme.shared.onSurfaceVariant, size: 20.0)
        queueButton.accessibilityLabel = "Queue"
        sleepButton.configure(icon: .moon, color: FlowTheme.shared.onSurfaceVariant, size: 20.0)
        sleepButton.accessibilityLabel = "Sleep timer"

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: FlowSpacing.playerHorizontalPadding),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -FlowSpacing.playerHorizontalPadding),
            row.topAnchor.constraint(equalTo: playButton.bottomAnchor, constant: FlowSpacing.xl),
            row.heightAnchor.constraint(equalToConstant: 42.0),
            row.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -FlowSpacing.lg),
        ])
    }

    private func wireActions() {
        closeButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onBack?()
        }
        moreButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.presentMoreSheet()
        }
        playButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.service.togglePlayPause()
        }
        previousButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.service.playPrevious()
        }
        nextButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.service.playNext()
        }
        likeButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.toggleLike()
        }
        downloadButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.downloadCurrentTrack()
        }
        lyricsButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.presentLyrics()
        }
        shuffleButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            guard let self = self else { return }
            self.service.setShuffle(!self.service.queue.shuffleEnabled)
        }
        repeatButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.service.cycleRepeatMode()
        }
        queueButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.presentQueue()
        }
        sleepButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.presentSleepTimer()
        }
    }

    private func observeService() {
        bag.add(service.state.observe { [weak self] snapshot in
            self?.render(snapshot)
        })
        bag.add(service.addItemObserver { [weak self] item in
            guard let self = self else { return }
            self.currentItem = item
            self.artwork.setItem(item, next: self.nextItem(), previous: self.previousItem())
            self.refreshLikeState()
            self.refreshDownloadState()
        })
        bag.add(FlowEventBus.shared.on("downloads") { [weak self] _ in
            self?.refreshDownloadState()
        })
        bag.add(FlowEventBus.shared.on("playlists") { [weak self] _ in
            self?.refreshLikeState()
        })
    }

    private func observeTheme() {
        bag.add(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
    }

    // MARK: - Layout

    /// Sizes the artwork to whatever the controls leave, capped by the column width, the way the
    /// Android player computes it.
    private func updateArtworkWidth() {
        guard hasAppeared else { return }
        let column = min(content.bounds.width, 600.0)
        let available = column - FlowSpacing.playerHorizontalPadding * 2.0
        // Everything under the artwork: top bar, header, progress, transport and the action row.
        let reserved: CGFloat = 44.0 + FlowSpacing.lg + 52.0 + 52.0 + 72.0 + 42.0
            + FlowSpacing.xl * 3.0 + FlowSpacing.lg * 2.0 + FlowSpacing.lg
        let height = content.bounds.height - reserved
        let side = min(available, max(height, 140.0))
        guard abs((artworkWidth?.constant ?? 0.0) - side) > 0.5 else { return }
        artworkWidth?.constant = side
    }

    // MARK: - Rendering

    private func render(_ snapshot: PlaybackSnapshot) {
        let item = snapshot.item
        if item?.videoId != currentItem?.videoId {
            currentItem = item
            artwork.setItem(item, next: nextItem(), previous: previousItem())
            refreshLikeState()
            refreshDownloadState()
            titleLabel.text = item?.title ?? "Nothing playing"
            artistLabel.text = item?.channelName ?? ""
            accessibilityLabel = item.map { "\($0.title), \($0.channelName)" }
        }
        playingFromLabel.text = snapshot.queueTitle ?? (item?.isMusic == true ? "Flow Music" : "Flow")
        titleLabel.text = item?.title ?? "Nothing playing"
        artistLabel.text = item?.channelName ?? ""

        playButton.setIcon(snapshot.isPlaying ? .pause : .play)
        playButton.accessibilityLabel = snapshot.isPlaying ? "Pause" : "Play"
        artwork.setAnimating(snapshot.isPlaying && hasAppeared)

        if !isScrubbing {
            progress.setPosition(snapshot.position, duration: snapshot.duration)
        }

        shuffleButton.setActive(snapshot.shuffleEnabled)
        switch snapshot.repeatMode {
        case .off:
            repeatButton.setIcon(.repeatAll)
            repeatButton.setActive(false)
            repeatButton.accessibilityLabel = "Repeat off"
        case .all:
            repeatButton.setIcon(.repeatAll)
            repeatButton.setActive(true)
            repeatButton.accessibilityLabel = "Repeat all"
        case .one:
            repeatButton.setIcon(.repeatOne)
            repeatButton.setActive(true)
            repeatButton.accessibilityLabel = "Repeat one"
        }
        refreshSleepTimer()

        if snapshot.isBuffering {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        if let error = snapshot.error {
            artistLabel.text = error
        }
    }

    private func refreshSleepTimer() {
        sleepButton.setActive(SleepTimer.shared.isActive)
        sleepButton.accessibilityLabel = SleepTimer.shared.isActive ? "Sleep timer active" : "Sleep timer"
    }

    private func refreshLikeState() {
        guard let item = currentItem else {
            likeButton.setIcon(.heart)
            return
        }
        let liked = LikedMusic.contains(videoId: item.videoId)
        likeButton.setIcon(liked ? .liked : .heart)
        likeButton.setIconColor(liked ? FlowTheme.shared.primary : FlowTheme.shared.onSurfaceVariant)
        likeButton.accessibilityLabel = liked ? "Liked" : "Like"
        likeButton.accessibilityTraits = liked ? [.button, .selected] : .button
    }

    private func refreshDownloadState() {
        guard let item = currentItem else { return }
        let record = DownloadStore.shared.record(videoId: item.videoId)
        switch record?.state {
        case .completed?:
            downloadButton.setIcon(.downloaded)
            downloadButton.setIconColor(FlowTheme.shared.primary)
            downloadButton.accessibilityLabel = "Downloaded"
        case .downloading?, .queued?:
            downloadButton.setIcon(.download)
            downloadButton.setIconColor(FlowTheme.shared.primary)
            downloadButton.accessibilityLabel = "Downloading"
        case .paused?:
            downloadButton.setIcon(.download)
            downloadButton.setIconColor(FlowTheme.shared.onSurfaceVariant)
            downloadButton.accessibilityLabel = "Download paused"
        default:
            downloadButton.setIcon(.download)
            downloadButton.setIconColor(FlowTheme.shared.onSurfaceVariant)
            downloadButton.accessibilityLabel = "Download"
        }
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        background.applyTheme()
        closeButton.setIconColor(scheme.onSurface)
        moreButton.setIconColor(scheme.onSurface)
        nowPlayingLabel.textColor = scheme.onSurface.withAlpha(0.9)
        playingFromLabel.textColor = scheme.onSurfaceVariant
        titleLabel.textColor = scheme.onSurface
        artistLabel.textColor = scheme.onSurfaceVariant
        playButton.setIconColor(scheme.onPrimary)
        playButton.backgroundColor = scheme.primary
        previousButton.setIconColor(scheme.onSurface)
        nextButton.setIconColor(scheme.onSurface)
        progress.applyTheme()
        artwork.applyTheme()
        refreshLikeState()
        refreshDownloadState()
        refreshSleepTimer()
        let inactive = scheme.onSurfaceVariant
        lyricsButton.setIconColor(inactive)
        shuffleButton.setIconColor(service.queue.shuffleEnabled ? scheme.primary : inactive)
        queueButton.setIconColor(inactive)
        spinner.color = scheme.onSurfaceVariant
        for button in [lyricsButton, shuffleButton, repeatButton, queueButton, sleepButton] {
            button.applyTheme()
        }
    }

    // MARK: - Queue neighbours

    private func nextItem() -> PlaybackQueueItem? {
        guard let index = service.queue.nextIndex(manual: true) else { return nil }
        return service.queue.item(at: index)
    }

    private func previousItem() -> PlaybackQueueItem? {
        guard let index = service.queue.previousIndex() else { return nil }
        return service.queue.item(at: index)
    }

    // MARK: - Actions

    private func toggleLike() {
        guard let item = currentItem else { return }
        let liked = LikedMusic.toggle(item: item)
        refreshLikeState()
        FlowSnackbar.show(liked ? "Added to liked music" : "Removed from liked music")
    }

    private func downloadCurrentTrack() {
        guard let item = currentItem else { return }
        if let record = DownloadStore.shared.record(videoId: item.videoId) {
            switch record.state {
            case .completed:
                FlowSnackbar.show("Already downloaded")
                return
            case .queued, .downloading:
                FlowSnackbar.show("Downloading")
                return
            case .paused:
                DownloadStore.shared.resume(videoId: item.videoId)
                FlowSnackbar.show("Download resumed")
                return
            case .failed, .cancelled:
                break
            }
        }
        DownloadStore.shared.enqueue(
            videoId: item.videoId,
            title: item.title,
            channelName: item.channelName,
            thumbnailUrl: item.thumbnailUrl,
            quality: PrefsStore.shared.string(for: .downloadQuality) ?? "720p",
            duration: item.duration,
            isMusic: true
        )
        FlowSnackbar.show("Download queued")
        refreshDownloadState()
    }

    // MARK: - Sheets

    private func presentLyrics() {
        guard let item = currentItem else { return }
        let controller = LyricsViewController(
            videoId: item.videoId,
            title: item.title,
            artist: item.channelName,
            duration: item.duration,
            service: service
        )
        controller.present(from: self)
    }

    private func presentQueue() {
        let sheet = QueueSheetViewController(service: service)
        sheet.present(from: self)
    }

    private func presentSleepTimer() {
        let sheet = SleepTimerSheetController(
            onStartMinutes: { [weak self] minutes in
                self?.service.startSleepTimer(minutes: minutes)
                self?.refreshSleepTimer()
            },
            onStartEndOfItem: { [weak self] in
                self?.service.startSleepTimerAtEndOfItem()
                self?.refreshSleepTimer()
            },
            onCancel: { [weak self] in
                self?.service.cancelSleepTimer()
                self?.refreshSleepTimer()
            }
        )
        sheet.present(from: self)
    }

    private func presentSpeedSheet() {
        let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        let current = Double(PrefsStore.shared.playbackSpeed)
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
            guard let speed = speeds.element(at: index) else { return }
            self?.service.setPlaybackSpeed(speed)
        }
        let sheet = FlowSheet(content: content, title: "Playback speed", detent: .medium)
        sheet.present(from: self)
    }

    private func presentMoreSheet() {
        var actions: [FlowActionSheetContent.Action] = [
            FlowActionSheetContent.Action(title: "Playback speed", icon: .clock) { [weak self] in
                self?.presentSpeedSheet()
            },
            FlowActionSheetContent.Action(title: "Equalizer", icon: .equalizer) { [weak self] in
                self?.presentEqualizer()
            },
            FlowActionSheetContent.Action(title: "Sleep timer", icon: .moon) { [weak self] in
                self?.presentSleepTimer()
            },
            FlowActionSheetContent.Action(title: "Add to playlist", icon: .playlist) { [weak self] in
                self?.presentPlaylistPicker()
            },
            FlowActionSheetContent.Action(title: "Share", icon: .share) { [weak self] in
                self?.shareCurrentTrack()
            },
        ]
        if let item = currentItem, !item.channelId.isEmpty {
            actions.insert(
                FlowActionSheetContent.Action(title: "Go to artist", icon: .music) { [weak self] in
                    self?.openArtist(channelId: item.channelId)
                },
                at: 0
            )
        }
        if let record = currentItem.flatMap({ DownloadStore.shared.record(videoId: $0.videoId) }),
           record.state == .completed {
            actions.append(FlowActionSheetContent.Action(title: "Remove download", icon: .trash, isDestructive: true) { [weak self] in
                guard let self = self, let item = self.currentItem else { return }
                DownloadStore.shared.remove(videoId: item.videoId)
                self.refreshDownloadState()
            })
        }
        let content = FlowActionSheetContent(actions: actions)
        let sheet = FlowSheet(content: content, title: nil, detent: .medium)
        content.onActionSelected = { [weak sheet] in
            sheet?.dismissSheet()
        }
        sheet.present(from: self)
    }

    private func presentEqualizer() {
        let controller = EqualizerViewController()
        controller.present(from: self)
    }

    private func presentPlaylistPicker() {
        guard let item = currentItem else { return }
        let playlists = PlaylistStore.shared.localPlaylists()
        var options = playlists.map { playlist in
            ChoiceSheetContent.Option(
                title: playlist.title,
                subtitle: "\(playlist.items.count) videos",
                isSelected: PlaylistStore.shared.contains(videoId: item.videoId, in: playlist.playlistId)
            )
        }
        options.append(ChoiceSheetContent.Option(title: "New playlist", subtitle: "Create one and add this track", isSelected: false))
        let content = ChoiceSheetContent(options: options)
        content.onSelect = { [weak self] index in
            guard let self = self else { return }
            if index == playlists.count {
                let identifier = PlaylistStore.shared.createPlaylist(title: item.channelName.isEmpty ? "New playlist" : item.channelName)
                PlaylistStore.shared.addVideo(
                    videoId: item.videoId,
                    title: item.title,
                    channelName: item.channelName,
                    thumbnailUrl: item.thumbnailUrl,
                    duration: item.duration,
                    to: identifier
                )
                FlowSnackbar.show("Added to playlist")
                return
            }
            guard let playlist = playlists.element(at: index) else { return }
            if PlaylistStore.shared.contains(videoId: item.videoId, in: playlist.playlistId) {
                PlaylistStore.shared.removeVideo(videoId: item.videoId, from: playlist.playlistId)
                FlowSnackbar.show("Removed from " + playlist.title)
            } else {
                PlaylistStore.shared.addVideo(
                    videoId: item.videoId,
                    title: item.title,
                    channelName: item.channelName,
                    thumbnailUrl: item.thumbnailUrl,
                    duration: item.duration,
                    to: playlist.playlistId
                )
                FlowSnackbar.show("Added to " + playlist.title)
            }
        }
        let sheet = FlowSheet(content: content, title: "Add to playlist", detent: .medium)
        sheet.present(from: self)
    }

    private func shareCurrentTrack() {
        guard let item = currentItem else { return }
        let text = item.isMusic
            ? "https://music.youtube.com/watch?v=" + item.videoId
            : "https://www.youtube.com/watch?v=" + item.videoId
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = moreButton
        activity.popoverPresentationController?.sourceRect = moreButton.bounds
        present(activity, animated: true, completion: nil)
    }

    private func openArtist(channelId: String) {
        // The shell owns navigation; the player only asks for the destination.
        Router.shared.openChannel(id: channelId)
    }

    /// Presents the player from a host controller.
    func present(from presenter: UIViewController? = nil) {
        let host = presenter ?? FlowSheet.topViewController()
        host?.present(self, animated: true, completion: nil)
    }
}

// MARK: - Progress

/// The seek bar with its two time labels. Dragging previews the target time and commits on release,
/// which is what keeps the position from fighting the player while a finger is down.
final class MusicProgressView: UIView {

    private let slider = UISlider()
    private let currentLabel = UILabel()
    private let durationLabel = UILabel()
    private var duration: TimeInterval = 0

    /// Called when a drag starts.
    var onSeekBegan: (() -> Void)?
    /// Called with the committed position.
    var onSeek: ((TimeInterval) -> Void)?
    /// Called when a drag ends.
    var onSeekEnded: (() -> Void)?

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

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumTrackTintColor = FlowTheme.shared.primary
        slider.maximumTrackTintColor = FlowTheme.shared.onSurface.withAlpha(0.24)
        slider.setThumbImage(MusicProgressView.thumb(), for: .normal)
        slider.addTarget(self, action: #selector(touchDown), for: .touchDown)
        slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(touchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.accessibilityLabel = "Playback position"
        addSubview(slider)

        for label in [currentLabel, durationLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = FlowTypography.labelSmall
            label.textColor = FlowTheme.shared.onSurfaceVariant
        }
        currentLabel.text = "0:00"
        durationLabel.text = "0:00"
        durationLabel.textAlignment = .right
        addSubview(currentLabel)
        addSubview(durationLabel)

        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.topAnchor.constraint(equalTo: topAnchor),
            slider.heightAnchor.constraint(equalToConstant: 28.0),

            currentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xs),
            currentLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 1.0),
            currentLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xs),
            durationLabel.centerYAnchor.constraint(equalTo: currentLabel.centerYAnchor),
            durationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: currentLabel.trailingAnchor, constant: FlowSpacing.md),
        ])
    }

    /// Updates the bar from the player, unless the viewer is dragging it.
    func setPosition(_ position: TimeInterval, duration: TimeInterval) {
        self.duration = max(duration, 0.0)
        slider.maximumValue = Float(max(self.duration, 1.0))
        slider.value = Float(min(max(position, 0.0), max(self.duration, 1.0)))
        currentLabel.text = Formatters.playbackTime(position)
        durationLabel.text = Formatters.playbackTime(self.duration)
    }

    /// Repaints the bar in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        slider.minimumTrackTintColor = scheme.primary
        slider.maximumTrackTintColor = scheme.onSurface.withAlpha(0.24)
        currentLabel.textColor = scheme.onSurfaceVariant
        durationLabel.textColor = scheme.onSurfaceVariant
    }

    @objc private func touchDown() {
        onSeekBegan?()
    }

    @objc private func valueChanged() {
        currentLabel.text = Formatters.playbackTime(TimeInterval(slider.value))
    }

    @objc private func touchUp() {
        onSeek?(TimeInterval(slider.value))
        onSeekEnded?()
    }

    private static func thumb() -> UIImage {
        let size = CGSize(width: 14.0, height: 14.0)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        let context = UIGraphicsGetCurrentContext()
        context?.setFillColor(UIColor.white.cgColor)
        context?.fillEllipse(in: CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }
}

// MARK: - Toggle button

/// One of the action row's toggles: a rounded segment that fills with the accent when it is on.
final class MusicToggleButton: UIControl {

    private let iconView = FlowIconView()
    private var icon: FlowIcon = .shuffle
    private var iconColor: UIColor = FlowTheme.shared.onSurfaceVariant
    private var isActive = false

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
        layer.cornerRadius = 21.0
        layer.masksToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isUserInteractionEnabled = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20.0),
            iconView.heightAnchor.constraint(equalToConstant: 20.0),
        ])
        accessibilityTraits = .button
        applyTheme()
    }

    func configure(icon: FlowIcon, color: UIColor, size: CGFloat) {
        self.icon = icon
        iconColor = color
        iconView.icon = icon
        iconView.iconColor = color
        iconView.iconSize = size
        applyTheme()
    }

    func setIcon(_ icon: FlowIcon) {
        self.icon = icon
        iconView.icon = icon
    }

    func setIconColor(_ color: UIColor) {
        iconColor = color
        iconView.iconColor = color
    }

    /// Turns the segment's fill on or off.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        accessibilityTraits = active ? [.button, .selected] : .button
        applyTheme()
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = isActive ? scheme.primaryContainer : scheme.onSurface.withAlpha(0.08)
        iconView.iconColor = isActive ? scheme.onPrimaryContainer : iconColor
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.6 : 1.0
        }
    }
}

// MARK: - Artwork

/// The now-playing cover.
///
/// The cover is drawn inside a clipping frame and is slightly larger than it, so it can drift: a
/// slow vertical sway while the music plays, and a counter-move while a sideways drag pulls the
/// neighbouring covers in. Both are transforms on the image, never on the frame, so the corner
/// radius and the layout stay put.
final class MusicArtworkView: UIView {

    /// Called when a drag past the threshold commits to the next track.
    var onSkipNext: (() -> Void)?
    /// Called when a drag past the threshold commits to the previous track.
    var onSkipPrevious: (() -> Void)?

    private let currentImage = AsyncImageView()
    private let nextImage = AsyncImageView()
    private let previousImage = AsyncImageView()
    private let placeholderIcon = FlowIconView()
    private var currentURL: String = ""
    private var nextURL: String = ""
    private var previousURL: String = ""
    private var dragOffset: CGFloat = 0.0
    private var isAnimating = false
    private var driftTimer: Timer?

    /// How much larger than the frame the cover is drawn, which is what allows the drift.
    private static let overscan: CGFloat = 1.12
    /// The fraction of a drag that moves the cover itself rather than its neighbour.
    private static let parallaxFactor: CGFloat = 0.12

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
        backgroundColor = FlowTheme.shared.scheme.surfaceContainerHigh
        applyCornerRadius(FlowShapes.medium)
        clipsToBounds = true

        for image in [previousImage, nextImage, currentImage] {
            image.translatesAutoresizingMaskIntoConstraints = false
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
            addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: leadingAnchor),
                image.trailingAnchor.constraint(equalTo: trailingAnchor),
                image.topAnchor.constraint(equalTo: topAnchor),
                image.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.icon = .music
        placeholderIcon.iconSize = 56.0
        addSubview(placeholderIcon)
        NSLayoutConstraint.activate([
            placeholderIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderIcon.widthAnchor.constraint(equalToConstant: 56.0),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 56.0),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        applyTheme()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyDrift()
    }

    /// Sets the covers. The neighbours are only loaded when the queue has them, so a single-track
    /// queue does not fetch anything it will never show.
    func setItem(_ item: PlaybackQueueItem?, next: PlaybackQueueItem?, previous: PlaybackQueueItem?) {
        let newURL = item?.thumbnailUrl ?? ""
        if newURL != currentURL {
            currentURL = newURL
            currentImage.setImage(url: newURL, placeholder: FlowTheme.shared.scheme.surfaceContainerHigh)
            dragOffset = 0.0
        }
        let newNext = next?.thumbnailUrl ?? ""
        if newNext != nextURL {
            nextURL = newNext
            nextImage.setImage(url: newNext, placeholder: FlowTheme.shared.scheme.surfaceContainerHigh)
        }
        let newPrevious = previous?.thumbnailUrl ?? ""
        if newPrevious != previousURL {
            previousURL = newPrevious
            previousImage.setImage(url: newPrevious, placeholder: FlowTheme.shared.scheme.surfaceContainerHigh)
        }
        placeholderIcon.isHidden = !newURL.isEmpty
        applyDrift()
    }

    /// Starts or stops the slow sway that gives the cover depth while music plays.
    func setAnimating(_ animating: Bool) {
        guard animating != isAnimating else { return }
        isAnimating = animating
        driftTimer?.invalidate()
        driftTimer = nil
        guard animating, !UIAccessibility.isReduceMotionEnabled else {
            UIView.animate(withDuration: FlowMotion.emphasized, animations: {
                self.currentImage.transform = .identity
            }, completion: nil)
            return
        }
        var phase: CGFloat = 0.0
        driftTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase = phase == 0.0 ? 1.0 : 0.0
            UIView.animate(
                withDuration: 4.0,
                delay: 0.0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
                animations: {
                    self.applyDrift(driftPhase: phase)
                },
                completion: nil
            )
        }
        applyDrift()
    }

    private func applyDrift(driftPhase: CGFloat = 0.0) {
        let side = max(bounds.width, 1.0)
        let overscan = side * (MusicArtworkView.overscan - 1.0) / 2.0
        let sway = (driftPhase - 0.5) * 2.0 * overscan * 0.5
        // The cover is scaled up so the overscan is available on every side, then moved by the
        // drag (with the neighbour counter-moving) and by the idle sway.
        let scale = MusicArtworkView.overscan
        let dx = dragOffset + dragOffset * MusicArtworkView.parallaxFactor
        currentImage.transform = CGAffineTransform(translationX: dx, y: sway).scaledBy(x: scale, y: scale)
        previousImage.transform = CGAffineTransform(translationX: -side + dragOffset, y: 0)
        nextImage.transform = CGAffineTransform(translationX: side + dragOffset, y: 0)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        let side = max(bounds.width, 1.0)
        switch recognizer.state {
        case .changed:
            let hasNeighbour = translation.x < 0 ? !nextURL.isEmpty : !previousURL.isEmpty
            let resistance: CGFloat = hasNeighbour ? 1.0 : 0.3
            dragOffset = min(max(translation.x * resistance, -side), side)
            applyDrift()
        case .ended, .cancelled:
            let threshold = side * 0.3
            let target = dragOffset
            if target < -threshold && !nextURL.isEmpty {
                commitSkip(forward: true, side: side)
            } else if target > threshold && !previousURL.isEmpty {
                commitSkip(forward: false, side: side)
            } else {
                dragOffset = 0.0
                FlowMotion.animate({
                    self.applyDrift()
                }, completion: nil)
            }
        default:
            break
        }
    }

    /// Slides the pulled-in cover the rest of the way, then changes track. The new cover arrives
    /// behind the animation, so the handoff has no visible gap.
    private func commitSkip(forward: Bool, side: CGFloat) {
        let direction: CGFloat = forward ? -1.0 : 1.0
        UIView.animate(
            withDuration: FlowMotion.standard,
            delay: 0.0,
            options: [.curveEaseInOut],
            animations: {
                self.dragOffset = direction * side
                self.applyDrift()
            },
            completion: { _ in
                self.dragOffset = 0.0
                if forward {
                    self.onSkipNext?()
                } else {
                    self.onSkipPrevious?()
                }
                self.applyDrift()
            }
        )
    }

    /// Repaints the placeholder in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = scheme.surfaceContainerHigh
        placeholderIcon.iconColor = scheme.onSurfaceVariant
        for image in [currentImage, nextImage, previousImage] {
            image.placeholderColor = scheme.surfaceContainerHigh
        }
    }

    deinit {
        driftTimer?.invalidate()
    }
}

// MARK: - Background

/// The player's backdrop: a vertical wash from the palette's low surface to its background, with a
/// faint accent glow behind the artwork. It repaints with the theme rather than following the
/// artwork, which keeps text contrast predictable in every palette.
final class MusicBackgroundView: UIView {

    private let gradient = CAGradientLayer()
    private let glow = CAGradientLayer()

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
        gradient.startPoint = CGPoint(x: 0.5, y: 0.0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1.0)
        layer.addSublayer(gradient)

        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1.0, y: 1.0)
        layer.addSublayer(glow)
        applyTheme()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        let side = min(bounds.width, bounds.height) * 0.9
        glow.frame = CGRect(
            x: bounds.midX - side / 2.0,
            y: bounds.height * 0.12,
            width: side,
            height: side
        )
        CATransaction.commit()
    }

    /// Repaints the wash in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        gradient.colors = [
            scheme.surfaceContainerLow.cgColor,
            scheme.background.cgColor,
        ]
        glow.colors = [
            scheme.primary.withAlpha(0.16).cgColor,
            scheme.primary.withAlpha(0.0).cgColor,
        ]
    }
}

// MARK: - Liked music

/// The viewer's liked tracks.
///
/// iOS has no account-level like API, and the port keeps everything on the device, so a like is a
/// membership of one local playlist. That is the same data the Library screen lists, which means a
/// liked song is visible and playable from there rather than being a flag only the player knows.
enum LikedMusic {

    /// The title of the playlist likes are kept in.
    static let playlistTitle = "Liked music"

    /// Whether `videoId` is liked.
    static func contains(videoId: String) -> Bool {
        guard let playlist = playlist() else { return false }
        return PlaylistStore.shared.contains(videoId: videoId, in: playlist.playlistId)
    }

    /// Adds or removes an item, returning whether it is liked afterwards.
    @discardableResult
    static func toggle(item: PlaybackQueueItem) -> Bool {
        let store = PlaylistStore.shared
        let identifier = playlist()?.playlistId ?? store.createPlaylist(title: playlistTitle)
        if store.contains(videoId: item.videoId, in: identifier) {
            store.removeVideo(videoId: item.videoId, from: identifier)
            return false
        }
        store.addVideo(
            videoId: item.videoId,
            title: item.title,
            channelName: item.channelName,
            thumbnailUrl: item.thumbnailUrl,
            duration: item.duration,
            to: identifier
        )
        return true
    }

    /// The liked playlist, created on first use.
    private static func playlist() -> StoredPlaylist? {
        return PlaylistStore.shared.localPlaylists().first { $0.title == playlistTitle }
    }
}

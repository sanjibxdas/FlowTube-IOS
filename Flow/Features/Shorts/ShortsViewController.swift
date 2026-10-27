import AVFoundation
import UIKit

/// The Shorts reel: one full-screen Short per page, paged vertically with a swipe, each page playing
/// its own `AVPlayer`.
///
/// The reel is a `UICollectionView` with a paging flow layout rather than a scroll view of players,
/// so only the cells near the viewport exist and only the visible one plays. Tapping pauses,
/// double-tapping likes, and the right rail carries the like, dislike, comments, share and save
/// actions. A progress bar along the bottom tracks the current Short.
final class ShortsViewController: UIViewController {

    // MARK: - Navigation

    /// Called when the viewer opens a Short's comments.
    var onOpenComments: ((Video) -> Void)?
    /// Called when the viewer opens the Short's channel.
    var onOpenChannel: ((String) -> Void)?
    /// Called when the viewer asks for the linked video of a Short.
    var onOpenVideo: ((Video) -> Void)?
    /// Called when the viewer closes the reel.
    var onClose: (() -> Void)?

    // MARK: - State

    private let viewModel: ShortsViewModel
    private var collectionView: UICollectionView!
    private let layout = ShortsFlowLayout()
    private let closeButton = FlowIconButton.make(.back, color: .white, size: 24.0, target: nil, action: nil)
    private let titleLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private var progressWidth: NSLayoutConstraint?
    private var progressObservation: NSKeyValueObservation?
    private var themeToken: ObservationToken?
    private var currentCell: ShortsCell?
    private var currentIndex = 0
    private var didAutoPlay = false
    private var isPausedByViewer = false

    // MARK: - Construction

    init(viewModel: ShortsViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    convenience init(source: ShortsSource = .feed) {
        self.init(viewModel: ShortsViewModel(source: source))
    }

    required init?(coder: NSCoder) {
        viewModel = ShortsViewModel(source: .feed)
        super.init(coder: coder)
    }

    deinit {
        progressObservation?.invalidate()
        themeToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildChrome()
        buildCollection()
        bind()
        viewModel.load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        configureAudioSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        currentCell?.pause()
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        currentCell?.pause()
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    // MARK: - Build

    private func buildChrome() {
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityLabel = "Close"
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        view.addSubview(closeButton)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Shorts"
        titleLabel.font = FlowTypography.titleMedium
        titleLabel.textColor = .white
        view.addSubview(titleLabel)

        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        view.addSubview(progressTrack)

        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressFill.backgroundColor = .white
        progressTrack.addSubview(progressFill)

        progressWidth = progressFill.widthAnchor.constraint(equalToConstant: 0.0)
        progressWidth?.isActive = true

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.sm),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: FlowSpacing.xs),

            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            progressTrack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressTrack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 3.0),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
        ])
    }

    private func buildCollection() {
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0.0
        layout.minimumInteritemSpacing = 0.0

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .black
        collectionView.isPagingEnabled = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(ShortsCell.self, forCellWithReuseIdentifier: ShortsCell.reuseIdentifier)
        view.insertSubview(collectionView, at: 0)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func bind() {
        viewModel.onChange = { [weak self] in
            self?.render()
        }
        viewModel.onLikeChanged = { [weak self] videoId, liked in
            self?.currentCell?.setLiked(liked)
            if liked {
                FlowSnackbar.show("Liked")
            }
        }
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
    }

    // MARK: - Rendering

    private func render() {
        collectionView.reloadData()
        if viewModel.videos.isEmpty {
            if let message = viewModel.errorMessage {
                FlowSnackbar.showError(message)
            }
            return
        }
        if !didAutoPlay {
            didAutoPlay = true
            let indexPath = IndexPath(item: min(currentIndex, viewModel.videos.count - 1), section: 0)
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
            playCurrent()
        }
    }

    private func applyTheme() {
        view.backgroundColor = .black
        collectionView.backgroundColor = .black
        titleLabel.textColor = .white
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        progressFill.backgroundColor = .white
    }

    // MARK: - Playback

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetooth])
            try session.setActive(true)
        } catch {
            // Playback still works with the session the app already has; the reel does not fail
            // because a category could not be set.
        }
    }

    private func playCurrent() {
        guard let video = viewModel.videos.element(at: currentIndex) else { return }
        guard let cell = collectionView.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? ShortsCell else {
            return
        }
        currentCell = cell
        cell.configure(
            with: video,
            viewModel: viewModel,
            onComments: { [weak self] in self?.onOpenComments?(video) },
            onChannel: { [weak self] in
                guard !video.channelId.isEmpty else { return }
                self?.onOpenChannel?(video.channelId)
            },
            onShare: { [weak self] in self?.share(video) },
            onSave: { [weak self] in self?.save(video) },
            onLinkedVideo: { [weak self] in self?.onOpenVideo?(video) }
        )
        cell.onProgress = { [weak self] fraction in
            self?.updateProgress(fraction)
        }
        cell.prepareAndPlay()
        viewModel.prefetchItems(from: currentIndex, count: 2)
        viewModel.markCurrent(index: currentIndex)
    }

    private func updateProgress(_ fraction: Double) {
        let width = progressTrack.bounds.width * CGFloat(min(max(fraction, 0.0), 1.0))
        progressWidth?.constant = width
    }

    private func pauseCurrent() {
        currentCell?.pause()
    }

    // MARK: - Actions

    @objc private func handleClose() {
        pauseCurrent()
        if let navigation = navigationController, navigation.viewControllers.first !== self {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true, completion: nil)
        }
        onClose?()
    }

    private func share(_ video: Video) {
        let text = video.shareURL
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX,
            y: view.bounds.midY,
            width: 1.0,
            height: 1.0
        )
        present(activity, animated: true, completion: nil)
    }

    private func save(_ video: Video) {
        let saved = viewModel.toggleSave(video)
        FlowSnackbar.show(saved ? "Short saved" : "Short unsaved")
        currentCell?.setSaved(saved)
    }
}

// MARK: - Collection data source

extension ShortsViewController: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return viewModel.videos.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ShortsCell.reuseIdentifier, for: indexPath)
        guard let shortsCell = cell as? ShortsCell, let video = viewModel.videos.element(at: indexPath.item) else {
            return cell
        }
        shortsCell.configure(
            with: video,
            viewModel: viewModel,
            onComments: { [weak self] in self?.onOpenComments?(video) },
            onChannel: { [weak self] in
                guard !video.channelId.isEmpty else { return }
                self?.onOpenChannel?(video.channelId)
            },
            onShare: { [weak self] in self?.share(video) },
            onSave: { [weak self] in self?.save(video) },
            onLinkedVideo: { [weak self] in self?.onOpenVideo?(video) }
        )
        shortsCell.onProgress = { [weak self] fraction in
            guard let self = self else { return }
            if self.currentIndex == indexPath.item {
                self.updateProgress(fraction)
            }
        }
        shortsCell.onSingleTap = { [weak self] in
            self?.currentCell?.togglePlayback()
        }
        shortsCell.onDoubleTap = { [weak self] in
            guard let self = self else { return }
            let liked = self.viewModel.toggleLike(video)
            shortsCell.setLiked(liked)
        }
        return cell
    }
}

// MARK: - Collection delegate

extension ShortsViewController: UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return collectionView.bounds.size
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let shortsCell = cell as? ShortsCell else { return }
        if indexPath.item == currentIndex {
            currentCell = shortsCell
            shortsCell.prepareAndPlay()
        } else {
            shortsCell.prepareAndPause()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ShortsCell)?.pause()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleOnVisiblePage()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            settleOnVisiblePage()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        let height = max(collectionView.bounds.height, 1.0)
        let page = Int((scrollView.contentOffset.y / height).rounded())
        guard page != currentIndex, page >= 0, page < viewModel.videos.count else { return }
        currentIndex = page
        viewModel.markCurrent(index: page)
        playCurrent()
    }

    private func settleOnVisiblePage() {
        let height = max(collectionView.bounds.height, 1.0)
        let page = Int((collectionView.contentOffset.y / height).rounded())
        let clamped = min(max(page, 0), max(viewModel.videos.count - 1, 0))
        if clamped != currentIndex {
            currentIndex = clamped
            viewModel.markCurrent(index: clamped)
        }
        playCurrent()
    }
}

// MARK: - Prefetching

extension ShortsViewController: UICollectionViewDataSourcePrefetching {

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let video = viewModel.videos.element(at: indexPath.item) else { continue }
            viewModel.playerItem(for: video) { _ in }
            if !video.thumbnailUrl.isEmpty {
                ImageLoader.shared.prefetch([video.thumbnailUrl])
            }
        }
    }
}

// MARK: - Layout

/// A vertical paging layout whose page is always the collection's bounds. The default flow layout
/// caches item sizes before the collection has bounds, which leaves the first page short on a
/// rotation; this layout recomputes on every bounds change.
final class ShortsFlowLayout: UICollectionViewFlowLayout {

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        return newBounds.size != collectionView?.bounds.size
    }

    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        if let flow = context as? UICollectionViewFlowLayoutInvalidationContext {
            flow.invalidateFlowLayoutDelegateMetrics = true
        }
        return context
    }
}

// MARK: - Cell

/// One page of the reel: the video layer, the tap gestures, the progress state and the right rail.
final class ShortsCell: UICollectionViewCell {

    static let reuseIdentifier = "ShortsCell"

    private let playerContainer = UIView()
    private var playerLayer: AVPlayerLayer?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var video: Video?
    private weak var viewModel: ShortsViewModel?

    private let scrim = UIView()
    private let channelLabel = UILabel()
    private let titleLabel = UILabel()
    private let soundLabel = UILabel()
    private let rail = UIStackView()
    private let likeButton = ShortsActionButton.make(.heart, title: "Like")
    private let dislikeButton = ShortsActionButton.make(.dislike, title: "Dislike")
    private let commentsButton = ShortsActionButton.make(.comment, title: "Comments")
    private let shareButton = ShortsActionButton.make(.share, title: "Share")
    private let saveButton = ShortsActionButton.make(.playlist, title: "Save")
    private let playBadge = FlowIconView.make(.play, color: .white, size: 64.0)
    private let loadingSpinner = UIActivityIndicatorView(style: .whiteLarge)

    /// Reports playback progress, 0...1.
    var onProgress: ((Double) -> Void)?
    /// Called on a single tap.
    var onSingleTap: (() -> Void)?
    /// Called on a double tap.
    var onDoubleTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        tearDownPlayer()
    }

    private func commonInit() {
        backgroundColor = .black
        contentView.backgroundColor = .black

        playerContainer.translatesAutoresizingMaskIntoConstraints = false
        playerContainer.backgroundColor = .black
        contentView.addSubview(playerContainer)

        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        scrim.isUserInteractionEnabled = false
        contentView.addSubview(scrim)

        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.hidesWhenStopped = true
        contentView.addSubview(loadingSpinner)

        playBadge.translatesAutoresizingMaskIntoConstraints = false
        playBadge.isHidden = true
        playBadge.isUserInteractionEnabled = false
        contentView.addSubview(playBadge)

        channelLabel.translatesAutoresizingMaskIntoConstraints = false
        channelLabel.font = FlowTypography.titleSmall
        channelLabel.textColor = .white
        channelLabel.numberOfLines = 1
        contentView.addSubview(channelLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.bodyMedium
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        soundLabel.translatesAutoresizingMaskIntoConstraints = false
        soundLabel.font = FlowTypography.bodySmall
        soundLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        soundLabel.numberOfLines = 1
        contentView.addSubview(soundLabel)

        rail.axis = .vertical
        rail.spacing = FlowSpacing.xl
        rail.alignment = .center
        rail.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rail)
        rail.addArrangedSubview(likeButton)
        rail.addArrangedSubview(dislikeButton)
        rail.addArrangedSubview(commentsButton)
        rail.addArrangedSubview(shareButton)
        rail.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            playerContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            scrim.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            loadingSpinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            playBadge.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            rail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.md),
            rail.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.bottomAnchor, constant: -FlowSpacing.xxl),

            channelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xl),
            channelLabel.trailingAnchor.constraint(equalTo: rail.leadingAnchor, constant: -FlowSpacing.lg),
            channelLabel.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -FlowSpacing.xs),

            titleLabel.leadingAnchor.constraint(equalTo: channelLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: channelLabel.trailingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: soundLabel.topAnchor, constant: -FlowSpacing.sm),

            soundLabel.leadingAnchor.constraint(equalTo: channelLabel.leadingAnchor),
            soundLabel.trailingAnchor.constraint(equalTo: channelLabel.trailingAnchor),
            soundLabel.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.bottomAnchor, constant: -FlowSpacing.xxl),
        ])

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        contentView.addGestureRecognizer(singleTap)
        contentView.addGestureRecognizer(doubleTap)

        likeButton.onTap = { [weak self] in
            guard let self = self, let video = self.video, let model = self.viewModel else { return }
            let liked = model.toggleLike(video)
            self.setLiked(liked)
        }
        dislikeButton.onTap = { [weak self] in
            guard let self = self, let video = self.video, let model = self.viewModel else { return }
            let disliked = model.toggleDislike(video)
            self.setDisliked(disliked)
        }
        commentsButton.onTap = { [weak self] in
            self?.onCommentsTapped?()
        }
        shareButton.onTap = { [weak self] in
            self?.onShareTapped?()
        }
        saveButton.onTap = { [weak self] in
            self?.onSaveTapped?()
        }
        channelLabel.isUserInteractionEnabled = true
        let channelTap = UITapGestureRecognizer(target: self, action: #selector(handleChannelTap))
        channelLabel.addGestureRecognizer(channelTap)
    }

    private var onCommentsTapped: (() -> Void)?
    private var onShareTapped: (() -> Void)?
    private var onSaveTapped: (() -> Void)?
    private var onChannelTapped: (() -> Void)?
    private var onLinkedVideoTapped: (() -> Void)?

    /// Fills the page from a Short.
    func configure(
        with video: Video,
        viewModel: ShortsViewModel,
        onComments: @escaping () -> Void,
        onChannel: @escaping () -> Void,
        onShare: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onLinkedVideo: @escaping () -> Void
    ) {
        self.video = video
        self.viewModel = viewModel
        onCommentsTapped = onComments
        onShareTapped = onShare
        onSaveTapped = onSave
        onChannelTapped = onChannel
        onLinkedVideoTapped = onLinkedVideo

        channelLabel.text = video.channelName
        titleLabel.text = video.title
        soundLabel.text = video.channelName.isEmpty ? nil : "Original Sound - " + video.channelName
        setLiked(viewModel.isLiked(video.id))
        setDisliked(viewModel.isDisliked(video.id))
        setSaved(viewModel.isSaved(video.id))
        accessibilityLabel = video.title
    }

    // MARK: Playback

    /// Resolves the stream and starts playing when it arrives.
    func prepareAndPlay() {
        guard let video = video, let model = viewModel else { return }
        loadingSpinner.startAnimating()
        model.playerItem(for: video) { [weak self] item in
            guard let self = self else { return }
            guard let item = item else {
                self.loadingSpinner.stopAnimating()
                FlowSnackbar.showError("An error occurred")
                return
            }
            self.attach(item: item)
            self.play()
        }
    }

    /// Resolves the stream but leaves it paused, for a page that is about to be shown.
    func prepareAndPause() {
        guard let video = video, let model = viewModel else { return }
        model.playerItem(for: video) { [weak self] item in
            guard let self = self, let item = item else { return }
            self.attach(item: item)
        }
    }

    private func attach(item: AVPlayerItem) {
        tearDownPlayer()
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = playerContainer.bounds
        playerContainer.layer.addSublayer(layer)
        self.player = player
        playerLayer = layer

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if observed.status == .readyToPlay {
                    self.loadingSpinner.stopAnimating()
                } else if observed.status == .failed {
                    self.loadingSpinner.stopAnimating()
                    if let id = self.video?.id {
                        self.viewModel?.invalidateItem(for: id)
                    }
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let player = self.player else { return }
            player.seek(to: .zero)
            player.play()
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, let player = self.player, let item = player.currentItem else { return }
            let duration = CMTimeGetSeconds(item.duration)
            guard duration.isFinite, duration > 0.0 else { return }
            let seconds = CMTimeGetSeconds(time)
            self.onProgress?(seconds / duration)
        }
    }

    private func tearDownPlayer() {
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }

    /// Starts playback.
    func play() {
        player?.play()
        playBadge.isHidden = true
    }

    /// Pauses playback and shows the play mark.
    func pause() {
        player?.pause()
        playBadge.isHidden = (player == nil)
        if let video = video, let player = player, let item = player.currentItem {
            let duration = CMTimeGetSeconds(item.duration)
            let position = CMTimeGetSeconds(player.currentTime())
            if duration.isFinite, duration > 0.0 {
                viewModel?.recordView(video, position: position, duration: duration)
            }
        }
    }

    /// Toggles between playing and paused, for a tap.
    func togglePlayback() {
        guard let player = player else { return }
        if player.rate > 0.0 {
            pause()
        } else {
            play()
        }
    }

    /// Reflects the like state on the rail.
    func setLiked(_ liked: Bool) {
        likeButton.setIcon(liked ? .liked : .heart, tint: liked ? FlowTheme.youtubeRed : .white)
        likeButton.accessibilityValue = liked ? "Liked" : nil
    }

    /// Reflects the dislike state on the rail.
    func setDisliked(_ disliked: Bool) {
        dislikeButton.setIcon(.dislike, tint: disliked ? FlowTheme.youtubeRed : .white)
        dislikeButton.accessibilityValue = disliked ? "Disliked" : nil
    }

    /// Reflects the saved state on the rail.
    func setSaved(_ saved: Bool) {
        saveButton.setIcon(saved ? .check : .playlist, tint: saved ? FlowTheme.youtubeRed : .white)
        saveButton.accessibilityValue = saved ? "Saved" : nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = playerContainer.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tearDownPlayer()
        video = nil
        viewModel = nil
        onProgress = nil
        onSingleTap = nil
        onDoubleTap = nil
        onCommentsTapped = nil
        onShareTapped = nil
        onSaveTapped = nil
        onChannelTapped = nil
        onLinkedVideoTapped = nil
        setLiked(false)
        setDisliked(false)
        setSaved(false)
        playBadge.isHidden = true
        loadingSpinner.stopAnimating()
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap() {
        onDoubleTap?()
    }

    @objc private func handleChannelTap() {
        onChannelTapped?()
    }
}

// MARK: - Rail button

/// One action on the Shorts rail: a white glyph with a label underneath.
final class ShortsActionButton: UIControl {

    private let iconView = FlowIconView()
    private let label = UILabel()

    /// Called when the button is tapped.
    var onTap: (() -> Void)?

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
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.iconColor = .white
        iconView.iconSize = 28.0
        addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FlowTypography.labelSmall
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 56.0),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28.0),
            iconView.heightAnchor.constraint(equalToConstant: 28.0),

            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: FlowSpacing.xxs),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        accessibilityTraits = .button
    }

    /// Creates a rail button.
    static func make(_ icon: FlowIcon, title: String) -> ShortsActionButton {
        let button = ShortsActionButton()
        button.iconView.icon = icon
        button.label.text = title
        button.accessibilityLabel = title
        return button
    }

    /// Changes the glyph and its tint.
    func setIcon(_ icon: FlowIcon, tint: UIColor) {
        iconView.icon = icon
        iconView.iconColor = tint
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1.0 }
    }

    @objc private func handleTap() {
        onTap?()
    }
}

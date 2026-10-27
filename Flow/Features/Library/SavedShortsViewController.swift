import AVFoundation
import UIKit

/// Saved Shorts: a grid of the vertical videos the viewer kept, with a hold-to-preview player.
///
/// The Android screen is a plain adaptive grid. The iOS port keeps the grid and adds the preview the
/// Android card performs on long press: holding a tile opens a muted, looping player over the grid,
/// and letting go closes it. Tapping opens the Short in the Shorts tab; the tile's menu can preview
/// or remove it.
final class SavedShortsViewController: UIViewController {

    /// One saved Short, as the store returns it.
    private struct SavedShort {
        let videoId: String
        let title: String
        let channelName: String
        let thumbnailUrl: String
        let savedAt: Date
    }

    // MARK: - Views

    private let collectionView: UICollectionView
    private let layout = UICollectionViewFlowLayout()
    private let emptyState = FlowEmptyState.make(kind: .custom(
        icon: .shorts,
        title: "No saved shorts yet",
        message: "Shorts you save will appear here."
    ))
    private let preview = ShortsPreviewView()

    // MARK: - State

    private var shorts: [SavedShort] = []
    private var tokens: [ObservationToken] = []
    private var previewWorkItem: DispatchWorkItem?
    private var previewVideoId: String?

    // MARK: - Construction

    init() {
        layout.minimumLineSpacing = FlowSpacing.md
        layout.minimumInteritemSpacing = FlowSpacing.md
        layout.sectionInset = UIEdgeInsets(
            top: FlowSpacing.md,
            left: FlowSpacing.screenMargin,
            bottom: FlowSpacing.xxl,
            right: FlowSpacing.screenMargin
        )
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        layout.minimumLineSpacing = FlowSpacing.md
        layout.minimumInteritemSpacing = FlowSpacing.md
        layout.sectionInset = UIEdgeInsets(
            top: FlowSpacing.md,
            left: FlowSpacing.screenMargin,
            bottom: FlowSpacing.xxl,
            right: FlowSpacing.screenMargin
        )
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(coder: coder)
    }

    deinit {
        previewWorkItem?.cancel()
        for token in tokens {
            token.cancelObservation()
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Saved Shorts"
        view.backgroundColor = FlowTheme.shared.background
        buildViews()
        observeStores()
        applyTheme()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        endPreview()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.layout.invalidateLayout()
        }, completion: nil)
    }

    // MARK: - Build

    private func buildViews() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            SavedShortCell.self,
            forCellWithReuseIdentifier: SavedShortCell.reuseIdentifier
        )
        view.addSubview(collectionView)

        emptyState.isHidden = true
        view.addSubview(emptyState)

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.alpha = 0.0
        preview.isHidden = true
        preview.onClose = { [weak self] in
            self?.endPreview()
        }
        view.addSubview(preview)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        collectionView.addGestureRecognizer(longPress)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.topAnchor.constraint(equalTo: view.topAnchor),
            preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func observeStores() {
        tokens.append(FlowEventBus.shared.on("shorts") { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async { self.reload() }
        })
        tokens.append(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
    }

    // MARK: - Loading

    private func reload() {
        shorts = SavedShortsStore.shared.all().map { entry in
            SavedShort(
                videoId: entry.videoId,
                title: entry.title,
                channelName: entry.channelName,
                thumbnailUrl: entry.thumbnailUrl,
                savedAt: entry.savedAt
            )
        }
        collectionView.reloadData()
        emptyState.isHidden = !shorts.isEmpty
        collectionView.isHidden = shorts.isEmpty
    }

    // MARK: - Theme

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        collectionView.backgroundColor = scheme.background
        emptyState.applyTheme()
        preview.applyTheme()
        for cell in collectionView.visibleCells {
            (cell as? SavedShortCell)?.applyTheme()
        }
    }

    // MARK: - Preview

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: collectionView)
        switch recognizer.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: point),
                  let short = shorts.element(at: indexPath.item) else { return }
            beginPreview(short)
        case .ended, .cancelled, .failed:
            endPreview()
        default:
            break
        }
    }

    /// Shows the preview immediately with the Short's still, then swaps in the stream once it
    /// resolves. A failed lookup closes the preview rather than leaving an empty black panel up.
    private func beginPreview(_ short: SavedShort) {
        guard previewVideoId != short.videoId else { return }
        previewVideoId = short.videoId
        preview.show(
            title: short.title,
            channelName: short.channelName,
            thumbnailUrl: short.thumbnailUrl
        )
        previewWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.previewVideoId == short.videoId else { return }
            FlowApp.shared.youtubeAPI.player(videoId: short.videoId) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self, self.previewVideoId == short.videoId else { return }
                    guard case .success(let player) = result,
                          let item = ShortsViewModel.makeItem(from: player) else {
                        self.endPreview()
                        FlowSnackbar.showError("Couldn't preview this Short.")
                        return
                    }
                    self.preview.play(item: item)
                }
            }
        }
        previewWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func endPreview() {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        previewVideoId = nil
        preview.stop()
    }

    // MARK: - Actions

    private func open(_ short: SavedShort) {
        Router.shared.openWatch(videoId: short.videoId)
    }

    private func presentActions(for short: SavedShort) {
        let actions: [FlowActionSheetContent.Action] = [
            FlowActionSheetContent.Action(title: "Play", icon: .play) { [weak self] in
                self?.open(short)
            },
            FlowActionSheetContent.Action(title: "Preview", icon: .shorts) { [weak self] in
                // Let the sheet finish dismissing so the preview is not revealed underneath it.
                DispatchQueue.main.asyncAfter(deadline: .now() + FlowMotion.emphasized) {
                    self?.beginPreview(short)
                }
            },
            FlowActionSheetContent.Action(
                title: "Remove from Saved Shorts",
                icon: .trash,
                isDestructive: true
            ) {
                // The store deletes on its own queue and broadcasts "shorts" when the row is gone,
                // so the grid reloads from that event rather than racing the write.
                SavedShortsStore.shared.remove(videoId: short.videoId)
                FlowSnackbar.show("Removed from Saved Shorts")
            },
        ]
        LibraryMenu.present(from: self, title: short.title, actions: actions)
    }
}

// MARK: - Grid data

extension SavedShortsViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return shorts.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: SavedShortCell.reuseIdentifier,
            for: indexPath
        )
        guard let tile = cell as? SavedShortCell, let short = shorts.element(at: indexPath.item) else {
            return cell
        }
        tile.configure(
            thumbnailUrl: short.thumbnailUrl,
            title: short.title,
            channelName: short.channelName,
            savedAt: short.savedAt
        )
        tile.onMore = { [weak self] in
            self?.presentActions(for: short)
        }
        tile.applyTheme()
        return tile
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let available = collectionView.bounds.width - FlowSpacing.screenMargin * 2.0
        guard available > 0.0 else {
            return CGSize(width: 160.0, height: 160.0 * 16.0 / 9.0 + 52.0)
        }
        let columns: CGFloat = available > 640.0 ? 4.0 : (available > 420.0 ? 3.0 : 2.0)
        let width = floor((available - FlowSpacing.md * (columns - 1.0)) / columns)
        // Shorts are 9:16, with the title and channel lines underneath.
        return CGSize(width: width, height: width * 16.0 / 9.0 + 52.0)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let short = shorts.element(at: indexPath.item) else { return }
        open(short)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? SavedShortCell)?.applyTheme()
    }
}

// MARK: - Tile

/// One saved Short: the vertical still, its title and channel, and a menu button.
final class SavedShortCell: UICollectionViewCell {

    static let reuseIdentifier = "SavedShortCell"

    private let thumbnail = AsyncImageView.make(cornerRadius: FlowShapes.medium)
    private let titleLabel = UILabel()
    private let channelLabel = UILabel()
    private let moreButton = FlowIconButton()
    private let playGlyph = FlowIconView()

    /// Called when the tile's menu button is tapped.
    var onMore: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        contentView.backgroundColor = .clear

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(thumbnail)

        playGlyph.translatesAutoresizingMaskIntoConstraints = false
        playGlyph.icon = .play
        playGlyph.iconSize = 28.0
        playGlyph.isUserInteractionEnabled = false
        contentView.addSubview(playGlyph)

        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.configure(icon: .more, color: .white, size: 18.0)
        moreButton.addTarget(self, action: #selector(handleMore), for: .touchUpInside)
        moreButton.accessibilityLabel = "Short actions"
        contentView.addSubview(moreButton)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.bodySmallEmphasized
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        channelLabel.translatesAutoresizingMaskIntoConstraints = false
        channelLabel.font = FlowTypography.labelSmall
        channelLabel.numberOfLines = 1
        contentView.addSubview(channelLabel)

        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbnail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            thumbnail.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor, multiplier: 16.0 / 9.0),

            playGlyph.centerXAnchor.constraint(equalTo: thumbnail.centerXAnchor),
            playGlyph.centerYAnchor.constraint(equalTo: thumbnail.centerYAnchor),
            playGlyph.widthAnchor.constraint(equalToConstant: 28.0),
            playGlyph.heightAnchor.constraint(equalToConstant: 28.0),

            moreButton.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: -FlowSpacing.xxs),
            moreButton.topAnchor.constraint(equalTo: thumbnail.topAnchor, constant: FlowSpacing.xxs),
            moreButton.widthAnchor.constraint(equalToConstant: 44.0),
            moreButton.heightAnchor.constraint(equalToConstant: 44.0),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: FlowSpacing.xs),

            channelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            channelLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            channelLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),
        ])
        applyTheme()
    }

    /// Sets the tile's content.
    func configure(thumbnailUrl: String, title: String, channelName: String, savedAt: Date) {
        thumbnail.setImage(url: thumbnailUrl, targetSize: CGSize(width: 360.0, height: 640.0))
        titleLabel.text = title
        var parts: [String] = []
        if !channelName.isEmpty {
            parts.append(channelName)
        }
        parts.append(Formatters.relativeDate(savedAt))
        channelLabel.text = parts.joined(separator: " · ")
        accessibilityLabel = "\(title), \(channelLabel.text ?? "")"
        accessibilityHint = "Hold to preview"
    }

    /// Repaints the tile in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        thumbnail.placeholderColor = scheme.surfaceContainerHighest
        thumbnail.applyTheme()
        titleLabel.textColor = scheme.onSurface
        channelLabel.textColor = scheme.onSurfaceVariant
        playGlyph.iconColor = UIColor.white.withAlphaComponent(0.9)
        moreButton.setIconColor(.white)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.clearImage()
        titleLabel.text = nil
        channelLabel.text = nil
        onMore = nil
    }

    @objc private func handleMore() {
        onMore?()
    }
}

// MARK: - Preview overlay

/// The hold-to-preview surface: a dimmed backdrop, the Short playing muted and looping, and its
/// title. It owns its own `AVPlayer` so the main playback queue is never disturbed.
final class ShortsPreviewView: UIView {

    private let backdrop = UIView()
    private let playerContainer = UIView()
    private let still = AsyncImageView.make()
    private let spinner = UIActivityIndicatorView(style: .white)
    private let titleLabel = UILabel()
    private let channelLabel = UILabel()
    private let closeButton = FlowIconButton()

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var endObserver: NSObjectProtocol?

    /// Called when the viewer taps the backdrop or the close button.
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        releasePlayer()
    }

    private func commonInit() {
        isHidden = true
        backgroundColor = .clear

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        addSubview(backdrop)
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))

        playerContainer.translatesAutoresizingMaskIntoConstraints = false
        playerContainer.backgroundColor = .black
        playerContainer.layer.cornerRadius = FlowShapes.medium
        playerContainer.layer.masksToBounds = true
        addSubview(playerContainer)

        still.translatesAutoresizingMaskIntoConstraints = false
        still.contentMode = .scaleAspectFill
        playerContainer.addSubview(still)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        playerContainer.addSubview(spinner)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleMediumEmphasized
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        addSubview(titleLabel)

        channelLabel.translatesAutoresizingMaskIntoConstraints = false
        channelLabel.font = FlowTypography.bodySmall
        channelLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        channelLabel.numberOfLines = 1
        addSubview(channelLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.configure(icon: .close, color: .white, size: 22.0)
        closeButton.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        closeButton.accessibilityLabel = "Close preview"
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            playerContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            playerContainer.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -FlowSpacing.xxl),
            playerContainer.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.62),
            playerContainer.heightAnchor.constraint(equalTo: playerContainer.widthAnchor, multiplier: 16.0 / 9.0),

            still.leadingAnchor.constraint(equalTo: playerContainer.leadingAnchor),
            still.trailingAnchor.constraint(equalTo: playerContainer.trailingAnchor),
            still.topAnchor.constraint(equalTo: playerContainer.topAnchor),
            still.bottomAnchor.constraint(equalTo: playerContainer.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: playerContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: playerContainer.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.md),
            closeButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: FlowSpacing.md),
            closeButton.widthAnchor.constraint(equalToConstant: 44.0),
            closeButton.heightAnchor.constraint(equalToConstant: 44.0),

            titleLabel.leadingAnchor.constraint(equalTo: playerContainer.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: playerContainer.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: playerContainer.bottomAnchor, constant: FlowSpacing.lg),

            channelLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            channelLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            channelLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),
        ])
        applyTheme()
    }

    /// Shows the preview with the Short's still, before the stream has resolved.
    func show(title: String, channelName: String, thumbnailUrl: String) {
        releasePlayer()
        titleLabel.text = title
        channelLabel.text = channelName
        still.setImage(url: thumbnailUrl, targetSize: CGSize(width: 360.0, height: 640.0))
        still.isHidden = false
        spinner.startAnimating()
        isHidden = false
        FlowMotion.animate {
            self.alpha = 1.0
        }
    }

    /// Starts playing a resolved item, muted and looping, over the still.
    func play(item: AVPlayerItem) {
        releasePlayer()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = playerContainer.bounds
        playerContainer.layer.insertSublayer(layer, below: still.layer)
        self.player = player
        playerLayer = layer
        still.isHidden = true
        spinner.stopAnimating()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero)
            self?.player?.play()
        }
        player.play()
    }

    /// Fades the preview out and releases its player. A preview that is shown again mid-fade
    /// cancels the animation; the completion then leaves the new preview alone.
    func stop() {
        guard !isHidden else { return }
        FlowMotion.animate({
            self.alpha = 0.0
        }, completion: { _ in
            guard self.alpha == 0.0 else { return }
            self.isHidden = true
            self.releasePlayer()
            self.still.clearImage()
            self.titleLabel.text = nil
            self.channelLabel.text = nil
        })
    }

    /// Repaints the preview in the current palette. The player itself stays black in every theme.
    func applyTheme() {
        still.applyTheme()
        titleLabel.textColor = .white
        channelLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        closeButton.setIconColor(.white)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = playerContainer.bounds
    }

    private func releasePlayer() {
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        endObserver = nil
        player?.pause()
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        spinner.stopAnimating()
    }

    @objc private func handleTap() {
        onClose?()
    }
}

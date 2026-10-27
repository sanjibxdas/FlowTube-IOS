import UIKit

/// The watch page: the player at the top, then the video's title and channel, the action row, the
/// description with its chapters, a comments preview and the related videos.
///
/// The player itself is `VideoPlayerViewController` from the playback layer, embedded as a child so
/// the watch page owns the metadata below it while the playback service owns the picture. That split
/// is what lets the mini player keep playing after the viewer leaves.
final class WatchViewController: UIViewController {

    // MARK: - Navigation

    /// Called when the viewer picks another video. When nothing is wired, the screen pushes a new
    /// watch page onto its own navigation stack, which is what the Android screen does.
    var onOpenVideo: ((Video) -> Void)?
    /// Called with the channel id the viewer picked.
    var onOpenChannel: ((String) -> Void)?
    /// Called when the viewer leaves the watch page.
    var onClose: (() -> Void)?

    // MARK: - State

    private let videoId: String
    private let api: YouTubeAPI
    private let service: PlaybackService

    private let playerContainer = UIView()
    private let playerErrorLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")

    private var playerController: VideoPlayerViewController?
    private var model: WatchPageModel?
    private var video: Video?
    private var rows: [WatchRow] = []
    private var isDescriptionExpanded = false
    private var isLoading = false
    private var loadToken = 0
    private var bag = ObservationBag()
    private var themeToken: ObservationToken?

    /// The first comment and the section's total, fetched once for the preview.
    private var commentPreview: Comment?
    private var commentTotalText: String?
    private var isLoadingCommentPreview = false

    // MARK: - Player layout

    /// The player at its 16:9 size.
    private var expandedPlayerHeight: NSLayoutConstraint!
    /// The player shrunk to the mini-player pin.
    private var compactPlayerHeight: NSLayoutConstraint!
    /// The player covering the screen while the viewer is in full screen.
    private var fullscreenPlayerConstraints: [NSLayoutConstraint] = []
    /// Whether the player is currently pinned small.
    private var isPlayerCollapsed = false
    /// Whether the player is covering the screen because the viewer went full screen.
    private var isPlayerFullscreen = false
    /// A tap target over the shrunken player, so a tap expands it instead of reaching the controls.
    private let collapsedTapTarget = UIControl()
    /// Watches the player's full-screen flag while the page is on screen.
    private var fullscreenPollTimer: Timer?

    /// How far the page scrolls before the player shrinks, and how far back it must come before it
    /// grows again. The gap keeps the pin from flickering at the threshold.
    private static let collapseThreshold: CGFloat = 96.0
    private static let expandThreshold: CGFloat = 32.0
    /// The height of the pinned player, matching the shell's mini player bar.
    private static let compactPlayerHeightValue: CGFloat = 64.0

    /// One row of the page below the player.
    private enum WatchRow {
        case info
        case channel
        case actions
        case description
        case comments
        case relatedHeader
        case related(Video)
    }

    // MARK: - Construction

    init(
        videoId: String,
        api: YouTubeAPI = YouTubeAPI(),
        service: PlaybackService = .shared
    ) {
        self.videoId = videoId
        self.api = api
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        videoId = ""
        api = YouTubeAPI()
        service = .shared
        super.init(coder: coder)
    }

    deinit {
        fullscreenPollTimer?.invalidate()
        themeToken?.cancelObservation()
        bag.cancelAll()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildPlayer()
        buildTable()
        buildOverlays()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        bag.add(FlowEventBus.shared.on("playlists") { [weak self] _ in
            DispatchQueue.main.async {
                self?.reloadActionsRow()
            }
        })
        bag.add(FlowEventBus.shared.on("downloads") { [weak self] _ in
            DispatchQueue.main.async {
                self?.reloadActionsRow()
            }
        })
        bag.add(FlowEventBus.shared.on("subscriptions") { [weak self] _ in
            DispatchQueue.main.async {
                self?.reloadChannelRow()
            }
        })
        applyTheme()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        reloadActionsRow()
        reloadChannelRow()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    /// The player draws the status bar's colour and hides it with its chrome, so the page asks the
    /// child rather than answering for it.
    override var childForStatusBarStyle: UIViewController? {
        return playerController
    }

    override var childForStatusBarHidden: UIViewController? {
        return playerController
    }

    /// The page's own orientation is the player's: portrait while inline, free while full screen.
    /// iPhone's Info.plist lists only portrait, so the player's full-screen button rotates the
    /// device through `UIDevice` and this mask is what lets the rotation stick.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if playerController?.isFullscreen == true {
            return .allButUpsideDown
        }
        return UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    override var shouldAutorotate: Bool {
        return true
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.reconcilePlayerPresentation()
            self?.view.layoutIfNeeded()
        }, completion: nil)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // The player toggles full screen from its own controls without telling the page, so the
        // page reconciles the container against the player's state on every layout pass. The
        // compare-and-return inside keeps this from re-entering.
        reconcilePlayerPresentation()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startFullscreenPolling()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopFullscreenPolling()
    }

    // MARK: - Full-screen observation

    /// The player toggles full screen from its own chrome and tells nobody, and the layout pass
    /// that usually follows a rotation is not guaranteed — a viewer with orientation lock on can
    /// press the button and stay upright. The page therefore watches the flag while it is on
    /// screen, at a cadence slow enough to cost nothing and fast enough to feel immediate.
    private func startFullscreenPolling() {
        stopFullscreenPolling()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.reconcilePlayerPresentation()
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenPollTimer = timer
    }

    private func stopFullscreenPolling() {
        fullscreenPollTimer?.invalidate()
        fullscreenPollTimer = nil
    }

    // MARK: - Build

    private func buildPlayer() {
        playerContainer.translatesAutoresizingMaskIntoConstraints = false
        playerContainer.backgroundColor = .black
        view.addSubview(playerContainer)

        playerErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        playerErrorLabel.font = FlowTypography.bodyMedium
        playerErrorLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        playerErrorLabel.textAlignment = .center
        playerErrorLabel.numberOfLines = 4
        playerErrorLabel.isHidden = true

        let controller = VideoPlayerViewController(videoId: videoId, service: service)
        controller.onBack = { [weak self] in self?.handleBack() }
        controller.onOpenDetails = { [weak self] in self?.scrollToDescription() }
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        playerContainer.addSubview(controller.view)
        controller.didMove(toParent: self)
        playerController = controller

        // Above the player, so an unplayable video's reason is not covered by the black surface.
        playerContainer.addSubview(playerErrorLabel)

        // The player's own back button leaves the page; the page's collapse gesture and full
        // screen are the player's, so the shell only watches the size it should be.
        collapsedTapTarget.translatesAutoresizingMaskIntoConstraints = false
        collapsedTapTarget.backgroundColor = .clear
        collapsedTapTarget.isHidden = true
        collapsedTapTarget.addTarget(self, action: #selector(handleCollapsedTap), for: .touchUpInside)
        collapsedTapTarget.accessibilityLabel = "Expand video"
        collapsedTapTarget.accessibilityTraits = .button
        playerContainer.addSubview(collapsedTapTarget)

        expandedPlayerHeight = playerContainer.heightAnchor.constraint(
            equalTo: view.widthAnchor,
            multiplier: 9.0 / 16.0
        )
        compactPlayerHeight = playerContainer.heightAnchor.constraint(
            equalToConstant: WatchViewController.compactPlayerHeightValue
        )
        fullscreenPlayerConstraints = [
            playerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerContainer.topAnchor.constraint(equalTo: view.topAnchor),
            playerContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]

        NSLayoutConstraint.activate([
            playerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerContainer.topAnchor.constraint(equalTo: view.topAnchor),
            expandedPlayerHeight,

            controller.view.leadingAnchor.constraint(equalTo: playerContainer.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: playerContainer.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: playerContainer.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: playerContainer.bottomAnchor),

            collapsedTapTarget.leadingAnchor.constraint(equalTo: playerContainer.leadingAnchor),
            collapsedTapTarget.trailingAnchor.constraint(equalTo: playerContainer.trailingAnchor),
            collapsedTapTarget.topAnchor.constraint(equalTo: playerContainer.topAnchor),
            collapsedTapTarget.bottomAnchor.constraint(equalTo: playerContainer.bottomAnchor),

            playerErrorLabel.centerXAnchor.constraint(equalTo: playerContainer.centerXAnchor),
            playerErrorLabel.centerYAnchor.constraint(equalTo: playerContainer.centerYAnchor),
            playerErrorLabel.leadingAnchor.constraint(equalTo: playerContainer.leadingAnchor, constant: FlowSpacing.xxl),
            playerErrorLabel.trailingAnchor.constraint(equalTo: playerContainer.trailingAnchor, constant: -FlowSpacing.xxl),
        ])
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 96.0
        tableView.rowHeight = UITableView.automaticDimension
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.register(WatchInfoCell.self, forCellReuseIdentifier: WatchInfoCell.reuseIdentifier)
        tableView.register(WatchChannelCell.self, forCellReuseIdentifier: WatchChannelCell.reuseIdentifier)
        tableView.register(WatchActionsCell.self, forCellReuseIdentifier: WatchActionsCell.reuseIdentifier)
        tableView.register(WatchDescriptionCell.self, forCellReuseIdentifier: WatchDescriptionCell.reuseIdentifier)
        tableView.register(WatchCommentsPreviewCell.self, forCellReuseIdentifier: WatchCommentsPreviewCell.reuseIdentifier)
        tableView.register(WatchSectionHeaderCell.self, forCellReuseIdentifier: WatchSectionHeaderCell.reuseIdentifier)
        tableView.register(WatchRelatedCell.self, forCellReuseIdentifier: WatchRelatedCell.reuseIdentifier)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: playerContainer.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildOverlays() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        errorState.translatesAutoresizingMaskIntoConstraints = false
        errorState.isHidden = true
        errorState.onAction = { [weak self] in self?.load() }
        view.addSubview(errorState)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),

            errorState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorState.topAnchor.constraint(equalTo: playerContainer.bottomAnchor),
            errorState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Player presentation

    /// Matches the container to the player's own state: full screen when the player says so,
    /// otherwise the inline 16:9 box or its pinned size.
    private func reconcilePlayerPresentation() {
        let wantsFullscreen = playerController?.isFullscreen ?? false
        if wantsFullscreen != isPlayerFullscreen {
            setPlayerFullscreen(wantsFullscreen)
        }
        guard !isPlayerFullscreen else { return }
        if isPlayerCollapsed {
            expandedPlayerHeight.isActive = false
            compactPlayerHeight.isActive = true
        } else {
            compactPlayerHeight.isActive = false
            expandedPlayerHeight.isActive = true
        }
    }

    /// Lifts the player over the whole page, or puts it back in its box.
    private func setPlayerFullscreen(_ fullscreen: Bool) {
        isPlayerFullscreen = fullscreen
        if fullscreen {
            expandedPlayerHeight.isActive = false
            compactPlayerHeight.isActive = false
            NSLayoutConstraint.activate(fullscreenPlayerConstraints)
            view.bringSubviewToFront(playerContainer)
            tableView.isHidden = true
            collapsedTapTarget.isHidden = true
            setNeedsStatusBarAppearanceUpdate()
            return
        }
        NSLayoutConstraint.deactivate(fullscreenPlayerConstraints)
        // Not simply `false`: a page that failed to load keeps its error state instead of
        // uncovering the empty table underneath it.
        updateEmptyState()
        collapsedTapTarget.isHidden = !isPlayerCollapsed
        reconcilePlayerPresentation()
        setNeedsStatusBarAppearanceUpdate()
    }

    /// Shrinks the player to the pin, or grows it back.
    private func setPlayerCollapsed(_ collapsed: Bool, animated: Bool) {
        guard collapsed != isPlayerCollapsed, !isPlayerFullscreen else { return }
        isPlayerCollapsed = collapsed
        collapsedTapTarget.isHidden = !collapsed
        if collapsed {
            expandedPlayerHeight.isActive = false
            compactPlayerHeight.isActive = true
        } else {
            compactPlayerHeight.isActive = false
            expandedPlayerHeight.isActive = true
        }
        guard animated else {
            view.layoutIfNeeded()
            return
        }
        FlowMotion.animate({
            self.view.layoutIfNeeded()
        }, completion: nil)
    }

    @objc private func handleCollapsedTap() {
        setPlayerCollapsed(false, animated: true)
        tableView.setContentOffset(.zero, animated: true)
    }

    /// Follows the page's scroll: past the threshold the player pins, back near the top it returns.
    private func updatePlayerCollapse(for offset: CGFloat) {
        guard !isPlayerFullscreen else { return }
        if !isPlayerCollapsed && offset > WatchViewController.collapseThreshold {
            setPlayerCollapsed(true, animated: true)
        } else if isPlayerCollapsed && offset < WatchViewController.expandThreshold {
            setPlayerCollapsed(false, animated: true)
        }
    }

    // MARK: - Loading

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        loadToken += 1
        let token = loadToken
        errorState.isHidden = true
        // A retry starts clean: the previous attempt's preview belongs to a page that never loaded.
        commentPreview = nil
        commentTotalText = nil
        isLoadingCommentPreview = false
        spinner.startAnimating()

        WatchPageService.shared.load(videoId: videoId) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard token == self.loadToken else { return }
                self.isLoading = false
                self.spinner.stopAnimating()
                switch result {
                case .success(let model):
                    self.apply(model: model)
                case .failure(let error):
                    self.showError(error)
                }
            }
        }
    }

    private func apply(model: WatchPageModel) {
        self.model = model
        let page = model.page
        var video = page.video
        // DeArrow's title and thumbnail replace YouTube's on the page, so the metadata below the
        // player matches the picture the viewer is looking at.
        if !model.title.isEmpty { video.title = model.title }
        if !model.thumbnailUrl.isEmpty { video.thumbnailUrl = model.thumbnailUrl }
        self.video = video

        playerErrorLabel.isHidden = page.isPlayable
        if !page.isPlayable {
            playerErrorLabel.text = page.playabilityReason ?? "This video can't be played right now."
        }

        rebuildRows()
        tableView.reloadData()
        updateEmptyState()
        loadCommentPreview(continuation: page.commentsContinuation)
    }

    /// Fetches the first comment for the preview card.
    ///
    /// The preview is a courtesy, so a failure leaves the card saying "Add a comment..." rather
    /// than showing an error on a page that otherwise loaded. The first page is also what the full
    /// comments screen will ask for, so `ImageLoader` and the network cache make the second request
    /// cheap.
    private func loadCommentPreview(continuation: String?) {
        guard let token = continuation, !token.isEmpty, !isLoadingCommentPreview else {
            return
        }
        isLoadingCommentPreview = true
        api.comments(videoId: videoId, continuation: token) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoadingCommentPreview = false
                guard case .success(let page) = result else { return }
                self.commentPreview = page.comments.first
                self.commentTotalText = page.totalText
                self.reloadCommentsRow()
            }
        }
    }

    private func reloadCommentsRow() {
        guard let index = rows.firstIndex(where: { row in
            if case .comments = row { return true }
            return false
        }) else { return }
        tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
    }

    private func showError(_ error: FlowError) {
        rows = []
        tableView.reloadData()
        tableView.isHidden = true
        errorState.isHidden = false
        errorState.configure(
            kind: .custom(icon: .wifi, title: "Couldn't load this video", message: error.displayMessage),
            actionTitle: "Retry"
        )
        errorState.applyTheme()
    }

    /// The table is shown only when it has rows to show and the page is not in its error state.
    /// While the first load is in flight the table stays visible but empty, so the spinner has a
    /// background and the player is not the only thing on screen.
    private func updateEmptyState() {
        let empty = rows.isEmpty && !isLoading
        tableView.isHidden = empty || !errorState.isHidden
    }

    private func rebuildRows() {
        guard let model = model else {
            rows = []
            return
        }
        var result: [WatchRow] = [.info, .channel, .actions, .description]
        // The preview is the way into the comment section, so it is shown even when the page sent
        // no continuation: the full screen then explains that comments are off.
        result.append(.comments)
        if !model.page.related.isEmpty {
            result.append(.relatedHeader)
            for video in model.page.related {
                result.append(.related(video))
            }
        }
        rows = result
    }

    private func reloadActionsRow() {
        guard let index = rows.firstIndex(where: { row in
            if case .actions = row { return true }
            return false
        }) else { return }
        tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
    }

    private func reloadChannelRow() {
        guard let index = rows.firstIndex(where: { row in
            if case .channel = row { return true }
            return false
        }) else { return }
        tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
    }

    // MARK: - Actions

    private func handleBack() {
        if let close = onClose {
            close()
            return
        }
        if let navigation = navigationController, navigation.viewControllers.first !== self {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true, completion: nil)
        }
    }

    private func open(video: Video) {
        if let handler = onOpenVideo {
            handler(video)
            return
        }
        let controller = WatchViewController(videoId: video.id, api: api, service: service)
        push(controller)
    }

    private func openChannel(_ channelId: String) {
        guard !channelId.isEmpty else { return }
        if let handler = onOpenChannel {
            handler(channelId)
            return
        }
        push(ChannelViewController(channelId: channelId, api: api))
    }

    /// Pushes onto the page's own stack, or — when the page was presented on its own, which is how
    /// the router opens a watch link — onto a stack of its own so the destination still has a back
    /// button.
    private func push(_ controller: UIViewController) {
        if let navigation = navigationController {
            navigation.pushViewController(controller, animated: true)
            return
        }
        Router.shared.push(controller, from: self)
    }

    private func openComments() {
        guard let model = model else { return }
        let controller = CommentsViewController(
            videoId: videoId,
            continuation: model.page.commentsContinuation,
            api: api
        )
        controller.onOpenChannel = { [weak self] channelId in
            self?.openChannel(channelId)
        }
        controller.onSeek = { [weak self] seconds in
            self?.seek(to: seconds)
        }
        // `onClose` is left unset: the comments screen pops its own stack, or dismisses the stack
        // the router wrapped it in, which covers both ways this page can be reached.
        push(controller)
    }

    private func toggleDescription() {
        isDescriptionExpanded.toggle()
        guard let index = rows.firstIndex(where: { row in
            if case .description = row { return true }
            return false
        }) else { return }
        tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .automatic)
    }

    /// Brings the description into view, opening it first: the title's "Show more" promises the
    /// full text, not just the collapsed card.
    private func scrollToDescription() {
        guard let index = rows.firstIndex(where: { row in
            if case .description = row { return true }
            return false
        }) else { return }
        if !isDescriptionExpanded {
            isDescriptionExpanded = true
            tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
        }
        tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .top, animated: true)
    }

    private func seek(to seconds: TimeInterval) {
        service.seek(to: seconds)
        service.play()
    }

    /// Opens a link the description printed.
    ///
    /// A YouTube link is routed inside the app so the viewer stays in Flow; anything else is handed
    /// to the system, which is the only thing that can show a web page.
    private func openLink(_ url: URL) {
        if let route = DeepLink.parse(url) {
            Router.shared.open(route)
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func share() {
        guard let video = video else { return }
        let text = video.title + "\nhttps://youtu.be/" + video.id
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

    private func copyLink() {
        UIPasteboard.general.string = "https://youtu.be/" + videoId
        FlowSnackbar.show("Link copied")
    }

    private func presentSaveSheet() {
        guard let video = video else { return }
        let playlists = PlaylistStore.shared.allPlaylists()
        var actions: [FlowActionSheetContent.Action] = playlists.map { playlist in
            let contains = PlaylistStore.shared.contains(videoId: video.id, in: playlist.playlistId)
            return FlowActionSheetContent.Action(
                title: playlist.title,
                icon: contains ? .check : .playlist
            ) { [weak self] in
                guard let self = self else { return }
                if contains {
                    PlaylistStore.shared.removeVideo(videoId: video.id, from: playlist.playlistId)
                    FlowSnackbar.show("Removed from " + playlist.title)
                } else {
                    PlaylistStore.shared.addVideo(
                        videoId: video.id,
                        title: video.title,
                        channelName: video.channelName,
                        thumbnailUrl: video.thumbnailUrl,
                        duration: TimeInterval(video.duration),
                        to: playlist.playlistId
                    )
                    FlowSnackbar.show("Saved to " + playlist.title)
                }
                self.reloadActionsRow()
            }
        }
        actions.append(FlowActionSheetContent.Action(title: "New playlist", icon: .add) { [weak self] in
            self?.presentNewPlaylistAlert()
        })
        actions.append(FlowActionSheetContent.Action(title: "Copy link", icon: .share) { [weak self] in
            self?.copyLink()
        })

        let content = FlowActionSheetContent(actions: actions)
        let sheet = FlowSheet(content: content, title: "Save to playlist", detent: .medium)
        content.onActionSelected = { [weak sheet] in sheet?.dismissSheet() }
        sheet.present(from: self)
    }

    private func presentNewPlaylistAlert() {
        guard let video = video else { return }
        let alert = UIAlertController(title: "New playlist", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Playlist name"
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Create", style: .default, handler: { [weak self, weak alert] _ in
            guard let self = self else { return }
            let title = (alert?.textFields?.first?.text ?? "").trimmed
            guard !title.isEmpty else {
                FlowSnackbar.showError("Give the playlist a name first")
                return
            }
            let playlistId = PlaylistStore.shared.createPlaylist(title: title)
            PlaylistStore.shared.addVideo(
                videoId: video.id,
                title: video.title,
                channelName: video.channelName,
                thumbnailUrl: video.thumbnailUrl,
                duration: TimeInterval(video.duration),
                to: playlistId
            )
            FlowSnackbar.show("Saved to " + title)
            self.reloadActionsRow()
        }))
        present(alert, animated: true, completion: nil)
    }

    private func download() {
        guard let video = video else { return }
        if DownloadStore.shared.isDownloaded(videoId: video.id) {
            FlowSnackbar.show("This video is already downloaded")
            return
        }
        DownloadStore.shared.enqueue(
            videoId: video.id,
            title: video.title,
            channelName: video.channelName,
            thumbnailUrl: video.thumbnailUrl,
            quality: PrefsStore.shared.string(for: .downloadQuality) ?? "720p",
            duration: TimeInterval(video.duration),
            isMusic: video.isMusic
        )
        FlowSnackbar.show("Download queued")
        reloadActionsRow()
    }

    private func toggleSubscription() {
        guard let video = video else { return }
        let channelName = video.channelName
        let avatar = video.channelThumbnailUrl
        // The watch page carries no subscriber figure of its own, so an existing subscription's
        // count is kept rather than overwritten with a guess.
        let existing = SubscriptionStore.shared.subscription(for: video.channelId)?.subscriberCount ?? 0
        let nowSubscribed = SubscriptionStore.shared.toggle(
            channelId: video.channelId,
            name: channelName,
            avatarUrl: avatar,
            subscriberCount: existing
        )
        if nowSubscribed {
            FlowSnackbar.show("Subscribed to " + channelName, actionTitle: "Undo") { [weak self] in
                SubscriptionStore.shared.unsubscribe(channelId: video.channelId)
                self?.reloadChannelRow()
            }
        } else {
            FlowSnackbar.show("Unsubscribed from " + channelName)
        }
        reloadChannelRow()
    }

    private func toggleLike() {
        let liked = WatchReactions.toggleLike(videoId)
        if liked {
            WatchReactions.clearDislike(videoId)
        }
        reloadActionsRow()
    }

    private func toggleDislike() {
        let disliked = WatchReactions.toggleDislike(videoId)
        if disliked {
            WatchReactions.clearLike(videoId)
        }
        reloadActionsRow()
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        tableView.reloadData()
        errorState.applyTheme()
    }
}

// MARK: - Data source

extension WatchViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let row = rows.element(at: indexPath.row) else { return UITableViewCell() }
        switch row {
        case .info:
            let cell = tableView.dequeueReusableCell(withIdentifier: WatchInfoCell.reuseIdentifier, for: indexPath)
            if let infoCell = cell as? WatchInfoCell, let video = video, let model = model {
                infoCell.configure(
                    title: video.title,
                    viewCount: model.page.video.viewCount,
                    uploadDate: model.page.video.uploadDate,
                    isUpcoming: model.page.isUpcoming,
                    membersOnly: model.page.video.membersOnlyText
                )
                infoCell.onOpenDescription = { [weak self] in self?.scrollToDescription() }
            }
            return cell

        case .channel:
            let cell = tableView.dequeueReusableCell(withIdentifier: WatchChannelCell.reuseIdentifier, for: indexPath)
            if let channelCell = cell as? WatchChannelCell, let video = video {
                // `WatchPage` keeps only the video from the owner block, so the subscriber line
                // comes from the local subscription when there is one. Without it the row shows
                // the name alone rather than a figure the page does not have.
                let subscribed = SubscriptionStore.shared.subscription(for: video.channelId)
                let subscriberText = subscribed.map { Formatters.subscriberCount($0.subscriberCount) } ?? ""
                let channel = Channel(
                    id: video.channelId,
                    name: video.channelName,
                    thumbnailUrl: video.channelThumbnailUrl,
                    subscriberCount: Int64(subscribed?.subscriberCount ?? 0),
                    subscriberCountText: subscriberText
                )
                channelCell.configure(
                    channel: channel,
                    isSubscribed: SubscriptionStore.shared.isSubscribed(video.channelId)
                )
                channelCell.onOpenChannel = { [weak self] in self?.openChannel(video.channelId) }
                channelCell.onToggleSubscription = { [weak self] in self?.toggleSubscription() }
            }
            return cell

        case .actions:
            let cell = tableView.dequeueReusableCell(withIdentifier: WatchActionsCell.reuseIdentifier, for: indexPath)
            if let actionsCell = cell as? WatchActionsCell, let model = model {
                let likeCount = model.page.likeCount + (WatchReactions.isLiked(videoId) ? 1 : 0)
                actionsCell.configure(
                    likeCount: likeCount,
                    dislikeCount: model.dislikeCounts?.dislikeCount ?? 0,
                    isLiked: WatchReactions.isLiked(videoId),
                    isDisliked: WatchReactions.isDisliked(videoId),
                    isSaved: !PlaylistStore.shared.playlistsContaining(videoId: videoId).isEmpty,
                    isDownloaded: DownloadStore.shared.isDownloaded(videoId: videoId)
                )
                actionsCell.onLike = { [weak self] in self?.toggleLike() }
                actionsCell.onDislike = { [weak self] in self?.toggleDislike() }
                actionsCell.onShare = { [weak self] in self?.share() }
                actionsCell.onSave = { [weak self] in self?.presentSaveSheet() }
                actionsCell.onDownload = { [weak self] in self?.download() }
            }
            return cell

        case .description:
            let cell = tableView.dequeueReusableCell(withIdentifier: WatchDescriptionCell.reuseIdentifier, for: indexPath)
            if let descriptionCell = cell as? WatchDescriptionCell, let model = model, let video = video {
                descriptionCell.configure(
                    description: video.description.isEmpty ? model.page.video.description : video.description,
                    chapters: model.page.chapters,
                    isExpanded: isDescriptionExpanded
                )
                descriptionCell.onToggle = { [weak self] in self?.toggleDescription() }
                descriptionCell.onChapter = { [weak self] chapter in self?.seek(to: chapter.startTime) }
                descriptionCell.onSeek = { [weak self] seconds in self?.seek(to: seconds) }
                descriptionCell.onLink = { [weak self] url in self?.openLink(url) }
            }
            return cell

        case .comments:
            let cell = tableView.dequeueReusableCell(withIdentifier: WatchCommentsPreviewCell.reuseIdentifier, for: indexPath)
            if let commentsCell = cell as? WatchCommentsPreviewCell {
                commentsCell.configure(totalText: commentTotalText, preview: commentPreview)
                commentsCell.onOpen = { [weak self] in self?.openComments() }
            }
            return cell

        case .relatedHeader:
            let cell = tableView.dequeueReusableCell(withIdentifier: WatchSectionHeaderCell.reuseIdentifier, for: indexPath)
            if let headerCell = cell as? WatchSectionHeaderCell {
                headerCell.configure(title: "Related Videos")
            }
            return cell

        case .related(let related):
            let cell = tableView.dequeueReusableCell(withIdentifier: WatchRelatedCell.reuseIdentifier, for: indexPath)
            if let relatedCell = cell as? WatchRelatedCell {
                relatedCell.configure(with: related)
            }
            return cell
        }
    }

}

// MARK: - Delegate

extension WatchViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = rows.element(at: indexPath.row) else { return }
        switch row {
        case .related(let video):
            open(video: video)
        case .comments:
            openComments()
        default:
            break
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    /// Pins the player once the viewer has scrolled past the metadata, and restores it at the top.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        updatePlayerCollapse(for: scrollView.contentOffset.y)
    }
}

// MARK: - Prefetching

extension WatchViewController: UITableViewDataSourcePrefetching {

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        var urls: [String] = []
        for indexPath in indexPaths {
            guard let row = rows.element(at: indexPath.row) else { continue }
            if case .related(let video) = row {
                urls.append(video.thumbnailUrl)
            }
        }
        ImageLoader.shared.prefetch(urls)
    }
}

// MARK: - Reactions

/// The viewer's like and dislike, kept on the device.
///
/// YouTube's own like endpoint needs an account, and the app works signed out, so the reaction is
/// local: it changes the button, the count the page shows and nothing else. The two sets are stored
/// as plain string arrays so a reaction survives a relaunch.
enum WatchReactions {

    private static let likedKey = "watch.liked"
    private static let dislikedKey = "watch.disliked"

    static func isLiked(_ videoId: String) -> Bool {
        return values(for: likedKey).contains(videoId)
    }

    static func isDisliked(_ videoId: String) -> Bool {
        return values(for: dislikedKey).contains(videoId)
    }

    /// Toggles the like. Returns the new state.
    @discardableResult
    static func toggleLike(_ videoId: String) -> Bool {
        var liked = values(for: likedKey)
        if let index = liked.firstIndex(of: videoId) {
            liked.remove(at: index)
            store(liked, for: likedKey)
            return false
        }
        liked.append(videoId)
        store(liked, for: likedKey)
        return true
    }

    /// Toggles the dislike. Returns the new state.
    @discardableResult
    static func toggleDislike(_ videoId: String) -> Bool {
        var disliked = values(for: dislikedKey)
        if let index = disliked.firstIndex(of: videoId) {
            disliked.remove(at: index)
            store(disliked, for: dislikedKey)
            return false
        }
        disliked.append(videoId)
        store(disliked, for: dislikedKey)
        return true
    }

    static func clearLike(_ videoId: String) {
        var liked = values(for: likedKey)
        guard let index = liked.firstIndex(of: videoId) else { return }
        liked.remove(at: index)
        store(liked, for: likedKey)
    }

    static func clearDislike(_ videoId: String) {
        var disliked = values(for: dislikedKey)
        guard let index = disliked.firstIndex(of: videoId) else { return }
        disliked.remove(at: index)
        store(disliked, for: dislikedKey)
    }

    private static func values(for key: String) -> [String] {
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    private static func store(_ values: [String], for key: String) {
        UserDefaults.standard.set(values, forKey: key)
    }
}

// MARK: - Info cell

/// The video's title, its "1.2M views · 3 weeks ago" line and, as on Android, the "…more" that
/// opens the description. The whole block is one target, which is what the affordance promises.
final class WatchInfoCell: UITableViewCell {

    static let reuseIdentifier = "WatchInfoCell"

    /// Called when the title, the counts or "Show more" is tapped.
    var onOpenDescription: (() -> Void)?

    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let moreButton = UIButton(type: .system)
    private let badgeLabel = PaddedLabel()
    private let badgeRow = UIStackView()
    private let metaRow = UIStackView()
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        titleLabel.font = FlowTypography.titleLargeEmphasized
        titleLabel.numberOfLines = 3

        badgeLabel.font = FlowTypography.labelSmall
        badgeLabel.textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        badgeLabel.layer.cornerRadius = 4.0
        badgeLabel.layer.masksToBounds = true
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let badgeSpacer = UIView()
        badgeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        badgeRow.axis = .horizontal
        badgeRow.alignment = .center
        badgeRow.addArrangedSubview(badgeLabel)
        badgeRow.addArrangedSubview(badgeSpacer)

        metaLabel.font = FlowTypography.bodySmall
        metaLabel.numberOfLines = 1
        metaLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        moreButton.titleLabel?.font = FlowTypography.bodySmallEmphasized
        moreButton.contentHorizontalAlignment = .left
        moreButton.setContentHuggingPriority(.required, for: .horizontal)
        moreButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        moreButton.addTarget(self, action: #selector(handleOpenDescription), for: .touchUpInside)
        // Android's wording for this affordance, which sits beside the counts rather than below.
        moreButton.setTitle("…more", for: .normal)

        metaRow.axis = .horizontal
        metaRow.spacing = FlowSpacing.xs
        metaRow.alignment = .center
        metaRow.addArrangedSubview(metaLabel)
        metaRow.addArrangedSubview(moreButton)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = FlowSpacing.xs
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(badgeRow)
        stack.addArrangedSubview(metaRow)
        contentView.addSubviewForAutoLayout(stack)

        // The title and the counts open the description, as they do on Android. "Show more" is a
        // button of its own, so it needs no gesture of its own to reach the same handler.
        titleLabel.isUserInteractionEnabled = true
        titleLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleOpenDescription)))
        metaLabel.isUserInteractionEnabled = true
        metaLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleOpenDescription)))

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.md),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.sm),
            badgeLabel.heightAnchor.constraint(equalToConstant: 18.0),
        ])
        applyTheme()
    }

    /// Fills the cell.
    func configure(
        title: String,
        viewCount: Int64,
        uploadDate: String,
        isUpcoming: Bool,
        membersOnly: String?
    ) {
        titleLabel.text = title
        var parts: [String] = []
        if viewCount > 0 {
            parts.append(Formatters.viewCount(Int(min(viewCount, Int64(Int.max)))))
        }
        if !uploadDate.isEmpty {
            parts.append(uploadDate)
        }
        metaLabel.text = parts.joined(separator: " · ")

        if let membersOnly = membersOnly, !membersOnly.isEmpty {
            badgeLabel.text = membersOnly
            badgeRow.isHidden = false
        } else if isUpcoming {
            badgeLabel.text = "Upcoming"
            badgeRow.isHidden = false
        } else {
            badgeLabel.text = nil
            badgeRow.isHidden = true
        }
        applyTheme()
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        metaLabel.textColor = scheme.onSurfaceVariant
        moreButton.setTitleColor(scheme.onSurface, for: .normal)
        badgeLabel.textColor = scheme.onSecondaryContainer
        badgeLabel.backgroundColor = scheme.secondaryContainer
    }

    @objc private func handleOpenDescription() {
        onOpenDescription?()
    }
}

// MARK: - Channel cell

/// The channel's avatar, name and subscriber count, with the subscribe button.
final class WatchChannelCell: UITableViewCell {

    static let reuseIdentifier = "WatchChannelCell"

    /// Called when the channel's name or avatar is tapped.
    var onOpenChannel: (() -> Void)?
    /// Called when the subscribe button is tapped.
    var onToggleSubscription: (() -> Void)?

    private let avatarView = AsyncImageView(frame: .zero)
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let subscribeButton = FlowButton.make("Subscribe", style: .filled)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.applyCornerRadius(20.0)
        avatarView.isUserInteractionEnabled = true
        avatarView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleChannel)))
        contentView.addSubview(avatarView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = FlowTypography.titleSmallEmphasized
        nameLabel.isUserInteractionEnabled = true
        nameLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleChannel)))
        contentView.addSubview(nameLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        contentView.addSubview(detailLabel)

        subscribeButton.translatesAutoresizingMaskIntoConstraints = false
        subscribeButton.onTap = { [weak self] in self?.onToggleSubscription?() }
        contentView.addSubview(subscribeButton)

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.sm),
            avatarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.sm),
            avatarView.widthAnchor.constraint(equalToConstant: 40.0),
            avatarView.heightAnchor.constraint(equalToConstant: 40.0),

            nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: FlowSpacing.lg),
            nameLabel.topAnchor.constraint(equalTo: avatarView.topAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: subscribeButton.leadingAnchor, constant: -FlowSpacing.md),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: FlowSpacing.xxs),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: subscribeButton.leadingAnchor, constant: -FlowSpacing.md),

            subscribeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            subscribeButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            // `FlowButton` floors itself at 40 points, so the row asks for that rather than a
            // height the button would break.
            subscribeButton.heightAnchor.constraint(equalToConstant: 40.0),
        ])
        applyTheme()
    }

    /// Fills the cell.
    func configure(channel: Channel, isSubscribed: Bool) {
        avatarView.setImage(url: channel.thumbnailUrl)
        nameLabel.text = channel.name
        let detail = channel.subscriberCountText.isEmpty ? channel.handle : channel.subscriberCountText
        detailLabel.text = detail
        // The watch page's response often carries no subscriber line, and an empty label would
        // still take a line's height under the name.
        detailLabel.isHidden = detail.isEmpty
        setSubscribed(isSubscribed)
        accessibilityLabel = [channel.name, detail].filter { !$0.isEmpty }.joined(separator: ", ")
        applyTheme()
    }

    /// Changes the button's wording and style.
    func setSubscribed(_ subscribed: Bool) {
        subscribeButton.configure(
            title: subscribed ? "Subscribed" : "Subscribe",
            style: subscribed ? .tonal : .filled,
            icon: subscribed ? .check : nil
        )
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        nameLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        subscribeButton.applyTheme()
    }

    @objc private func handleChannel() {
        onOpenChannel?()
    }
}

// MARK: - Actions cell

/// The like/dislike pair and the share, save and download buttons.
final class WatchActionsCell: UITableViewCell {

    static let reuseIdentifier = "WatchActionsCell"

    /// Called when Like is tapped.
    var onLike: (() -> Void)?
    /// Called when Dislike is tapped.
    var onDislike: (() -> Void)?
    /// Called when Share is tapped.
    var onShare: (() -> Void)?
    /// Called when Save is tapped.
    var onSave: (() -> Void)?
    /// Called when Download is tapped.
    var onDownload: (() -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let likeButton = WatchActionButton.make(.heart, title: "Like")
    private let dislikeButton = WatchActionButton.make(.dislike, title: "Dislike")
    private let shareButton = WatchActionButton.make(.share, title: "Share")
    private let saveButton = WatchActionButton.make(.playlist, title: "Save")
    private let downloadButton = WatchActionButton.make(.download, title: "Download")

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        contentView.addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = FlowSpacing.md
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        for button in [likeButton, dislikeButton, shareButton, saveButton, downloadButton] {
            stack.addArrangedSubview(button)
        }

        likeButton.onTap = { [weak self] in self?.onLike?() }
        dislikeButton.onTap = { [weak self] in self?.onDislike?() }
        shareButton.onTap = { [weak self] in self?.onShare?() }
        saveButton.onTap = { [weak self] in self?.onSave?() }
        downloadButton.onTap = { [weak self] in self?.onDownload?() }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.xs),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.sm),
            scrollView.heightAnchor.constraint(equalToConstant: 40.0),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    /// Fills the row.
    func configure(
        likeCount: Int64,
        dislikeCount: Int64,
        isLiked: Bool,
        isDisliked: Bool,
        isSaved: Bool,
        isDownloaded: Bool
    ) {
        // Android's wording: the count when there is one, otherwise "Liked" or "Like".
        if likeCount > 0 {
            likeButton.setTitle(Formatters.compactCount(Int(min(likeCount, Int64(Int.max)))))
        } else {
            likeButton.setTitle(isLiked ? "Liked" : "Like")
        }
        likeButton.setIcon(isLiked ? .liked : .heart, tint: isLiked ? FlowTheme.shared.scheme.primary : nil)
        likeButton.setSelected(isLiked)

        // The dislike count is Return YouTube Dislike's, and it is shown only when the service knows
        // the video — a zero there means "unknown", not "nobody disliked it".
        dislikeButton.setTitle(dislikeCount > 0 ? Formatters.compactCount(Int(min(dislikeCount, Int64(Int.max)))) : "Dislike")
        dislikeButton.setIcon(.dislike, tint: isDisliked ? FlowTheme.shared.scheme.primary : nil)
        dislikeButton.setSelected(isDisliked)

        saveButton.setTitle(isSaved ? "Saved" : "Save")
        saveButton.setIcon(isSaved ? .check : .playlist, tint: isSaved ? FlowTheme.shared.scheme.primary : nil)
        saveButton.setSelected(isSaved)

        downloadButton.setTitle(isDownloaded ? "Downloaded" : "Download")
        downloadButton.setIcon(isDownloaded ? .downloaded : .download, tint: isDownloaded ? FlowTheme.shared.scheme.primary : nil)
        downloadButton.setSelected(isDownloaded)
    }
}

// MARK: - Action button

/// One pill in the action row: an icon and a label, filled while its state is on.
final class WatchActionButton: UIControl {

    private let iconView = FlowIconView()
    private let label = UILabel()
    private let stack = UIStackView()
    private var isOn = false

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
        layer.masksToBounds = true

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = FlowSpacing.sm
        stack.isUserInteractionEnabled = false
        addSubviewForAutoLayout(stack)

        iconView.iconSize = 18.0
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 18.0).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 18.0).isActive = true

        label.font = FlowTypography.labelLarge
        label.numberOfLines = 1

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.lg),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.lg),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 36.0),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        accessibilityTraits = .button
        applyTheme()
    }

    /// Creates a button.
    static func make(_ icon: FlowIcon, title: String) -> WatchActionButton {
        let button = WatchActionButton()
        button.iconView.icon = icon
        button.label.text = title
        button.accessibilityLabel = title
        return button
    }

    /// Sets the label.
    func setTitle(_ title: String) {
        label.text = title
        accessibilityLabel = title
    }

    /// Sets the glyph, optionally tinting it.
    func setIcon(_ icon: FlowIcon, tint: UIColor?) {
        iconView.icon = icon
        if let tint = tint {
            iconView.iconColor = tint
            label.textColor = tint
        } else {
            applyTheme()
        }
    }

    /// Sets whether the button reads as on.
    func setSelected(_ selected: Bool) {
        isOn = selected
        accessibilityTraits = selected ? [.button, .selected] : .button
        applyTheme()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2.0
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        if isOn {
            backgroundColor = scheme.secondaryContainer
            label.textColor = scheme.onSecondaryContainer
            iconView.iconColor = scheme.onSecondaryContainer
        } else {
            backgroundColor = scheme.surfaceContainerHigh
            label.textColor = scheme.onSurface
            iconView.iconColor = scheme.onSurface
        }
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.7 : 1.0
        }
    }

    @objc private func handleTap() {
        onTap?()
    }
}

// MARK: - Description cell

/// The description, expandable, with the chapters listed once it is open.
final class WatchDescriptionCell: UITableViewCell {

    static let reuseIdentifier = "WatchDescriptionCell"

    /// Called when the viewer expands or collapses the description.
    var onToggle: (() -> Void)?
    /// Called when the viewer taps a chapter.
    var onChapter: ((Chapter) -> Void)?
    /// Called when the viewer taps a link or a timestamp in the description.
    var onLink: ((URL) -> Void)?
    /// Called with a timestamp the description mentions, in seconds.
    var onSeek: ((TimeInterval) -> Void)?

    private let card = FlowCard.make(elevation: .low)
    private let textView = UITextView()
    private let toggleButton = UIButton(type: .custom)
    private let chaptersStack = UIStackView()
    private let chaptersHeader = UILabel()

    /// The description as last configured, so a theme change can rebuild its marked-up text.
    private var descriptionText = ""
    private var isDescriptionExpanded = false

    /// The card ends under the chapters when they are shown, and under the toggle when they are
    /// not. Both constraints exist and the one that does not apply is switched off, because a
    /// hidden view keeps its intrinsic size and would otherwise leave a gap in the card.
    private var chaptersBottom: NSLayoutConstraint!
    private var collapsedBottom: NSLayoutConstraint!
    private var textBottom: NSLayoutConstraint!
    private var toggleHeight: NSLayoutConstraint!
    private var chaptersTop: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        // A text view rather than a label: the description carries links and timestamps, and only
        // a text view can tell which one was tapped. It is made to look exactly like a label —
        // no scrolling, no padding, no selection — so the card still reads as text.
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0.0
        textView.dataDetectorTypes = []
        textView.delegate = self
        // An empty dictionary keeps the tint already set on the text: the default link styling
        // would paint every timestamp system blue and underline it.
        textView.linkTextAttributes = [:]
        // With scrolling off the view's height is its text's height, which is what the cell needs
        // to size itself; the priority keeps Auto Layout from compressing it instead.
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        card.contentView.addSubview(textView)

        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.titleLabel?.font = FlowTypography.labelMediumEmphasized
        toggleButton.contentHorizontalAlignment = .left
        toggleButton.addTarget(self, action: #selector(handleToggle), for: .touchUpInside)
        card.contentView.addSubview(toggleButton)

        chaptersHeader.translatesAutoresizingMaskIntoConstraints = false
        chaptersHeader.font = FlowTypography.titleSmallEmphasized
        chaptersHeader.text = "Chapters"
        card.contentView.addSubview(chaptersHeader)

        chaptersStack.axis = .vertical
        chaptersStack.spacing = FlowSpacing.xxs
        chaptersStack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(chaptersStack)

        toggleHeight = toggleButton.heightAnchor.constraint(equalToConstant: 24.0)
        chaptersTop = chaptersHeader.topAnchor.constraint(
            equalTo: toggleButton.bottomAnchor,
            constant: FlowSpacing.md
        )
        chaptersBottom = chaptersStack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor)
        collapsedBottom = toggleButton.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor)
        textBottom = textView.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.xs),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.xs),

            textView.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            textView.topAnchor.constraint(equalTo: card.contentView.topAnchor),

            toggleButton.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            toggleButton.trailingAnchor.constraint(lessThanOrEqualTo: card.contentView.trailingAnchor),
            toggleButton.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: FlowSpacing.xs),
            toggleHeight,

            chaptersHeader.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            chaptersHeader.trailingAnchor.constraint(equalTo: textView.trailingAnchor),

            chaptersStack.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            chaptersStack.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            chaptersStack.topAnchor.constraint(equalTo: chaptersHeader.bottomAnchor, constant: FlowSpacing.xs),
        ])
        applyTheme()
    }

    /// Fills the cell.
    func configure(description: String, chapters: [Chapter], isExpanded: Bool) {
        descriptionText = description.isEmpty ? "No description" : description
        isDescriptionExpanded = isExpanded
        textView.attributedText = WatchDescriptionCell.attributedDescription(descriptionText)
        // The text container is what truncates: a text view has no `numberOfLines`, but its
        // container does, and with scrolling off the cell sizes itself to what is shown.
        textView.textContainer.maximumNumberOfLines = isExpanded ? 0 : 4
        textView.textContainer.lineBreakMode = isExpanded ? .byWordWrapping : .byTruncatingTail

        toggleButton.setTitle(isExpanded ? "Show less" : "Show more", for: .normal)
        let showsToggle = !(description.isEmpty && chapters.isEmpty)
        toggleButton.isHidden = !showsToggle

        for view in chaptersStack.arrangedSubviews {
            chaptersStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let showsChapters = isExpanded && !chapters.isEmpty
        chaptersHeader.isHidden = !showsChapters
        chaptersStack.isHidden = !showsChapters
        if showsChapters {
            for chapter in chapters {
                let button = ChapterRowButton()
                button.configure(chapter: chapter)
                button.onTap = { [weak self] in self?.onChapter?(chapter) }
                chaptersStack.addArrangedSubview(button)
            }
        }
        updateBottomConstraints(showsToggle: showsToggle, showsChapters: showsChapters)
        applyTheme()
    }

    /// Makes the card end under whichever of the chapters, the toggle or the text is last.
    ///
    /// The header keeps its position below the toggle in every state — the toggle is collapsed to
    /// zero height rather than removed — so the chapters never float free of the card.
    private func updateBottomConstraints(showsToggle: Bool, showsChapters: Bool) {
        chaptersTop.isActive = true
        chaptersBottom.isActive = showsChapters
        collapsedBottom.isActive = !showsChapters && showsToggle
        textBottom.isActive = !showsChapters && !showsToggle
        toggleHeight.constant = showsToggle ? 24.0 : 0.0
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        toggleButton.setTitleColor(scheme.onSurface, for: .normal)
        chaptersHeader.textColor = scheme.onSurface
        card.applyTheme()
        // The marked-up text carries the palette's colours, so it is rebuilt rather than repainted.
        if !descriptionText.isEmpty {
            textView.attributedText = WatchDescriptionCell.attributedDescription(descriptionText)
            textView.textContainer.maximumNumberOfLines = isDescriptionExpanded ? 0 : 4
            textView.textContainer.lineBreakMode = isDescriptionExpanded ? .byWordWrapping : .byTruncatingTail
        }
    }

    /// Builds the description's attributed text: the body, with the timestamps and links tinted.
    ///
    /// A timestamp carries a `flow-seek://` URL of its own so the delegate can tell it from a real
    /// link; a link carries itself, so tapping it opens exactly what the description printed. Each
    /// match is marked where it was found rather than by searching for its text again, so the same
    /// timestamp printed twice gets both of its occurrences marked.
    static func attributedDescription(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: FlowTypography.bodyMedium,
            .foregroundColor: FlowTheme.shared.scheme.onSurfaceVariant,
            .paragraphStyle: paragraph,
        ])
        let primary = FlowTheme.shared.scheme.primary

        for match in matches(of: WatchDescriptionCell.timestampPattern, in: text) {
            guard let stamp = Range(match.range, in: text).map({ String(text[$0]) }),
                  let seconds = firstTimestamp(in: stamp) else { continue }
            result.addAttributes([
                .link: "flow-seek://" + String(Int(seconds)),
                .foregroundColor: primary,
            ], range: match.range)
        }
        for match in matches(of: WatchDescriptionCell.linkPattern, in: text) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            var url = String(text[swiftRange])
            while let last = url.last, ".,;:!?)]".contains(last) {
                url.removeLast()
            }
            guard !url.isEmpty, let target = URL(string: url) else { continue }
            // The trailing punctuation trimmed above is left outside the marked span.
            let length = (url as NSString).length
            result.addAttributes([
                .link: target,
                .foregroundColor: primary,
            ], range: NSRange(location: match.range.location, length: min(length, match.range.length)))
        }
        return result
    }

    /// The `m:ss` / `h:mm:ss` pattern. The look-behind and look-ahead keep a clock time inside a
    /// longer number — "1:234" or "10:30:45:00" — from being read as one.
    static let timestampPattern = "(?<![0-9:])([0-9]{1,2}):([0-5][0-9])(?::([0-5][0-9]))?(?![0-9:])"
    /// The URL pattern. Quotes and angle brackets end a URL, so a link inside markup is still one.
    static let linkPattern = "https?://[^\\s<>\"']+"

    private static func matches(of pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, options: [], range: range)
    }

    /// The seconds a `m:ss` / `h:mm:ss` string names.
    static func firstTimestamp(in stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 3 {
            return TimeInterval(parts[0] * 3_600 + parts[1] * 60 + parts[2])
        }
        return TimeInterval(parts[0] * 60 + parts[1])
    }

    @objc private func handleToggle() {
        onToggle?()
    }
}

extension WatchDescriptionCell: UITextViewDelegate {

    /// Called when a marked span is tapped. Returning `false` keeps the app from handing the URL
    /// to Safari, which it must: a `flow-seek:` URL is not something the system can open.
    func textView(
        _ textView: UITextView,
        shouldInteractWith URL: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        if URL.scheme == "flow-seek" {
            // `flow-seek://123` puts the seconds in the host.
            if let seconds = TimeInterval(URL.host ?? "") {
                onSeek?(seconds)
            }
            return false
        }
        onLink?(URL)
        return false
    }
}

/// One chapter: its start time and title.
final class ChapterRowButton: UIControl {

    private let timeLabel = UILabel()
    private let titleLabel = UILabel()
    private let iconView = FlowIconView()

    /// Called when the chapter is tapped.
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
        iconView.icon = .chapter
        iconView.iconSize = 14.0
        addSubview(iconView)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = FlowTypography.labelMediumEmphasized
        addSubview(timeLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.bodyMedium
        titleLabel.numberOfLines = 2
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32.0),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 8.0),
            iconView.widthAnchor.constraint(equalToConstant: 14.0),
            iconView.heightAnchor.constraint(equalToConstant: 14.0),

            timeLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: FlowSpacing.sm),
            timeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6.0),
            timeLabel.widthAnchor.constraint(equalToConstant: 56.0),

            titleLabel.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: FlowSpacing.sm),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5.0),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5.0),
        ])
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        applyTheme()
    }

    /// Fills the row.
    func configure(chapter: Chapter) {
        timeLabel.text = Formatters.playbackTime(chapter.startTime)
        titleLabel.text = chapter.title
        accessibilityLabel = Formatters.playbackTime(chapter.startTime) + ", " + chapter.title
        applyTheme()
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        timeLabel.textColor = scheme.primary
        titleLabel.textColor = scheme.onSurface
        iconView.iconColor = scheme.onSurfaceVariant
    }

    @objc private func handleTap() {
        onTap?()
    }
}

// MARK: - Comments preview cell

/// A one-comment preview under the description, with the way into the full list.
final class WatchCommentsPreviewCell: UITableViewCell {

    static let reuseIdentifier = "WatchCommentsPreviewCell"

    /// Called when the preview is tapped.
    var onOpen: (() -> Void)?

    private let card = FlowCard.make(elevation: .low)
    private let titleLabel = UILabel()
    private let avatarView = AsyncImageView(frame: .zero)
    private let authorLabel = UILabel()
    private let bodyLabel = UILabel()
    private let chevronView = FlowIconView()

    /// The body hangs off the author line when there is a comment, and off the heading when the
    /// card is showing the "Add a comment..." placeholder.
    private var bodyTopToAuthor: NSLayoutConstraint!
    private var bodyTopToTitle: NSLayoutConstraint!
    private var bodyLeadingToAuthor: NSLayoutConstraint!
    private var bodyLeadingToTitle: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.translatesAutoresizingMaskIntoConstraints = false
        card.makeTappable(target: self, action: #selector(handleOpen))
        contentView.addSubview(card)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmallEmphasized
        titleLabel.text = "Comments"
        card.contentView.addSubview(titleLabel)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.icon = .chevronRight
        chevronView.iconSize = 18.0
        card.contentView.addSubview(chevronView)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.applyCornerRadius(12.0)
        card.contentView.addSubview(avatarView)

        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        authorLabel.font = FlowTypography.labelMedium
        card.contentView.addSubview(authorLabel)

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = FlowTypography.bodySmall
        bodyLabel.numberOfLines = 2
        card.contentView.addSubview(bodyLabel)

        bodyTopToAuthor = bodyLabel.topAnchor.constraint(
            equalTo: authorLabel.bottomAnchor,
            constant: FlowSpacing.xxs
        )
        bodyTopToTitle = bodyLabel.topAnchor.constraint(
            equalTo: titleLabel.bottomAnchor,
            constant: FlowSpacing.md
        )
        bodyLeadingToAuthor = bodyLabel.leadingAnchor.constraint(equalTo: authorLabel.leadingAnchor)
        bodyLeadingToTitle = bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.xs),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.xs),

            titleLabel.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -FlowSpacing.md),

            chevronView.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            chevronView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 18.0),
            chevronView.heightAnchor.constraint(equalToConstant: 18.0),

            avatarView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            avatarView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.lg),
            avatarView.widthAnchor.constraint(equalToConstant: 24.0),
            avatarView.heightAnchor.constraint(equalToConstant: 24.0),
            avatarView.bottomAnchor.constraint(lessThanOrEqualTo: card.contentView.bottomAnchor),

            authorLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: FlowSpacing.lg),
            authorLabel.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            authorLabel.topAnchor.constraint(equalTo: avatarView.topAnchor),

            bodyLeadingToAuthor,
            bodyLabel.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            bodyTopToAuthor,
            bodyLabel.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
        ])
        applyTheme()
    }

    /// Fills the preview. The heading is Android's "Comments · 1.2K" when the count is known.
    func configure(totalText: String?, preview: Comment?) {
        if let total = totalText, !total.isEmpty {
            titleLabel.text = "Comments · " + total
        } else {
            titleLabel.text = "Comments"
        }

        if let preview = preview {
            avatarView.setImage(url: preview.authorThumbnail)
            avatarView.isHidden = false
            authorLabel.text = CommentsViewController.displayAuthor(preview.author)
            authorLabel.isHidden = false
            bodyLabel.text = preview.text
            bodyTopToTitle.isActive = false
            bodyLeadingToTitle.isActive = false
            bodyLeadingToAuthor.isActive = true
            bodyTopToAuthor.isActive = true
        } else {
            avatarView.clearImage()
            avatarView.isHidden = true
            authorLabel.text = nil
            authorLabel.isHidden = true
            bodyLabel.text = "Add a comment..."
            // With no author line the body hangs off the heading, as Android's placeholder does.
            bodyTopToAuthor.isActive = false
            bodyLeadingToAuthor.isActive = false
            bodyLeadingToTitle.isActive = true
            bodyTopToTitle.isActive = true
        }
        applyTheme()
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        authorLabel.textColor = scheme.onSurfaceVariant
        bodyLabel.textColor = scheme.onSurface
        chevronView.iconColor = scheme.onSurfaceVariant
        avatarView.placeholderColor = scheme.surfaceVariant
        card.applyTheme()
    }

    @objc private func handleOpen() {
        onOpen?()
    }
}

// MARK: - Section header cell

/// A plain section title, used above the related videos.
final class WatchSectionHeaderCell: UITableViewCell {

    static let reuseIdentifier = "WatchSectionHeaderCell"

    private let titleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleMedium
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.sm),
        ])
        applyTheme()
    }

    /// Sets the title.
    func configure(title: String) {
        titleLabel.text = title
        titleLabel.isHidden = title.isEmpty
        applyTheme()
    }

    private func applyTheme() {
        titleLabel.textColor = FlowTheme.shared.scheme.onSurface
    }
}

// MARK: - Related cell

/// One related video: its thumbnail, title and channel.
final class WatchRelatedCell: UITableViewCell {

    static let reuseIdentifier = "WatchRelatedCell"

    private let thumbnailView = AsyncImageView(frame: .zero)
    private let durationLabel = PaddedLabel()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.applyCornerRadius(FlowShapes.thumbnail)
        contentView.addSubview(thumbnailView)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = FlowTypography.labelSmall
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        durationLabel.layer.cornerRadius = 4.0
        durationLabel.layer.masksToBounds = true
        durationLabel.textInsets = UIEdgeInsets(top: 1, left: 4, bottom: 1, right: 4)
        contentView.addSubview(durationLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 2
        contentView.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            thumbnailView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.sm),
            thumbnailView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.sm),
            thumbnailView.widthAnchor.constraint(equalToConstant: 160.0),
            thumbnailView.heightAnchor.constraint(equalToConstant: 90.0),

            durationLabel.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: -FlowSpacing.xxs),
            durationLabel.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: -FlowSpacing.xxs),

            titleLabel.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            titleLabel.topAnchor.constraint(equalTo: thumbnailView.topAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),
        ])
        applyTheme()
    }

    /// Fills the cell.
    func configure(with video: Video) {
        titleLabel.text = video.title
        thumbnailView.setImage(url: video.thumbnailUrl)
        durationLabel.text = video.isLive ? "LIVE" : Formatters.durationBadge(TimeInterval(video.duration))
        durationLabel.isHidden = durationLabel.text == nil

        var parts: [String] = []
        if !video.channelName.isEmpty { parts.append(video.channelName) }
        if video.viewCount > 0 { parts.append(Formatters.viewCount(Int(min(video.viewCount, Int64(Int.max))))) }
        if !video.uploadDate.isEmpty { parts.append(video.uploadDate) }
        detailLabel.text = parts.joined(separator: " · ")
        accessibilityLabel = video.title
        applyTheme()
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
    }
}

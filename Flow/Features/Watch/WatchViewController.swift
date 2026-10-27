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
    /// Called with the playlist id the viewer picked.
    var onOpenPlaylist: ((String) -> Void)?
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

    /// One row of the page below the player.
    private enum WatchRow {
        case info
        case channel
        case actions
        case description
        case comments
        case relatedHeader
        case related(Video)
        case relatedLoading

        var id: String {
            switch self {
            case .info: return "info"
            case .channel: return "channel"
            case .actions: return "actions"
            case .description: return "description"
            case .comments: return "comments"
            case .relatedHeader: return "relatedHeader"
            case .related(let video): return "related:" + video.id
            case .relatedLoading: return "relatedLoading"
            }
        }
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

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
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
        playerContainer.addSubview(playerErrorLabel)

        let controller = VideoPlayerViewController(videoId: videoId, service: service)
        controller.onBack = { [weak self] in self?.handleBack() }
        controller.onOpenDetails = { [weak self] in self?.scrollToDescription() }
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        playerContainer.addSubview(controller.view)
        controller.didMove(toParent: self)
        playerController = controller

        NSLayoutConstraint.activate([
            playerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerContainer.topAnchor.constraint(equalTo: view.topAnchor),
            playerContainer.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 9.0 / 16.0),

            controller.view.leadingAnchor.constraint(equalTo: playerContainer.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: playerContainer.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: playerContainer.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: playerContainer.bottomAnchor),

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

    // MARK: - Loading

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        loadToken += 1
        let token = loadToken
        errorState.isHidden = true
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
    }

    private func showError(_ error: FlowError) {
        errorState.isHidden = false
        errorState.configure(
            kind: .custom(icon: .wifi, title: "Couldn't load this video", message: error.displayMessage),
            actionTitle: "Retry"
        )
    }

    private func updateEmptyState() {
        let empty = rows.isEmpty && !isLoading
        tableView.isHidden = empty
    }

    private func rebuildRows() {
        guard let model = model else {
            rows = []
            return
        }
        var result: [WatchRow] = [.info, .channel, .actions, .description]
        if model.page.commentsContinuation != nil || !model.page.related.isEmpty {
            result.append(.comments)
        }
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
        navigationController?.pushViewController(controller, animated: true)
    }

    private func openChannel(_ channelId: String) {
        guard !channelId.isEmpty else { return }
        if let handler = onOpenChannel {
            handler(channelId)
            return
        }
        let controller = ChannelViewController(channelId: channelId, api: api)
        navigationController?.pushViewController(controller, animated: true)
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
            guard let self = self else { return }
            self.service.seek(to: seconds)
            self.service.play()
        }
        controller.onClose = { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func toggleDescription() {
        isDescriptionExpanded.toggle()
        guard let index = rows.firstIndex(where: { row in
            if case .description = row { return true }
            return false
        }) else { return }
        tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .automatic)
    }

    private func scrollToDescription() {
        guard let index = rows.firstIndex(where: { row in
            if case .description = row { return true }
            return false
        }) else { return }
        tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .top, animated: true)
    }

    private func seek(to seconds: TimeInterval) {
        service.seek(to: seconds)
        service.play()
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
        let subscribers = Int(min(video.viewCount, Int64(Int.max)))
        let nowSubscribed = SubscriptionStore.shared.toggle(
            channelId: video.channelId,
            name: channelName,
            avatarUrl: avatar,
            subscriberCount: subscribers
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
            }
            return cell

        case .channel:
            let cell = tableView.dequeueReusableCell(withIdentifier: WatchChannelCell.reuseIdentifier, for: indexPath)
            if let channelCell = cell as? WatchChannelCell, let video = video {
                let channel = Channel(
                    id: video.channelId,
                    name: video.channelName,
                    thumbnailUrl: video.channelThumbnailUrl,
                    subscriberCountText: ""
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
            }
            return cell

        case .comments:
            let cell = tableView.dequeueReusableCell(withIdentifier: WatchCommentsPreviewCell.reuseIdentifier, for: indexPath)
            if let commentsCell = cell as? WatchCommentsPreviewCell {
                commentsCell.configure(totalText: nil, preview: nil)
                commentsCell.onOpen = { [weak self] in self?.openComments() }
                loadCommentPreview(into: commentsCell)
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

        case .relatedLoading:
            let cell = tableView.dequeueReusableCell(withIdentifier: WatchSectionHeaderCell.reuseIdentifier, for: indexPath)
            if let headerCell = cell as? WatchSectionHeaderCell {
                headerCell.configure(title: "")
            }
            return cell
        }
    }

    /// Fills the comments preview with the first comment, once it has loaded.
    private func loadCommentPreview(into cell: WatchCommentsPreviewCell) {
        guard let token = model?.page.commentsContinuation else { return }
        api.comments(videoId: videoId, continuation: token) { [weak cell] result in
            guard case .success(let page) = result else { return }
            DispatchQueue.main.async {
                cell?.configure(totalText: page.totalText, preview: page.comments.first)
            }
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

/// The video's title and its "1.2M views · 3 weeks ago" line.
final class WatchInfoCell: UITableViewCell {

    static let reuseIdentifier = "WatchInfoCell"

    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let badgeLabel = PaddedLabel()

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
        titleLabel.font = FlowTypography.titleLarge
        titleLabel.numberOfLines = 3
        contentView.addSubview(titleLabel)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = FlowTypography.bodySmall
        metaLabel.numberOfLines = 1
        contentView.addSubview(metaLabel)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = FlowTypography.labelSmall
        badgeLabel.textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        badgeLabel.layer.cornerRadius = 4.0
        badgeLabel.layer.masksToBounds = true
        badgeLabel.isHidden = true
        contentView.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.md),

            badgeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            badgeLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xs),
            badgeLabel.heightAnchor.constraint(equalToConstant: 18.0),

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: badgeLabel.bottomAnchor, constant: FlowSpacing.xs),
            metaLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.sm),
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
            badgeLabel.isHidden = false
        } else if isUpcoming {
            badgeLabel.text = "Upcoming"
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }
        applyTheme()
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        metaLabel.textColor = scheme.onSurfaceVariant
        badgeLabel.textColor = scheme.onSecondaryContainer
        badgeLabel.backgroundColor = scheme.secondaryContainer
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

    private let avatarView = AsyncImageView()
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
            subscribeButton.heightAnchor.constraint(equalToConstant: 36.0),
        ])
        applyTheme()
    }

    /// Fills the cell.
    func configure(channel: Channel, isSubscribed: Bool) {
        avatarView.setImage(url: channel.thumbnailUrl)
        nameLabel.text = channel.name
        detailLabel.text = channel.subscriberCountText.isEmpty
            ? (channel.handle.isEmpty ? "" : channel.handle)
            : channel.subscriberCountText
        setSubscribed(isSubscribed)
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
        likeButton.setTitle(likeCount > 0 ? Formatters.compactCount(Int(min(likeCount, Int64(Int.max)))) : "Like")
        likeButton.setIcon(.liked, tint: isLiked ? FlowTheme.shared.scheme.primary : nil)
        likeButton.setSelected(isLiked)

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

    private let card = FlowCard.make(elevation: .low)
    private let textLabel = UILabel()
    private let toggleButton = UIButton(type: .custom)
    private let chaptersStack = UIStackView()

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

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = FlowTypography.bodyMedium
        textLabel.numberOfLines = 4
        card.contentView.addSubview(textLabel)

        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.titleLabel?.font = FlowTypography.labelMediumEmphasized
        toggleButton.contentHorizontalAlignment = .left
        toggleButton.addTarget(self, action: #selector(handleToggle), for: .touchUpInside)
        card.contentView.addSubview(toggleButton)

        chaptersStack.axis = .vertical
        chaptersStack.spacing = FlowSpacing.xxs
        chaptersStack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(chaptersStack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.xs),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.xs),

            textLabel.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            textLabel.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            textLabel.topAnchor.constraint(equalTo: card.contentView.topAnchor),

            toggleButton.leadingAnchor.constraint(equalTo: textLabel.leadingAnchor),
            toggleButton.trailingAnchor.constraint(lessThanOrEqualTo: card.contentView.trailingAnchor),
            toggleButton.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: FlowSpacing.xs),
            toggleButton.heightAnchor.constraint(equalToConstant: 24.0),

            chaptersStack.leadingAnchor.constraint(equalTo: textLabel.leadingAnchor),
            chaptersStack.trailingAnchor.constraint(equalTo: textLabel.trailingAnchor),
            chaptersStack.topAnchor.constraint(equalTo: toggleButton.bottomAnchor, constant: FlowSpacing.xs),
            chaptersStack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
        ])
        applyTheme()
    }

    /// Fills the cell.
    func configure(description: String, chapters: [Chapter], isExpanded: Bool) {
        textLabel.text = description.isEmpty ? "No description" : description
        textLabel.numberOfLines = isExpanded ? 0 : 4
        toggleButton.setTitle(isExpanded ? "Show less" : "Show more", for: .normal)
        toggleButton.isHidden = description.isEmpty && chapters.isEmpty

        for view in chaptersStack.arrangedSubviews {
            chaptersStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        chaptersStack.isHidden = !isExpanded || chapters.isEmpty
        guard isExpanded else {
            applyTheme()
            return
        }
        for chapter in chapters {
            let button = ChapterRowButton()
            button.configure(chapter: chapter)
            button.onTap = { [weak self] in self?.onChapter?(chapter) }
            chaptersStack.addArrangedSubview(button)
        }
        applyTheme()
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        textLabel.textColor = scheme.onSurfaceVariant
        toggleButton.setTitleColor(scheme.onSurface, for: .normal)
        card.applyTheme()
    }

    @objc private func handleToggle() {
        onToggle?()
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
    private let totalLabel = UILabel()
    private let authorLabel = UILabel()
    private let bodyLabel = UILabel()
    private let chevronView = FlowIconView()

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

        totalLabel.translatesAutoresizingMaskIntoConstraints = false
        totalLabel.font = FlowTypography.labelSmall
        card.contentView.addSubview(totalLabel)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.icon = .chevronRight
        chevronView.iconSize = 18.0
        card.contentView.addSubview(chevronView)

        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        authorLabel.font = FlowTypography.labelMedium
        card.contentView.addSubview(authorLabel)

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = FlowTypography.bodyMedium
        bodyLabel.numberOfLines = 2
        card.contentView.addSubview(bodyLabel)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.xs),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.xs),

            titleLabel.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: card.contentView.topAnchor),

            totalLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: FlowSpacing.md),
            totalLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            chevronView.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            chevronView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 18.0),
            chevronView.heightAnchor.constraint(equalToConstant: 18.0),

            authorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            authorLabel.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            authorLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.md),

            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: FlowSpacing.xxs),
            bodyLabel.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
        ])
        applyTheme()
    }

    /// Fills the preview.
    func configure(totalText: String?, preview: Comment?) {
        totalLabel.text = totalText
        totalLabel.isHidden = (totalText ?? "").isEmpty
        authorLabel.text = preview?.author
        authorLabel.isHidden = preview == nil
        bodyLabel.text = preview?.text
        bodyLabel.isHidden = preview == nil
        if preview == nil {
            bodyLabel.text = "Tap to read the comments"
            bodyLabel.isHidden = false
        }
        applyTheme()
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        totalLabel.textColor = scheme.onSurfaceVariant
        authorLabel.textColor = scheme.onSurfaceVariant
        bodyLabel.textColor = scheme.onSurface
        chevronView.iconColor = scheme.onSurfaceVariant
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

    private let thumbnailView = AsyncImageView()
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

import UIKit

/// A playlist's page: the header art, title, item count, play-all and shuffle, and the reorderable
/// list of videos.
///
/// A local playlist is read from `PlaylistStore` and can be reordered and edited in place. A remote
/// playlist is read from YouTube and is read-only — the Android app keeps the same distinction,
/// because a sync would bring back anything removed from a mirrored playlist.
final class PlaylistViewController: UIViewController {

    // MARK: - Navigation

    /// Called when the viewer plays the playlist, with the videos, the start index and whether to
    /// shuffle.
    var onPlay: (([Video], Int, Bool) -> Void)?
    /// Called when the viewer opens one video.
    var onOpenVideo: ((Video) -> Void)?
    /// Called when the viewer opens a video's channel.
    var onOpenChannel: ((String) -> Void)?

    // MARK: - State

    private let playlistId: String
    private let api: YouTubeAPI
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let headerView = PlaylistHeaderView()
    private let searchBar = PlaylistSearchBarView()
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")
    private let emptyState = FlowEmptyState.make(kind: .custom(
        icon: .playlist,
        title: "This playlist is empty",
        message: "Add videos from the video player to build your playlist"
    ))
    private let sortButton = FlowIconButton.make(.sort, color: .clear, size: 22.0, target: nil, action: nil)

    private var stored: StoredPlaylist?
    private var remote: PlaylistPage?
    private var videos: [Video] = []
    private var shownVideos: [Video] = []
    private var isLocal = false
    private var isEditable = false
    private var isSearching = false
    private var sortOrder: PlaylistSort = .manual
    private var continuation: String?
    private var isLoading = false
    private var isLoadingMore = false
    private var themeToken: ObservationToken?
    private var playlistsToken: ObservationToken?

    /// The orders the playlist can be shown in, matching the Android screen's menu.
    enum PlaylistSort: Int, CaseIterable {
        case manual
        case dateAddedNewest
        case dateAddedOldest
        case mostPopular
        case datePublishedNewest
        case datePublishedOldest

        var title: String {
            switch self {
            case .manual: return "Manual"
            case .dateAddedNewest: return "Date added (newest)"
            case .dateAddedOldest: return "Date added (oldest)"
            case .mostPopular: return "Most popular"
            case .datePublishedNewest: return "Date published (newest)"
            case .datePublishedOldest: return "Date published (oldest)"
            }
        }
    }

    // MARK: - Construction

    init(playlistId: String, api: YouTubeAPI = YouTubeAPI()) {
        self.playlistId = playlistId
        self.api = api
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        playlistId = ""
        api = YouTubeAPI()
        super.init(coder: coder)
    }

    deinit {
        themeToken?.cancelObservation()
        playlistsToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildTable()
        buildChrome()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        playlistsToken = FlowEventBus.shared.on("playlists") { [weak self] _ in
            guard let self = self, self.isLocal else { return }
            DispatchQueue.main.async {
                self.reloadLocal()
            }
        }
        applyTheme()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isLocal {
            reloadLocal()
        }
    }

    // MARK: - Build

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 88.0
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.register(PlaylistVideoCell.self, forCellReuseIdentifier: PlaylistVideoCell.reuseIdentifier)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildChrome() {
        headerView.onPlayAll = { [weak self] in self?.play(shuffle: false) }
        headerView.onShuffle = { [weak self] in self?.play(shuffle: true) }
        headerView.onEdit = { [weak self] in self?.editPlaylist() }
        headerView.onDelete = { [weak self] in self?.deletePlaylist() }
        headerView.onDownloadAll = { [weak self] in self?.downloadAll() }
        headerView.onShare = { [weak self] in self?.sharePlaylist() }

        searchBar.onChange = { [weak self] text in
            self?.applySearch(text)
        }

        sortButton.accessibilityLabel = "Playlist sort options"
        sortButton.addTarget(self, action: #selector(handleSort), for: .touchUpInside)
        sortButton.widthAnchor.constraint(equalToConstant: 40.0).isActive = true

        // The header scrolls with the list, so the cover, the search field and the sort button
        // share one table header rather than sitting in fixed chrome above it.
        let searchRow = UIStackView(arrangedSubviews: [searchBar, sortButton])
        searchRow.axis = .horizontal
        searchRow.spacing = FlowSpacing.xs
        searchRow.alignment = .center

        let headerContainer = UIView()
        headerContainer.addSubviewForAutoLayout(headerView)
        headerContainer.addSubviewForAutoLayout(searchRow)
        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: headerContainer.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: PlaylistViewController.headerHeight),

            searchRow.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: FlowSpacing.screenMargin),
            searchRow.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -FlowSpacing.md),
            searchRow.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            searchRow.heightAnchor.constraint(equalToConstant: 40.0),
        ])
        headerContainer.frame = CGRect(
            x: 0,
            y: 0,
            width: tableView.bounds.width,
            height: PlaylistViewController.headerHeight + 40.0 + FlowSpacing.sm
        )
        tableView.tableHeaderView = headerContainer
        tableView.tableFooterView = UIView(frame: .zero)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        errorState.translatesAutoresizingMaskIntoConstraints = false
        errorState.isHidden = true
        errorState.onAction = { [weak self] in self?.load() }
        view.addSubview(errorState)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        view.addSubview(emptyState)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorState.topAnchor.constraint(equalTo: view.topAnchor),
            errorState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: PlaylistViewController.headerHeight + 40.0 + FlowSpacing.sm
            ),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Loading

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        errorState.isHidden = true
        if let local = PlaylistStore.shared.playlist(id: playlistId) {
            isLocal = true
            stored = local
            isEditable = local.isLocal
            spinner.stopAnimating()
            reloadLocal()
            isLoading = false
            return
        }
        spinner.startAnimating()
        api.playlist(id: playlistId) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoading = false
                self.spinner.stopAnimating()
                switch result {
                case .success(let page):
                    self.remote = page
                    self.isLocal = false
                    self.isEditable = false
                    self.videos = page.videos
                    self.continuation = page.continuation
                    self.rebuildHeader()
                    self.applySort()
                case .failure(let error):
                    self.errorState.isHidden = false
                    self.errorState.configure(
                        kind: .custom(icon: .wifi, title: "Couldn't load this playlist", message: error.displayMessage),
                        actionTitle: "Retry"
                    )
                }
            }
        }
    }

    private func reloadLocal() {
        guard let playlist = PlaylistStore.shared.playlist(id: playlistId) else { return }
        stored = playlist
        let entries = playlist.items
        videos = entries.map { entry in
            Video(
                id: entry.videoId,
                title: entry.title,
                channelName: entry.channelName,
                thumbnailUrl: entry.thumbnailUrl,
                duration: Int(entry.duration)
            )
        }
        rebuildHeader()
        applySort()
    }

    private func rebuildHeader() {
        let title: String
        let subtitle: String
        let artwork: String
        if let local = stored {
            title = local.title
            artwork = local.thumbnailUrl
            subtitle = PlaylistViewController.countText(videos.count)
        } else if let page = remote {
            title = page.playlist.name
            artwork = page.playlist.thumbnailUrl
            let count = page.trackCount ?? page.playlist.videoCount
            subtitle = PlaylistViewController.countText(count)
        } else {
            title = "Playlist"
            artwork = ""
            subtitle = ""
        }
        headerView.configure(
            title: title,
            subtitle: subtitle,
            artworkUrl: artwork,
            isEditable: isEditable
        )
    }

    /// The height of the cover block above the search field.
    private static let headerHeight: CGFloat = 244.0

    private func applySort() {
        var result = videos
        let addedAt = PlaylistViewController.addedDates(for: stored)
        switch sortOrder {
        case .manual:
            break
        case .dateAddedNewest:
            result.sort { left, right in
                let leftDate = addedAt[left.id] ?? Date(timeIntervalSince1970: 0)
                let rightDate = addedAt[right.id] ?? Date(timeIntervalSince1970: 0)
                return leftDate > rightDate
            }
        case .dateAddedOldest:
            result.sort { left, right in
                let leftDate = addedAt[left.id] ?? Date(timeIntervalSince1970: 0)
                let rightDate = addedAt[right.id] ?? Date(timeIntervalSince1970: 0)
                return leftDate < rightDate
            }
        case .mostPopular:
            result.sort { $0.viewCount > $1.viewCount }
        case .datePublishedNewest:
            result.sort { $0.timestamp > $1.timestamp }
        case .datePublishedOldest:
            result.sort { $0.timestamp < $1.timestamp }
        }
        videos = result
        applySearch(searchBar.text, reload: false)
        updateEmptyState()
        tableView.reloadData()
    }

    private func updateEmptyState() {
        let empty = shownVideos.isEmpty
        emptyState.isHidden = !empty
        if empty {
            emptyState.configure(kind: .custom(
                icon: .playlist,
                title: isSearching ? "No results" : "This playlist is empty",
                message: isSearching ? "Try a different search." : "Add videos from the video player to build your playlist"
            ))
        }
    }

    private func applySearch(_ text: String, reload: Bool = true) {
        let trimmed = text.trimmed
        isSearching = !trimmed.isEmpty
        if trimmed.isEmpty {
            shownVideos = videos
        } else {
            let lowered = trimmed.lowercased()
            shownVideos = videos.filter { video in
                return video.title.lowercased().contains(lowered)
                    || video.channelName.lowercased().contains(lowered)
            }
        }
        updateEmptyState()
        if reload {
            tableView.reloadData()
        }
    }

    /// When each video was added, for the "date added" orders. Remote playlists have no such
    /// dates, so every entry falls back to the epoch and the order stays as YouTube sent it.
    private static func addedDates(for playlist: StoredPlaylist?) -> [String: Date] {
        var dates: [String: Date] = [:]
        for entry in playlist?.items ?? [] {
            dates[entry.videoId] = entry.addedAt
        }
        return dates
    }

    private func loadMore() {
        guard let token = continuation, !token.isEmpty, !isLoadingMore, !isLocal else { return }
        isLoadingMore = true
        api.playlistContinuation(token) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoadingMore = false
                guard case .success(let page) = result else { return }
                var known = Set(self.videos.map { $0.id })
                for video in page.videos where !known.contains(video.id) {
                    self.videos.append(video)
                    known.insert(video.id)
                }
                self.continuation = page.continuation
                self.applySort()
            }
        }
    }

    // MARK: - Actions

    private func play(shuffle: Bool) {
        guard !videos.isEmpty else {
            FlowSnackbar.showError("This playlist is empty")
            return
        }
        onPlay?(videos, 0, shuffle)
    }

    private func editPlaylist() {
        guard let playlist = stored else { return }
        let content = PlaylistEditContent(title: playlist.title, description: playlist.description)
        let sheet = FlowSheet(content: content, title: "Edit playlist", detent: .large, showsGrabber: true)
        content.onSave = { [weak self, weak sheet] newTitle, newDescription in
            guard let self = self else { return }
            PlaylistStore.shared.renamePlaylist(id: self.playlistId, title: newTitle)
            PlaylistStore.shared.updateDescription(id: self.playlistId, description: newDescription)
            self.reloadLocal()
            sheet?.dismissSheet()
        }
        sheet.present(from: self)
    }

    private func deletePlaylist() {
        guard let playlist = stored else { return }
        let alert = UIAlertController(
            title: "Delete playlist?",
            message: "This will permanently delete '" + playlist.title + "' and all its videos.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { [weak self] _ in
            guard let self = self else { return }
            PlaylistStore.shared.deletePlaylist(id: self.playlistId)
            if let navigation = self.navigationController, navigation.viewControllers.first !== self {
                navigation.popViewController(animated: true)
            } else {
                self.dismiss(animated: true, completion: nil)
            }
        }))
        present(alert, animated: true, completion: nil)
    }

    private func downloadAll() {
        guard !videos.isEmpty else { return }
        var queued = 0
        for video in videos {
            if DownloadStore.shared.isDownloaded(videoId: video.id) { continue }
            DownloadStore.shared.enqueue(
                videoId: video.id,
                title: video.title,
                channelName: video.channelName,
                thumbnailUrl: video.thumbnailUrl,
                quality: PrefsStore.shared.string(for: .downloadQuality) ?? "720p",
                duration: TimeInterval(video.duration),
                isMusic: video.isMusic
            )
            queued += 1
        }
        if queued == 0 {
            FlowSnackbar.showError("Could not queue any downloads from this playlist")
        } else {
            FlowSnackbar.show("Queued " + String(queued) + "/" + String(videos.count) + " downloads")
        }
    }

    private func sharePlaylist() {
        let title = stored?.title ?? remote?.playlist.name ?? "Playlist"
        let text = title + "\nhttps://www.youtube.com/playlist?list=" + playlistId
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

    @objc private func handleSort() {
        let actions = PlaylistSort.allCases.map { option in
            FlowActionSheetContent.Action(title: option.title, icon: option == sortOrder ? .check : nil) { [weak self] in
                guard let self = self else { return }
                self.sortOrder = option
                self.applySort()
            }
        }
        let content = FlowActionSheetContent(actions: actions)
        let sheet = FlowSheet(content: content, title: "Playlist sort options", detent: .medium, showsGrabber: true)
        content.onActionSelected = { [weak sheet] in sheet?.dismissSheet() }
        sheet.present(from: self)
    }

    private func remove(at index: Int) {
        guard let video = shownVideos.element(at: index) else { return }
        guard let playlist = PlaylistStore.shared.playlist(id: playlistId) else { return }
        if let entry = playlist.items.first(where: { $0.videoId == video.id }) {
            PlaylistStore.shared.removeItem(rowId: entry.rowId, from: playlistId)
        } else {
            PlaylistStore.shared.removeVideo(videoId: video.id, from: playlistId)
        }
        FlowSnackbar.show("Removed from playlist")
    }

    private func move(from: Int, to: Int) {
        guard isEditable, sortOrder == .manual, !isSearching else { return }
        guard from != to, shownVideos.element(at: from) != nil else { return }
        PlaylistStore.shared.moveItem(in: playlistId, from: from, to: to)
        // The store rewrites the order on a background queue; the event it broadcasts is what
        // refreshes the list, so the rows only move once the new positions are committed.
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        sortButton.setIconColor(scheme.onSurface)
        headerView.applyTheme()
        errorState.applyTheme()
        emptyState.applyTheme()
        tableView.reloadData()
    }

    private static func countText(_ count: Int) -> String {
        if count == 1 {
            return "1 video"
        }
        return String(count) + " videos"
    }
}

// MARK: - Data source

extension PlaylistViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return shownVideos.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: PlaylistVideoCell.reuseIdentifier, for: indexPath)
        if let videoCell = cell as? PlaylistVideoCell, let video = shownVideos.element(at: indexPath.row) {
            videoCell.configure(with: video, position: indexPath.row + 1)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return isEditable
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return isEditable && sortOrder == .manual && !isSearching
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        remove(at: indexPath.row)
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        move(from: sourceIndexPath.row, to: destinationIndexPath.row)
    }
}

// MARK: - Delegate

extension PlaylistViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let video = shownVideos.element(at: indexPath.row) else { return }
        // Play the list as it is shown, so a sorted or filtered view keeps its order.
        onPlay?(shownVideos, indexPath.row, false)
        onOpenVideo?(video)
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard isEditable, let video = shownVideos.element(at: indexPath.row) else { return nil }
        let removeAction = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, completion in
            guard let self = self else {
                completion(false)
                return
            }
            if let playlist = PlaylistStore.shared.playlist(id: self.playlistId),
               let entry = playlist.items.first(where: { $0.videoId == video.id }) {
                PlaylistStore.shared.removeItem(rowId: entry.rowId, from: self.playlistId)
                completion(true)
            } else {
                completion(false)
            }
        }
        removeAction.backgroundColor = FlowTheme.shared.scheme.error
        return UISwipeActionsConfiguration(actions: [removeAction])
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        let offset = scrollView.contentOffset.y
        let height = scrollView.contentSize.height
        let visible = scrollView.bounds.height
        guard height > visible else { return }
        if offset > height - visible * 2.0 {
            loadMore()
        }
    }
}

// MARK: - Prefetching

extension PlaylistViewController: UITableViewDataSourcePrefetching {

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        var urls: [String] = []
        for indexPath in indexPaths {
            if let video = shownVideos.element(at: indexPath.row) {
                urls.append(video.thumbnailUrl)
            }
        }
        ImageLoader.shared.prefetch(urls)
    }
}

// MARK: - Header

/// The playlist's cover, title, count and action row.
final class PlaylistHeaderView: UIView {

    private let artworkView = AsyncImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let playButton = FlowButton.make("Play all", style: .filled, icon: .play)
    private let shuffleButton = FlowButton.make("Shuffle", style: .tonal, icon: .shuffle)
    private let downloadButton = FlowButton.makeIcon(.download, style: .text)
    private let shareButton = FlowButton.makeIcon(.share, style: .text)
    private let editButton = FlowButton.makeIcon(.edit, style: .text)
    private let deleteButton = FlowButton.makeIcon(.trash, style: .text)

    /// Called when Play all is tapped.
    var onPlayAll: (() -> Void)?
    /// Called when Shuffle is tapped.
    var onShuffle: (() -> Void)?
    /// Called when Download all is tapped.
    var onDownloadAll: (() -> Void)?
    /// Called when Share is tapped.
    var onShare: (() -> Void)?
    /// Called when Edit is tapped.
    var onEdit: (() -> Void)?
    /// Called when Delete is tapped.
    var onDelete: (() -> Void)?

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

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.applyCornerRadius(FlowShapes.medium)
        addSubview(artworkView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.headlineSmall
        titleLabel.numberOfLines = 2
        addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = FlowTypography.bodyMedium
        subtitleLabel.numberOfLines = 1
        addSubview(subtitleLabel)

        let primaryRow = UIStackView(arrangedSubviews: [playButton, shuffleButton])
        primaryRow.axis = .horizontal
        primaryRow.spacing = FlowSpacing.md
        primaryRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(primaryRow)

        let secondaryRow = UIStackView(arrangedSubviews: [downloadButton, shareButton, editButton, deleteButton])
        secondaryRow.axis = .horizontal
        secondaryRow.spacing = FlowSpacing.xs
        secondaryRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(secondaryRow)

        playButton.onTap = { [weak self] in self?.onPlayAll?() }
        shuffleButton.onTap = { [weak self] in self?.onShuffle?() }
        downloadButton.onTap = { [weak self] in self?.onDownloadAll?() }
        shareButton.onTap = { [weak self] in self?.onShare?() }
        editButton.onTap = { [weak self] in self?.onEdit?() }
        deleteButton.onTap = { [weak self] in self?.onDelete?() }

        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            artworkView.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.md),
            artworkView.widthAnchor.constraint(equalToConstant: 112.0),
            artworkView.heightAnchor.constraint(equalToConstant: 112.0),

            titleLabel.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.screenMargin),
            titleLabel.topAnchor.constraint(equalTo: artworkView.topAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xs),

            primaryRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            primaryRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -FlowSpacing.screenMargin),
            primaryRow.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: FlowSpacing.lg),
            primaryRow.heightAnchor.constraint(equalToConstant: 40.0),

            secondaryRow.leadingAnchor.constraint(equalTo: primaryRow.leadingAnchor),
            secondaryRow.topAnchor.constraint(equalTo: primaryRow.bottomAnchor, constant: FlowSpacing.sm),
            secondaryRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.sm),
        ])
        applyTheme()
    }

    /// Fills the header.
    func configure(title: String, subtitle: String, artworkUrl: String, isEditable: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        artworkView.setImage(url: artworkUrl)
        editButton.isHidden = !isEditable
        deleteButton.isHidden = !isEditable
        accessibilityLabel = title
    }

    /// Repaints the header in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        subtitleLabel.textColor = scheme.onSurfaceVariant
        playButton.applyTheme()
        shuffleButton.applyTheme()
        downloadButton.applyTheme()
        shareButton.applyTheme()
        editButton.applyTheme()
        deleteButton.applyTheme()
    }
}

// MARK: - Search bar

/// The playlist's search field, which filters the list by title and channel.
final class PlaylistSearchBarView: UIView, UITextFieldDelegate {

    private let container = UIView()
    private let textField = UITextField()
    private let iconView = FlowIconView()

    /// Called on every edit.
    var onChange: ((String) -> Void)?

    /// The field's current text.
    var text: String {
        return textField.text ?? ""
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

        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = FlowShapes.pill(for: 40.0)
        container.layer.masksToBounds = true
        addSubview(container)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.icon = .search
        iconView.iconSize = 18.0
        container.addSubview(iconView)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = FlowTypography.bodyMedium
        textField.placeholder = "Search"
        textField.returnKeyType = .search
        textField.delegate = self
        textField.addTarget(self, action: #selector(handleChange), for: .editingChanged)
        container.addSubview(textField)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: FlowSpacing.lg),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18.0),
            iconView.heightAnchor.constraint(equalToConstant: 18.0),

            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: FlowSpacing.md),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -FlowSpacing.lg),
            textField.topAnchor.constraint(equalTo: container.topAnchor),
            textField.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        applyTheme()
    }

    /// Repaints the field in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        container.backgroundColor = scheme.surfaceContainerHigh
        textField.textColor = scheme.onSurface
        textField.tintColor = scheme.primary
        iconView.iconColor = scheme.onSurfaceVariant
        textField.attributedPlaceholder = NSAttributedString(
            string: "Search",
            attributes: [.foregroundColor: scheme.onSurfaceVariant]
        )
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func handleChange() {
        onChange?(textField.text ?? "")
    }
}

// MARK: - Cell

/// One video in a playlist: its position, thumbnail, title and channel.
final class PlaylistVideoCell: UITableViewCell {

    static let reuseIdentifier = "PlaylistVideoCell"

    private let positionLabel = UILabel()
    private let thumbnailView = AsyncImageView()
    private let durationLabel = PaddedLabel()
    private let titleLabel = UILabel()
    private let channelLabel = UILabel()
    private let dragView = FlowIconView()

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

        positionLabel.translatesAutoresizingMaskIntoConstraints = false
        positionLabel.font = FlowTypography.bodySmall
        positionLabel.textAlignment = .center
        contentView.addSubview(positionLabel)

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

        channelLabel.translatesAutoresizingMaskIntoConstraints = false
        channelLabel.font = FlowTypography.bodySmall
        channelLabel.numberOfLines = 1
        contentView.addSubview(channelLabel)

        dragView.translatesAutoresizingMaskIntoConstraints = false
        dragView.icon = .drag
        dragView.iconSize = 18.0
        contentView.addSubview(dragView)

        NSLayoutConstraint.activate([
            positionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.md),
            positionLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            positionLabel.widthAnchor.constraint(equalToConstant: 20.0),

            thumbnailView.leadingAnchor.constraint(equalTo: positionLabel.trailingAnchor, constant: FlowSpacing.md),
            thumbnailView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 96.0),
            thumbnailView.heightAnchor.constraint(equalToConstant: 54.0),

            durationLabel.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: -FlowSpacing.xxs),
            durationLabel.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: -FlowSpacing.xxs),

            titleLabel.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: FlowSpacing.md),
            titleLabel.trailingAnchor.constraint(equalTo: dragView.leadingAnchor, constant: -FlowSpacing.sm),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),

            channelLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            channelLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            channelLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),

            dragView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.md),
            dragView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            dragView.widthAnchor.constraint(equalToConstant: 18.0),
            dragView.heightAnchor.constraint(equalToConstant: 18.0),
        ])
        applyTheme()
    }

    /// Fills the cell from a video and its position in the playlist.
    func configure(with video: Video, position: Int) {
        positionLabel.text = String(position)
        titleLabel.text = video.title
        channelLabel.text = video.channelName
        thumbnailView.setImage(url: video.thumbnailUrl)
        durationLabel.text = Formatters.durationBadge(TimeInterval(video.duration))
        durationLabel.isHidden = durationLabel.text == nil
        accessibilityLabel = video.title
        applyTheme()
    }

    /// Repaints the cell in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        positionLabel.textColor = scheme.onSurfaceVariant
        titleLabel.textColor = scheme.onSurface
        channelLabel.textColor = scheme.onSurfaceVariant
        dragView.iconColor = scheme.onSurfaceVariant
    }
}

// MARK: - Edit sheet

/// The edit sheet's content: a title field and a description field.
final class PlaylistEditContent: UIView, UITextFieldDelegate, UITextViewDelegate {

    /// Called with the new title and description.
    var onSave: ((String, String) -> Void)?

    private let titleField = UITextField()
    private let descriptionView = UITextView()
    private let saveButton = FlowButton.make("Save", style: .filled)

    init(title: String, description: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        titleField.text = title
        descriptionView.text = description
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    private func build() {
        let scheme = FlowTheme.shared.scheme

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = FlowTypography.bodyLarge
        titleField.placeholder = "Name"
        titleField.textColor = scheme.onSurface
        titleField.tintColor = scheme.primary
        titleField.borderStyle = .roundedRect
        titleField.backgroundColor = scheme.surfaceContainerHigh
        titleField.delegate = self
        addSubview(titleField)

        descriptionView.translatesAutoresizingMaskIntoConstraints = false
        descriptionView.font = FlowTypography.bodyMedium
        descriptionView.textColor = scheme.onSurface
        descriptionView.backgroundColor = scheme.surfaceContainerHigh
        descriptionView.layer.cornerRadius = FlowShapes.small
        descriptionView.layer.masksToBounds = true
        descriptionView.delegate = self
        addSubview(descriptionView)

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.onTap = { [weak self] in
            guard let self = self else { return }
            self.onSave?(self.titleField.text ?? "", self.descriptionView.text ?? "")
        }
        addSubview(saveButton)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleField.topAnchor.constraint(equalTo: topAnchor),
            titleField.heightAnchor.constraint(equalToConstant: 44.0),

            descriptionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            descriptionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            descriptionView.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: FlowSpacing.lg),
            descriptionView.heightAnchor.constraint(equalToConstant: 120.0),

            saveButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            saveButton.topAnchor.constraint(equalTo: descriptionView.bottomAnchor, constant: FlowSpacing.lg),
            saveButton.heightAnchor.constraint(equalToConstant: 44.0),
            saveButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

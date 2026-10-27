import UIKit

// MARK: - Sorting

/// How a music collection orders its songs. The list is the one the Android collection screen
/// offers, minus the orders that need data the iOS stores do not keep.
enum MusicSortOrder: CaseIterable {

    /// The collection's own order — the stored positions, or YouTube's running order.
    case collection
    case newestAdded
    case oldestAdded
    case title
    case artist
    case album
    case longest
    case shortest

    /// The menu title. The collection's own order is worded for what it means on this page — liked
    /// music is already newest first, so its own order is "Recently liked".
    func title(isLiked: Bool) -> String {
        switch self {
        case .collection: return isLiked ? "Recently liked" : "Playlist order"
        case .newestAdded: return "Date added (newest)"
        case .oldestAdded: return "Date added (oldest)"
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .longest: return "Longest first"
        case .shortest: return "Shortest first"
        }
    }

    /// The orders a collection has data for. Only stored collections know when a song was added, so
    /// the date orders appear only when the songs carry dates; liked music is already newest first,
    /// so for it "newest added" would only repeat its own order.
    static func available(hasAddedDates: Bool, isLiked: Bool) -> [MusicSortOrder] {
        return allCases.filter { order in
            switch order {
            case .newestAdded:
                return hasAddedDates && !isLiked
            case .oldestAdded:
                return hasAddedDates
            case .collection, .title, .artist, .album, .longest, .shortest:
                return true
            }
        }
    }
}

/// One song on a collection page, with the date it was added when the collection stores one.
private struct CollectionTrack {
    let song: SongItem
    let addedAt: Date?
    /// The stored row, when the song came from the local database. Removing a song needs it.
    let rowId: Int64?
}

// MARK: - Header

/// A collection's header: the cover, the title, the byline and metadata, then the action row.
final class MusicCollectionHeaderView: UIView {

    private let artworkView = AsyncImageView()
    private let kindLabel = UILabel()
    private let titleLabel = UILabel()
    private let authorButton = UIButton(type: .system)
    private let metadataLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let playButton = FlowButton.make("Play", style: .filled, icon: .play)
    private let shuffleButton = FlowButton.makeIcon(.shuffle, style: .tonal)
    private let editButton = FlowButton.makeIcon(.drag, style: .text)
    private let downloadButton = FlowButton.makeIcon(.download, style: .text)
    private let shareButton = FlowButton.makeIcon(.share, style: .text)

    /// Called when Play is tapped.
    var onPlay: (() -> Void)?
    /// Called when Shuffle is tapped.
    var onShuffle: (() -> Void)?
    /// Called when Reorder is tapped.
    var onEdit: (() -> Void)?
    /// Called when Download is tapped.
    var onDownload: (() -> Void)?
    /// Called when Share is tapped.
    var onShare: (() -> Void)?
    /// Called with the author's id when the byline is tapped.
    var onAuthor: ((String) -> Void)?

    private var authorId: String?

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

        kindLabel.translatesAutoresizingMaskIntoConstraints = false
        kindLabel.font = FlowTypography.labelMedium
        addSubview(kindLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.headlineSmall
        titleLabel.numberOfLines = 2
        addSubview(titleLabel)

        authorButton.translatesAutoresizingMaskIntoConstraints = false
        authorButton.titleLabel?.font = FlowTypography.bodyLarge
        authorButton.contentHorizontalAlignment = .leading
        authorButton.addTarget(self, action: #selector(handleAuthor), for: .touchUpInside)
        addSubview(authorButton)

        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.font = FlowTypography.bodySmall
        metadataLabel.numberOfLines = 2
        addSubview(metadataLabel)

        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = FlowTypography.bodySmall
        descriptionLabel.numberOfLines = 3
        descriptionLabel.isHidden = true
        addSubview(descriptionLabel)

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.onTap = { [weak self] in self?.onPlay?() }
        addSubview(playButton)

        shuffleButton.translatesAutoresizingMaskIntoConstraints = false
        shuffleButton.accessibilityLabel = "Shuffle"
        shuffleButton.onTap = { [weak self] in self?.onShuffle?() }
        addSubview(shuffleButton)

        editButton.translatesAutoresizingMaskIntoConstraints = false
        editButton.accessibilityLabel = "Reorder songs"
        editButton.onTap = { [weak self] in self?.onEdit?() }
        addSubview(editButton)

        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        downloadButton.accessibilityLabel = "Download"
        downloadButton.onTap = { [weak self] in self?.onDownload?() }
        addSubview(downloadButton)

        shareButton.translatesAutoresizingMaskIntoConstraints = false
        shareButton.accessibilityLabel = "Share"
        shareButton.onTap = { [weak self] in self?.onShare?() }
        addSubview(shareButton)

        let artworkSize = MusicMetrics.heroArtworkSize

        NSLayoutConstraint.activate([
            artworkView.centerXAnchor.constraint(equalTo: centerXAnchor),
            artworkView.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.xl),
            artworkView.widthAnchor.constraint(equalToConstant: artworkSize),
            artworkView.heightAnchor.constraint(equalToConstant: artworkSize),

            kindLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            kindLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.screenMargin),
            kindLabel.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: FlowSpacing.xl),

            titleLabel.leadingAnchor.constraint(equalTo: kindLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: kindLabel.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: kindLabel.bottomAnchor, constant: FlowSpacing.xs),

            authorButton.leadingAnchor.constraint(equalTo: kindLabel.leadingAnchor),
            authorButton.trailingAnchor.constraint(lessThanOrEqualTo: kindLabel.trailingAnchor),
            authorButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xs),
            authorButton.heightAnchor.constraint(equalToConstant: 28.0),

            metadataLabel.leadingAnchor.constraint(equalTo: kindLabel.leadingAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: kindLabel.trailingAnchor),
            metadataLabel.topAnchor.constraint(equalTo: authorButton.bottomAnchor, constant: FlowSpacing.xxs),

            descriptionLabel.leadingAnchor.constraint(equalTo: kindLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: kindLabel.trailingAnchor),
            descriptionLabel.topAnchor.constraint(equalTo: metadataLabel.bottomAnchor, constant: FlowSpacing.xs),

            playButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            playButton.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: FlowSpacing.lg),
            playButton.heightAnchor.constraint(equalToConstant: 44.0),

            shuffleButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: FlowSpacing.md),
            shuffleButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            shuffleButton.widthAnchor.constraint(equalToConstant: 44.0),
            shuffleButton.heightAnchor.constraint(equalToConstant: 44.0),

            editButton.leadingAnchor.constraint(equalTo: shuffleButton.trailingAnchor, constant: FlowSpacing.xs),
            editButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            editButton.widthAnchor.constraint(equalToConstant: 44.0),
            editButton.heightAnchor.constraint(equalToConstant: 44.0),

            downloadButton.trailingAnchor.constraint(equalTo: shareButton.leadingAnchor),
            downloadButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            downloadButton.widthAnchor.constraint(equalToConstant: 44.0),
            downloadButton.heightAnchor.constraint(equalToConstant: 44.0),

            shareButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.md),
            shareButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            shareButton.widthAnchor.constraint(equalToConstant: 44.0),
            shareButton.heightAnchor.constraint(equalToConstant: 44.0),
            shareButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.lg),
        ])
        applyTheme()
    }

    /// Fills the header. A nil `authorId` makes the byline a plain name rather than a link.
    func configure(
        kind: String,
        title: String,
        author: String?,
        authorId: String?,
        metadata: String,
        description: String?,
        artworkUrl: String?,
        canEdit: Bool
    ) {
        kindLabel.text = kind
        titleLabel.text = title
        self.authorId = authorId
        let name = author ?? ""
        authorButton.setTitle(name, for: .normal)
        authorButton.isHidden = name.isEmpty
        // "You" is plain text; a channel name is a link to that artist.
        authorButton.isUserInteractionEnabled = authorId != nil
        authorButton.accessibilityTraits = authorId == nil ? .staticText : .button
        metadataLabel.text = metadata
        // An empty label still reports a line's height, so the text is cleared as well as hidden.
        let note = (description ?? "").trimmed
        descriptionLabel.text = note.isEmpty ? nil : note
        descriptionLabel.isHidden = note.isEmpty
        artworkView.setImage(url: artworkUrl)
        editButton.isHidden = !canEdit
        accessibilityLabel = title
    }

    /// Shows whether every song in the collection is downloaded.
    func setDownloaded(_ downloaded: Bool) {
        downloadButton.setIcon(downloaded ? FlowIcon.downloaded : FlowIcon.download)
    }

    /// Repaints the header in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        kindLabel.textColor = scheme.onSurfaceVariant
        titleLabel.textColor = scheme.onSurface
        metadataLabel.textColor = scheme.onSurfaceVariant
        descriptionLabel.textColor = scheme.onSurfaceVariant
        authorButton.setTitleColor(scheme.onSurface, for: .normal)
        playButton.applyTheme()
        shuffleButton.applyTheme()
        editButton.applyTheme()
        downloadButton.applyTheme()
        shareButton.applyTheme()
        artworkView.applyTheme()
    }

    @objc private func handleAuthor() {
        guard let id = authorId else { return }
        onAuthor?(id)
    }
}

// MARK: - Collection

/// A music collection: Liked music, one of the viewer's own playlists, or a YouTube Music playlist.
///
/// All three read through the same table, because they differ only in where the songs come from.
/// A stored collection can be reordered and knows when each song was added; a YouTube playlist is
/// read-only and keeps YouTube's order. That is the same distinction the Android screen draws
/// between its OWN/SAVED kinds and a plain PLAYLIST.
final class MusicCollectionViewController: UIViewController {

    // MARK: - Source

    /// Where the collection's songs come from.
    enum Source {
        /// The local "Liked music" playlist, filled by the player's like button.
        case liked
        /// One of the viewer's own stored playlists.
        case local(playlistId: String)
        /// A playlist on YouTube Music, read-only.
        case remote(playlistId: String)
    }

    // MARK: - State

    private let source: Source
    private let api: YouTubeAPI
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let headerView = MusicCollectionHeaderView()
    private let sortButton = FlowIconButton()
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let emptyState = FlowEmptyState.make(kind: .custom(
        icon: .music,
        title: "This playlist is empty",
        message: "Add songs from any song's menu"
    ))
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")

    private var tracks: [CollectionTrack] = []
    private var sortOrder: MusicSortOrder = .collection
    private var remotePlaylist: PlaylistItem?
    private var continuation: String?
    private var isLoading = false
    private var isLoadingMore = false
    private var isReordering = false
    private var themeToken: ObservationToken?
    private var playlistsToken: ObservationToken?

    /// The playlist the songs are stored under, when the source is local. Liked music is stored as
    /// an ordinary playlist titled "Liked music", so it is looked up the same way.
    private var storedPlaylistId: String? {
        switch source {
        case .liked:
            return PlaylistStore.shared.localPlaylists()
                .first { $0.title == LikedMusic.playlistTitle }?
                .playlistId
        case .local(let playlistId):
            return playlistId
        case .remote:
            return nil
        }
    }

    /// Whether the songs live in the app's own database, which is what makes them reorderable.
    /// Liked music counts as stored even before the first like has created its playlist row.
    private var isStored: Bool {
        switch source {
        case .liked, .local:
            return true
        case .remote:
            return false
        }
    }

    /// Whether this is the built-in liked collection, which words its own order differently.
    private var isLikedCollection: Bool {
        if case .liked = source { return true }
        return false
    }

    /// Whether the viewer may drag songs around. A stored playlist keeps a manual order; liked
    /// music is ordered by when each song was liked, so there is nothing to drag.
    private var canReorder: Bool {
        if case .local = source { return true }
        return false
    }

    // MARK: - Construction

    init(source: Source, api: YouTubeAPI = YouTubeAPI()) {
        self.source = source
        self.api = api
        super.init(nibName: nil, bundle: nil)
        switch source {
        case .liked:
            title = LikedMusic.playlistTitle
        case .local, .remote:
            title = "Playlist"
        }
    }

    required init?(coder: NSCoder) {
        source = .liked
        api = YouTubeAPI()
        super.init(coder: coder)
        title = LikedMusic.playlistTitle
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
            guard let self = self, self.isStored else { return }
            DispatchQueue.main.async {
                // A reorder broadcasts its own commit; reloading mid-drag would yank the row the
                // viewer is holding, and the list already shows the order that was just written.
                guard !self.isReordering else { return }
                self.loadStored()
            }
        }
        applyTheme()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        if isStored {
            loadStored()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeader()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Build

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.rowHeight = MusicMetrics.trackRowHeight
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: FlowSpacing.xxl, right: 0)
        tableView.register(MusicTrackRowCell.self, forCellReuseIdentifier: MusicTrackRowCell.reuseIdentifier)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildChrome() {
        headerView.onPlay = { [weak self] in self?.play(startIndex: 0, shuffle: false) }
        headerView.onShuffle = { [weak self] in self?.play(startIndex: 0, shuffle: true) }
        headerView.onDownload = { [weak self] in self?.downloadAll() }
        headerView.onShare = { [weak self] in self?.share() }
        headerView.onEdit = { [weak self] in self?.toggleReordering() }
        headerView.onAuthor = { [weak self] id in
            guard let self = self else { return }
            MusicItemRouter.openArtist(id: id, from: self, api: self.api)
        }

        sortButton.translatesAutoresizingMaskIntoConstraints = false
        sortButton.configure(icon: .sort, color: FlowTheme.shared.onSurface, size: 22.0)
        sortButton.accessibilityLabel = "Sort"
        sortButton.addTarget(self, action: #selector(handleSort), for: .touchUpInside)
        sortButton.widthAnchor.constraint(equalToConstant: 44.0).isActive = true
        sortButton.heightAnchor.constraint(equalToConstant: 44.0).isActive = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: sortButton)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        view.addSubview(emptyState)

        errorState.translatesAutoresizingMaskIntoConstraints = false
        errorState.isHidden = true
        errorState.onAction = { [weak self] in self?.load(force: true) }
        view.addSubview(errorState)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: view.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            errorState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorState.topAnchor.constraint(equalTo: view.topAnchor),
            errorState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The header is a table header, so it is measured by hand whenever the width changes. An empty
    /// collection has no header: the empty state takes the whole screen and the navigation bar
    /// already carries the playlist's name.
    private func sizeHeader() {
        guard !tracks.isEmpty else {
            tableView.tableHeaderView = nil
            return
        }
        let width = tableView.bounds.width
        guard width > 0.0 else { return }
        let height = headerView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard height > 0.0 else { return }
        let current = tableView.tableHeaderView?.frame
        guard current?.height != height || current?.width != width else { return }
        headerView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableView.tableHeaderView = headerView
    }

    // MARK: - Loading

    private func load(force: Bool = false) {
        if isLoading && !force { return }
        isLoading = true
        errorState.isHidden = true
        if tracks.isEmpty {
            spinner.startAnimating()
        }
        switch source {
        case .liked, .local:
            loadStored()
        case .remote(let playlistId):
            loadRemote(playlistId: playlistId)
        }
    }

    /// Reads a stored collection: one of the viewer's playlists, or Liked music.
    private func loadStored() {
        isLoading = false
        spinner.stopAnimating()
        errorState.isHidden = true
        guard let playlistId = storedPlaylistId,
              let playlist = PlaylistStore.shared.playlist(id: playlistId) else {
            tracks = []
            updateHeader()
            tableView.reloadData()
            updateEmptyState()
            return
        }
        tracks = playlist.items.map { entry in
            let artists = entry.channelName.isEmpty
                ? []
                : [MusicArtist(name: entry.channelName, id: nil)]
            let song = SongItem(
                id: entry.videoId,
                title: entry.title,
                artists: artists,
                duration: Int(entry.duration),
                thumbnailUrl: entry.thumbnailUrl
            )
            return CollectionTrack(song: song, addedAt: entry.addedAt, rowId: entry.rowId)
        }
        title = playlist.title
        applySort()
        updateEmptyState()
    }

    private func loadRemote(playlistId: String) {
        api.musicPlaylist(id: playlistId) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoading = false
                self.spinner.stopAnimating()
                switch result {
                case .success(let page):
                    self.remotePlaylist = page.playlist
                    self.tracks = page.songs.map { CollectionTrack(song: $0, addedAt: nil, rowId: nil) }
                    self.continuation = page.continuation
                    self.title = page.playlist.title
                    self.applySort()
                    self.updateEmptyState()
                case .failure(let error):
                    self.tracks = []
                    self.remotePlaylist = nil
                    self.updateHeader()
                    self.tableView.reloadData()
                    self.emptyState.isHidden = true
                    self.errorState.isHidden = false
                    self.errorState.configure(
                        kind: .custom(icon: .wifi, title: "Couldn't load this playlist", message: error.displayMessage),
                        actionTitle: "Retry"
                    )
                }
            }
        }
    }

    private func loadMore() {
        guard let token = continuation, !token.isEmpty, !isLoadingMore else { return }
        isLoadingMore = true
        api.musicPlaylistContinuation(token) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoadingMore = false
                guard case .success(let page) = result else { return }
                var known = Set(self.tracks.map { $0.song.id })
                for song in page.songs where !known.contains(song.id) {
                    self.tracks.append(CollectionTrack(song: song, addedAt: nil, rowId: nil))
                    known.insert(song.id)
                }
                self.continuation = page.continuation
                self.applySort()
            }
        }
    }

    // MARK: - Header

    private func updateHeader() {
        let playlist = storedPlaylistId.flatMap { PlaylistStore.shared.playlist(id: $0) }
        let kind: String
        switch source {
        case .liked:
            kind = "Built-in playlist"
        case .local:
            kind = "Your playlist"
        case .remote:
            kind = "Playlist"
        }
        let duration = tracks.reduce(0.0) { total, track in
            return total + TimeInterval(max(track.song.duration ?? 0, 0))
        }
        let metadata = MusicFormat.metadata([
            MusicFormat.songCount(tracks.count),
            MusicFormat.duration(duration),
        ])
        let author: String?
        let authorId: String?
        switch source {
        case .liked:
            author = nil
            authorId = nil
        case .local:
            author = "You"
            authorId = nil
        case .remote:
            author = remotePlaylist?.authorName
            authorId = remotePlaylist?.authorId
        }
        let artwork = playlist?.thumbnailUrl
            ?? remotePlaylist?.thumbnailUrl
            ?? tracks.first?.song.thumbnailUrl
        headerView.configure(
            kind: kind,
            title: playlist?.title ?? remotePlaylist?.title ?? title ?? "Playlist",
            author: author,
            authorId: authorId,
            metadata: metadata,
            description: playlist?.description,
            artworkUrl: artwork,
            canEdit: canReorder && !tracks.isEmpty
        )
        headerView.setDownloaded(isFullyDownloaded)
        sizeHeader()
    }

    private var isFullyDownloaded: Bool {
        guard !tracks.isEmpty else { return false }
        return tracks.allSatisfy { DownloadStore.shared.isDownloaded(videoId: $0.song.id) }
    }

    private func updateEmptyState() {
        let empty = tracks.isEmpty
        emptyState.isHidden = !empty
        guard empty else { return }
        switch source {
        case .liked:
            emptyState.configure(kind: .custom(
                icon: .heart,
                title: "No liked songs yet",
                message: "Songs you like in the player show up here"
            ))
        case .local:
            emptyState.configure(kind: .custom(
                icon: .music,
                title: "This playlist is empty",
                message: "Add songs from any song's menu"
            ))
        case .remote:
            emptyState.configure(kind: .custom(
                icon: .music,
                title: "This playlist is empty",
                message: "YouTube returned no songs for it"
            ))
        }
    }

    // MARK: - Sorting

    private func applySort() {
        let hasDates = tracks.contains { $0.addedAt != nil }
        if !MusicSortOrder.available(hasAddedDates: hasDates, isLiked: isLikedCollection).contains(sortOrder) {
            sortOrder = .collection
        }
        switch sortOrder {
        case .collection:
            break
        case .newestAdded:
            tracks.sort { left, right in
                let leftDate = left.addedAt ?? Date(timeIntervalSince1970: 0)
                let rightDate = right.addedAt ?? Date(timeIntervalSince1970: 0)
                return leftDate > rightDate
            }
        case .oldestAdded:
            tracks.sort { left, right in
                let leftDate = left.addedAt ?? Date.distantFuture
                let rightDate = right.addedAt ?? Date.distantFuture
                return leftDate < rightDate
            }
        case .title:
            tracks.sort { $0.song.title.localizedCaseInsensitiveCompare($1.song.title) == .orderedAscending }
        case .artist:
            tracks.sort { $0.song.artistLine.localizedCaseInsensitiveCompare($1.song.artistLine) == .orderedAscending }
        case .album:
            tracks.sort { left, right in
                let leftAlbum = left.song.albumName ?? "\u{FFFF}"
                let rightAlbum = right.song.albumName ?? "\u{FFFF}"
                return leftAlbum.localizedCaseInsensitiveCompare(rightAlbum) == .orderedAscending
            }
        case .longest:
            tracks.sort { ($0.song.duration ?? 0) > ($1.song.duration ?? 0) }
        case .shortest:
            tracks.sort { left, right in
                let leftLength = left.song.duration ?? Int.max
                let rightLength = right.song.duration ?? Int.max
                return leftLength < rightLength
            }
        }
        // Dragging only makes sense in the collection's own order, so choosing another order puts
        // the handles away rather than leaving rows that cannot move.
        if isReordering && sortOrder != .collection {
            isReordering = false
            tableView.setEditing(false, animated: true)
        }
        updateHeader()
        tableView.reloadData()
    }

    @objc private func handleSort() {
        let hasDates = tracks.contains { $0.addedAt != nil }
        let options = MusicSortOrder.available(hasAddedDates: hasDates, isLiked: isLikedCollection)
        var actions = options.map { option in
            return FlowActionSheetContent.Action(
                title: option.title(isLiked: isLikedCollection),
                icon: option == sortOrder ? FlowIcon.check : nil
            ) { [weak self] in
                guard let self = self else { return }
                self.sortOrder = option
                self.applySort()
            }
        }
        if canReorder, !tracks.isEmpty {
            actions.append(FlowActionSheetContent.Action(title: "Reorder songs", icon: .drag) { [weak self] in
                self?.toggleReordering()
            })
        }
        let content = FlowActionSheetContent(actions: actions)
        let sheet = FlowSheet(content: content, title: "Sort", detent: .medium, showsGrabber: true)
        content.onActionSelected = { [weak sheet] in sheet?.dismissSheet() }
        sheet.present(from: self)
    }

    // MARK: - Reordering

    private func toggleReordering() {
        guard canReorder else {
            FlowSnackbar.show("This playlist can't be reordered")
            return
        }
        guard sortOrder == .collection else {
            FlowSnackbar.show("Choose Playlist order to reorder")
            return
        }
        isReordering = !isReordering
        tableView.setEditing(isReordering, animated: true)
        tableView.reloadData()
        // The list already holds the order the drags produced, and the store writes that same
        // order, so leaving edit mode only puts the handles away.
        FlowSnackbar.show(isReordering ? "Drag the handles to reorder" : "Order saved")
    }

    // MARK: - Playing

    private func play(startIndex: Int, shuffle: Bool) {
        guard !tracks.isEmpty else {
            FlowSnackbar.showError("This playlist is empty")
            return
        }
        let ordered = shuffle ? tracks.shuffled() : tracks
        let items = ordered.map { MusicItemRouter.queueItem(for: $0.song) }
        let index = shuffle ? 0 : min(max(startIndex, 0), items.count - 1)
        MusicItemRouter.play(items: items, startIndex: index, title: title, from: self)
    }

    private func downloadAll() {
        guard !tracks.isEmpty else { return }
        let quality = PrefsStore.shared.string(for: .downloadQuality) ?? "720p"
        var queued = 0
        for track in tracks {
            let song = track.song
            if DownloadStore.shared.isDownloaded(videoId: song.id)
                || DownloadStore.shared.isDownloading(videoId: song.id) {
                continue
            }
            DownloadStore.shared.enqueue(
                videoId: song.id,
                title: song.title,
                channelName: song.artistLine,
                thumbnailUrl: song.thumbnailUrl,
                quality: quality,
                duration: TimeInterval(song.duration ?? 0),
                isMusic: true
            )
            queued += 1
        }
        if queued == 0 {
            FlowSnackbar.show("Already downloaded")
        } else {
            FlowSnackbar.show("Queued " + String(queued) + " of " + String(tracks.count) + " songs")
        }
    }

    private func share() {
        let identifier: String
        switch source {
        case .liked:
            identifier = "LM"
        case .local(let playlistId), .remote(let playlistId):
            identifier = playlistId
        }
        guard let url = URL(string: "https://music.youtube.com/playlist?list=" + identifier) else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX,
            y: view.bounds.midY,
            width: 1.0,
            height: 1.0
        )
        present(activity, animated: true, completion: nil)
    }

    private func remove(at index: Int) {
        guard let track = tracks.element(at: index), let playlistId = storedPlaylistId else { return }
        if let rowId = track.rowId {
            PlaylistStore.shared.removeItem(rowId: rowId, from: playlistId)
        } else {
            PlaylistStore.shared.removeVideo(videoId: track.song.id, from: playlistId)
        }
        FlowSnackbar.show("Removed from playlist")
    }

    private func move(from: Int, to: Int) {
        guard canReorder, sortOrder == .collection, isReordering, from != to else { return }
        guard let playlistId = storedPlaylistId, tracks.element(at: from) != nil else { return }
        let moved = tracks.remove(at: from)
        tracks.insert(moved, at: min(to, tracks.count))
        PlaylistStore.shared.moveItem(in: playlistId, from: from, to: to)
        // The store renumbers on its own queue and broadcasts when it commits; the list already
        // shows the new order, so the rows do not jump back while the write is in flight.
    }

    private func showMenu(for track: CollectionTrack) {
        let item = MusicItemRouter.queueItem(for: track.song)
        var actions: [FlowActionSheetContent.Action] = [
            FlowActionSheetContent.Action(title: "Play next", icon: .next) {
                FlowApp.shared.playback.playNext(item)
                FlowSnackbar.show("Playing next")
            },
            FlowActionSheetContent.Action(title: "Add to queue", icon: .queue) {
                FlowApp.shared.playback.enqueue(item)
                FlowSnackbar.show("Added to queue")
            },
        ]
        if let artistId = track.song.artists.first?.id, !artistId.isEmpty {
            actions.append(FlowActionSheetContent.Action(title: "View Artist", icon: .music) { [weak self] in
                guard let self = self else { return }
                MusicItemRouter.openArtist(id: artistId, from: self, api: self.api)
            })
        }
        if let albumId = track.song.albumId, !albumId.isEmpty {
            actions.append(FlowActionSheetContent.Action(title: "View Album", icon: .playlist) { [weak self] in
                guard let self = self else { return }
                MusicItemRouter.openAlbum(id: albumId, from: self, api: self.api)
            })
        }
        if isStored {
            actions.append(FlowActionSheetContent.Action(title: "Remove", icon: .trash, isDestructive: true) { [weak self] in
                guard let self = self,
                      let index = self.tracks.firstIndex(where: { $0.song.id == track.song.id }) else {
                    return
                }
                self.remove(at: index)
            })
        }
        let content = FlowActionSheetContent(actions: actions)
        let sheet = FlowSheet(content: content, title: track.song.title, detent: .medium, showsGrabber: true)
        content.onActionSelected = { [weak sheet] in sheet?.dismissSheet() }
        sheet.present(from: self)
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        sortButton.setIconColor(scheme.onSurface)
        spinner.color = scheme.onSurfaceVariant
        emptyState.applyTheme()
        errorState.applyTheme()
        headerView.applyTheme()
        tableView.reloadData()
    }
}

// MARK: - Data source

extension MusicCollectionViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return tracks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let track = tracks.element(at: indexPath.row) else {
            return UITableViewCell()
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: MusicTrackRowCell.reuseIdentifier, for: indexPath)
        guard let trackCell = cell as? MusicTrackRowCell else { return cell }
        trackCell.onMenu = { [weak self] in self?.showMenu(for: track) }
        trackCell.configure(
            position: nil,
            title: track.song.title,
            subtitle: MusicFormat.metadata([track.song.artistLine, track.song.albumName]),
            artworkUrl: track.song.thumbnailUrl,
            duration: TimeInterval(track.song.duration ?? 0),
            isDownloaded: DownloadStore.shared.isDownloaded(videoId: track.song.id),
            showsMenu: !isReordering
        )
        trackCell.applyTheme()
        return trackCell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return isStored
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return canReorder && sortOrder == .collection
    }

    func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete else { return }
        remove(at: indexPath.row)
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        move(from: sourceIndexPath.row, to: destinationIndexPath.row)
    }
}

// MARK: - Delegate

extension MusicCollectionViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isReordering else { return }
        play(startIndex: indexPath.row, shuffle: false)
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        // While reordering, the row shows only its drag handle; removing is a swipe action then.
        guard isStored, !isReordering else { return .none }
        return .delete
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        return false
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard isStored, let track = tracks.element(at: indexPath.row) else { return nil }
        let removeAction = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, completion in
            guard let self = self,
                  let index = self.tracks.firstIndex(where: { $0.song.id == track.song.id }) else {
                completion(false)
                return
            }
            self.remove(at: index)
            completion(true)
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

extension MusicCollectionViewController: UITableViewDataSourcePrefetching {

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        var urls: [String] = []
        for indexPath in indexPaths {
            if let track = tracks.element(at: indexPath.row) {
                urls.append(track.song.thumbnailUrl)
            }
        }
        ImageLoader.shared.prefetch(urls)
    }
}

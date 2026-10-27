import UIKit

// MARK: - Album header

/// An album's header: the square cover, the title, the artist line, the metadata and the action
/// row. It is the table's header so it scrolls with the tracks.
final class AlbumHeaderView: UIView {

    private let artworkView = AsyncImageView()
    private let kindLabel = UILabel()
    private let titleLabel = UILabel()
    private let artistButton = UIButton(type: .system)
    private let metadataLabel = UILabel()
    private let playButton = FlowButton.make("Play all", style: .filled, icon: .play)
    private let shuffleButton = FlowButton.makeIcon(.shuffle, style: .tonal)
    private let saveButton = FlowButton.makeIcon(.add, style: .text)
    private let downloadButton = FlowButton.makeIcon(.download, style: .text)
    private let shareButton = FlowButton.makeIcon(.share, style: .text)

    /// Called when Play all is tapped.
    var onPlay: (() -> Void)?
    /// Called when Shuffle is tapped.
    var onShuffle: (() -> Void)?
    /// Called when Save to library is tapped.
    var onSave: (() -> Void)?
    /// Called when Download is tapped.
    var onDownload: (() -> Void)?
    /// Called when Share is tapped.
    var onShare: (() -> Void)?
    /// Called with the artist's id when the byline is tapped.
    var onArtist: ((String) -> Void)?

    private var artistId: String?

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
        kindLabel.text = "Album"
        addSubview(kindLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.headlineSmall
        titleLabel.numberOfLines = 2
        addSubview(titleLabel)

        artistButton.translatesAutoresizingMaskIntoConstraints = false
        artistButton.titleLabel?.font = FlowTypography.bodyLarge
        artistButton.contentHorizontalAlignment = .leading
        artistButton.addTarget(self, action: #selector(handleArtist), for: .touchUpInside)
        addSubview(artistButton)

        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.font = FlowTypography.bodySmall
        metadataLabel.numberOfLines = 2
        addSubview(metadataLabel)

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.onTap = { [weak self] in self?.onPlay?() }
        addSubview(playButton)

        shuffleButton.translatesAutoresizingMaskIntoConstraints = false
        shuffleButton.accessibilityLabel = "Shuffle"
        shuffleButton.onTap = { [weak self] in self?.onShuffle?() }
        addSubview(shuffleButton)

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.accessibilityLabel = "Save to library"
        saveButton.onTap = { [weak self] in self?.onSave?() }
        addSubview(saveButton)

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

            artistButton.leadingAnchor.constraint(equalTo: kindLabel.leadingAnchor),
            artistButton.trailingAnchor.constraint(lessThanOrEqualTo: kindLabel.trailingAnchor),
            artistButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xs),
            artistButton.heightAnchor.constraint(equalToConstant: 28.0),

            metadataLabel.leadingAnchor.constraint(equalTo: kindLabel.leadingAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: kindLabel.trailingAnchor),
            metadataLabel.topAnchor.constraint(equalTo: artistButton.bottomAnchor, constant: FlowSpacing.xxs),

            playButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            playButton.topAnchor.constraint(equalTo: metadataLabel.bottomAnchor, constant: FlowSpacing.lg),
            playButton.heightAnchor.constraint(equalToConstant: 44.0),

            shuffleButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: FlowSpacing.md),
            shuffleButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            shuffleButton.widthAnchor.constraint(equalToConstant: 44.0),
            shuffleButton.heightAnchor.constraint(equalToConstant: 44.0),

            shareButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.md),
            shareButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            shareButton.widthAnchor.constraint(equalToConstant: 44.0),
            shareButton.heightAnchor.constraint(equalToConstant: 44.0),

            downloadButton.trailingAnchor.constraint(equalTo: shareButton.leadingAnchor),
            downloadButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            downloadButton.widthAnchor.constraint(equalToConstant: 44.0),
            downloadButton.heightAnchor.constraint(equalToConstant: 44.0),

            saveButton.trailingAnchor.constraint(equalTo: downloadButton.leadingAnchor),
            saveButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 44.0),
            saveButton.heightAnchor.constraint(equalToConstant: 44.0),
            saveButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.lg),
        ])
        applyTheme()
    }

    /// Fills the header from the page.
    func configure(page: AlbumPage, songCount: Int, totalDuration: TimeInterval, isSaved: Bool) {
        artworkView.setImage(url: page.album.thumbnailUrl)
        titleLabel.text = page.album.title
        artistId = page.album.artists.first?.id
        let artistName = page.album.artistLine
        artistButton.setTitle(artistName, for: .normal)
        artistButton.isHidden = artistName.isEmpty || artistId == nil
        let length = page.durationText ?? MusicFormat.duration(totalDuration)
        metadataLabel.text = MusicFormat.metadata([
            MusicFormat.year(page.album.year),
            MusicFormat.songCount(songCount),
            length,
        ])
        setSaved(isSaved)
        accessibilityLabel = page.album.title
    }

    /// Shows the library state on the save button.
    func setSaved(_ saved: Bool) {
        saveButton.setIcon(saved ? .check : .add)
        saveButton.accessibilityLabel = saved ? "Remove from library" : "Save to library"
    }

    /// Shows whether the album is already downloaded.
    func setDownloaded(_ downloaded: Bool) {
        downloadButton.setIcon(downloaded ? .downloaded : .download)
    }

    /// Repaints the header in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        kindLabel.textColor = scheme.onSurfaceVariant
        titleLabel.textColor = scheme.onSurface
        metadataLabel.textColor = scheme.onSurfaceVariant
        artistButton.setTitleColor(scheme.onSurface, for: .normal)
        playButton.applyTheme()
        shuffleButton.applyTheme()
        saveButton.applyTheme()
        downloadButton.applyTheme()
        shareButton.applyTheme()
        artworkView.applyTheme()
    }

    @objc private func handleArtist() {
        guard let id = artistId else { return }
        onArtist?(id)
    }
}

// MARK: - Album page

/// An album's page: the cover and its actions, the track list in running order, and the album's
/// other versions when YouTube lists them.
///
/// Saving writes the album into the library as a stored playlist, which is what makes it appear in
/// the Library tab and lets it be played with no network beyond the downloaded tracks.
final class AlbumViewController: UIViewController {

    // MARK: - State

    private let albumId: String
    private let api: YouTubeAPI
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let headerView = AlbumHeaderView()
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")

    private var page: AlbumPage?
    private var songs: [SongItem] = []
    private var otherVersions: [AlbumItem] = []
    private var isLoading = false
    private var themeToken: ObservationToken?
    private var playlistsToken: ObservationToken?

    /// The id the album is stored under in the library. YouTube's playlist id is the one that can
    /// be played again; the browse id is the fallback when the response carried no playlist.
    private var libraryId: String {
        guard let page = page else { return albumId }
        return page.album.playlistId.isEmpty ? page.album.browseId : page.album.playlistId
    }

    // MARK: - Construction

    init(albumId: String, api: YouTubeAPI = YouTubeAPI()) {
        self.albumId = albumId
        self.api = api
        super.init(nibName: nil, bundle: nil)
        title = "Album"
    }

    required init?(coder: NSCoder) {
        albumId = ""
        api = YouTubeAPI()
        super.init(coder: coder)
        title = "Album"
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
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.refreshSavedState()
            }
        }
        applyTheme()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        refreshSavedState()
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
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: FlowSpacing.xxl, right: 0)
        tableView.register(MusicTrackRowCell.self, forCellReuseIdentifier: MusicTrackRowCell.reuseIdentifier)
        tableView.register(MusicCarouselCell.self, forCellReuseIdentifier: MusicCarouselCell.reuseIdentifier)
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
        headerView.onSave = { [weak self] in self?.toggleSaved() }
        headerView.onDownload = { [weak self] in self?.downloadAll() }
        headerView.onShare = { [weak self] in self?.share() }
        headerView.onArtist = { [weak self] id in
            guard let self = self else { return }
            MusicItemRouter.openArtist(id: id, from: self, api: self.api)
        }

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        errorState.translatesAutoresizingMaskIntoConstraints = false
        errorState.isHidden = true
        errorState.onAction = { [weak self] in self?.load(force: true) }
        view.addSubview(errorState)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorState.topAnchor.constraint(equalTo: view.topAnchor),
            errorState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeader()
    }

    /// The header is a table header, so it is measured by hand whenever the width changes.
    private func sizeHeader() {
        guard page != nil else {
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
        guard tableView.tableHeaderView?.frame.height != height || tableView.tableHeaderView?.frame.width != width else {
            return
        }
        headerView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableView.tableHeaderView = headerView
    }

    // MARK: - Loading

    private func load(force: Bool = false) {
        if isLoading && !force { return }
        isLoading = true
        errorState.isHidden = true
        if page == nil {
            spinner.startAnimating()
        }

        api.album(id: albumId) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoading = false
                self.spinner.stopAnimating()
                switch result {
                case .success(let page):
                    self.page = page
                    self.songs = page.songs
                    self.otherVersions = page.otherVersions
                    self.title = page.album.title
                    self.headerView.configure(
                        page: page,
                        songCount: page.songs.count,
                        totalDuration: MusicFormat.totalDuration(page.songs),
                        isSaved: self.isSaved
                    )
                    self.headerView.setDownloaded(self.isFullyDownloaded)
                    self.sizeHeader()
                    self.tableView.reloadData()
                case .failure(let error):
                    if self.page == nil {
                        self.errorState.isHidden = false
                        self.errorState.configure(
                            kind: .custom(icon: .wifi, title: "Couldn't load this album", message: error.displayMessage),
                            actionTitle: "Retry"
                        )
                    } else {
                        FlowSnackbar.showError(error.displayMessage)
                    }
                }
            }
        }
    }

    // MARK: - Library

    private var isSaved: Bool {
        return PlaylistStore.shared.playlist(id: libraryId) != nil
    }

    private var isFullyDownloaded: Bool {
        guard !songs.isEmpty else { return false }
        return songs.allSatisfy { DownloadStore.shared.isDownloaded(videoId: $0.id) }
    }

    private func refreshSavedState() {
        guard page != nil else { return }
        headerView.setSaved(isSaved)
        headerView.setDownloaded(isFullyDownloaded)
    }

    /// Saves the album into the library, or takes it out again.
    private func toggleSaved() {
        guard let page = page else { return }
        if isSaved {
            PlaylistStore.shared.deletePlaylist(id: libraryId)
            headerView.setSaved(false)
            FlowSnackbar.show("Removed from library")
            return
        }
        let entries = songs.enumerated().map { offset, song in
            PlaylistEntry(
                rowId: 0,
                playlistId: libraryId,
                videoId: song.id,
                title: song.title,
                channelName: song.artistLine,
                thumbnailUrl: song.thumbnailUrl,
                duration: TimeInterval(song.duration ?? 0),
                position: offset,
                addedAt: Date()
            )
        }
        PlaylistStore.shared.saveRemotePlaylist(
            playlistId: libraryId,
            title: page.album.title,
            description: page.album.artistLine,
            thumbnailUrl: page.album.thumbnailUrl,
            items: entries
        )
        headerView.setSaved(true)
        FlowSnackbar.show("Saved to your library")
    }

    // MARK: - Actions

    private func play(startIndex: Int, shuffle: Bool) {
        guard !songs.isEmpty else {
            FlowSnackbar.showError("This album has no songs here")
            return
        }
        let ordered = shuffle ? songs.shuffled() : songs
        MusicItemRouter.play(songs: ordered, startIndex: startIndex, title: page?.album.title, from: self)
    }

    private func downloadAll() {
        guard !songs.isEmpty else { return }
        let quality = PrefsStore.shared.string(for: .downloadQuality) ?? "720p"
        var queued = 0
        for song in songs {
            if DownloadStore.shared.isDownloaded(videoId: song.id) || DownloadStore.shared.isDownloading(videoId: song.id) {
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
            FlowSnackbar.show("Queued " + String(queued) + "/" + String(songs.count) + " downloads")
        }
    }

    private func share() {
        guard let page = page, let url = URL(string: page.album.shareURL) else { return }
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

    private func showSongMenu(_ song: SongItem) {
        let item = MusicItemRouter.queueItem(for: song)
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
        if let artistId = song.artists.first?.id, !artistId.isEmpty {
            actions.append(FlowActionSheetContent.Action(title: "View Artist", icon: .music) { [weak self] in
                guard let self = self else { return }
                MusicItemRouter.openArtist(id: artistId, from: self, api: self.api)
            })
        }
        actions.append(FlowActionSheetContent.Action(title: "Share", icon: .share) { [weak self] in
            guard let self = self, let url = URL(string: song.shareURL) else { return }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = self.view
            activity.popoverPresentationController?.sourceRect = CGRect(
                x: self.view.bounds.midX,
                y: self.view.bounds.midY,
                width: 1.0,
                height: 1.0
            )
            self.present(activity, animated: true, completion: nil)
        })
        let content = FlowActionSheetContent(actions: actions)
        let sheet = FlowSheet(content: content, title: song.title, detent: .medium, showsGrabber: true)
        content.onActionSelected = { [weak sheet] in sheet?.dismissSheet() }
        sheet.present(from: self)
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        spinner.color = scheme.onSurfaceVariant
        errorState.applyTheme()
        headerView.applyTheme()
        tableView.reloadData()
    }

    // MARK: - Other versions

    private func versionCards() -> [UIView] {
        var views: [UIView] = []
        for album in otherVersions {
            let card = MusicCollectionCardView()
            card.configure(
                title: album.title,
                subtitle: MusicFormat.metadata([album.artistLine, MusicFormat.year(album.year)]),
                artworkUrl: album.thumbnailUrl,
                isExplicit: album.isExplicit
            )
            card.onTap = { [weak self] in
                guard let self = self else { return }
                MusicItemRouter.openAlbum(id: album.browseId, from: self, api: self.api)
            }
            views.append(card)
        }
        return views
    }
}

// MARK: - Data source

extension AlbumViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        return otherVersions.isEmpty ? 1 : 2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return songs.count
        }
        return otherVersions.isEmpty ? 0 : 1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1 {
            let cell = tableView.dequeueReusableCell(withIdentifier: MusicCarouselCell.reuseIdentifier, for: indexPath)
            guard let carouselCell = cell as? MusicCarouselCell else { return cell }
            carouselCell.carousel.configure(title: "Other versions")
            carouselCell.carousel.setItems(versionCards())
            carouselCell.carousel.applyTheme()
            return carouselCell
        }

        guard let song = songs.element(at: indexPath.row) else {
            return UITableViewCell()
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: MusicTrackRowCell.reuseIdentifier, for: indexPath)
        guard let trackCell = cell as? MusicTrackRowCell else { return cell }
        trackCell.onMenu = { [weak self] in self?.showSongMenu(song) }
        trackCell.configure(
            position: indexPath.row + 1,
            title: song.title,
            subtitle: song.artistLine,
            artworkUrl: song.thumbnailUrl,
            duration: TimeInterval(song.duration ?? 0),
            isDownloaded: DownloadStore.shared.isDownloaded(videoId: song.id)
        )
        trackCell.applyTheme()
        return trackCell
    }
}

// MARK: - Delegate

extension AlbumViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.section == 1 {
            return MusicMetrics.carouselRowHeight
        }
        return MusicMetrics.trackRowHeight
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0 else { return }
        play(startIndex: indexPath.row, shuffle: false)
    }
}

// MARK: - Prefetching

extension AlbumViewController: UITableViewDataSourcePrefetching {

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        var urls: [String] = []
        for indexPath in indexPaths where indexPath.section == 0 {
            if let song = songs.element(at: indexPath.row) {
                urls.append(song.thumbnailUrl)
            }
        }
        ImageLoader.shared.prefetch(urls)
    }
}

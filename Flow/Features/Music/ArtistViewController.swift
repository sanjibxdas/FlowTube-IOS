import UIKit

// MARK: - Hero

/// An artist's hero: the round portrait, the name, the listener line and the action row. It is the
/// table's header, so it scrolls away with the songs rather than sitting in fixed chrome.
final class ArtistHeroView: UIView {

    private let artworkView = AsyncImageView()
    private let nameLabel = UILabel()
    private let metadataLabel = UILabel()
    private let playButton = FlowButton.make("Play", style: .filled, icon: .play)
    private let shuffleButton = FlowButton.make("Shuffle", style: .tonal, icon: .shuffle)
    private let subscribeButton = FlowButton.make("Subscribe", style: .outlined)
    private let shareButton = FlowButton.makeIcon(.share, style: .text)

    /// Called when Play is tapped.
    var onPlay: (() -> Void)?
    /// Called when Shuffle is tapped.
    var onShuffle: (() -> Void)?
    /// Called when Subscribe is tapped.
    var onSubscribe: (() -> Void)?
    /// Called when Share is tapped.
    var onShare: (() -> Void)?

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
        artworkView.layer.cornerRadius = MusicMetrics.artistHeroSize / 2.0
        addSubview(artworkView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = FlowTypography.headlineSmall
        nameLabel.numberOfLines = 2
        nameLabel.textAlignment = .center
        addSubview(nameLabel)

        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.font = FlowTypography.bodyMedium
        metadataLabel.numberOfLines = 2
        metadataLabel.textAlignment = .center
        addSubview(metadataLabel)

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.onTap = { [weak self] in self?.onPlay?() }
        addSubview(playButton)

        shuffleButton.translatesAutoresizingMaskIntoConstraints = false
        shuffleButton.onTap = { [weak self] in self?.onShuffle?() }
        addSubview(shuffleButton)

        subscribeButton.translatesAutoresizingMaskIntoConstraints = false
        subscribeButton.onTap = { [weak self] in self?.onSubscribe?() }
        addSubview(subscribeButton)

        shareButton.translatesAutoresizingMaskIntoConstraints = false
        shareButton.accessibilityLabel = "Share Link"
        shareButton.addTarget(self, action: #selector(handleShare), for: .touchUpInside)
        addSubview(shareButton)

        NSLayoutConstraint.activate([
            artworkView.centerXAnchor.constraint(equalTo: centerXAnchor),
            artworkView.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.xl),
            artworkView.widthAnchor.constraint(equalToConstant: MusicMetrics.artistHeroSize),
            artworkView.heightAnchor.constraint(equalToConstant: MusicMetrics.artistHeroSize),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.screenMargin),
            nameLabel.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: FlowSpacing.lg),

            metadataLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            metadataLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: FlowSpacing.xs),

            playButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            playButton.topAnchor.constraint(equalTo: metadataLabel.bottomAnchor, constant: FlowSpacing.xl),
            playButton.heightAnchor.constraint(equalToConstant: 44.0),

            shuffleButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: FlowSpacing.md),
            shuffleButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            shuffleButton.heightAnchor.constraint(equalToConstant: 44.0),

            shareButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.md),
            shareButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            shareButton.widthAnchor.constraint(equalToConstant: 44.0),
            shareButton.heightAnchor.constraint(equalToConstant: 44.0),

            subscribeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            subscribeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.screenMargin),
            subscribeButton.topAnchor.constraint(equalTo: playButton.bottomAnchor, constant: FlowSpacing.md),
            subscribeButton.heightAnchor.constraint(equalToConstant: 44.0),
            subscribeButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.lg),
        ])
        applyTheme()
    }

    /// Fills the hero from the page.
    func configure(page: ArtistPage, isSubscribed: Bool) {
        artworkView.setImage(url: page.artist.thumbnailUrl)
        nameLabel.text = page.artist.title
        metadataLabel.text = MusicFormat.metadata([page.subscriberCountText, page.monthlyListenersText])
        setSubscribed(isSubscribed)
        accessibilityLabel = page.artist.title
    }

    /// Shows the subscription state on the button.
    func setSubscribed(_ subscribed: Bool) {
        subscribeButton.configure(
            title: subscribed ? "Subscribed" : "Subscribe",
            style: subscribed ? .tonal : .outlined
        )
    }

    /// Repaints the hero in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        nameLabel.textColor = scheme.onSurface
        metadataLabel.textColor = scheme.onSurfaceVariant
        shareButton.setIconColor(scheme.onSurface)
        playButton.applyTheme()
        shuffleButton.applyTheme()
        subscribeButton.applyTheme()
        artworkView.applyTheme()
    }

    @objc private func handleShare() {
        onShare?()
    }
}

// MARK: - Bio

/// The artist's description, clamped to three lines with a Show more toggle.
final class ArtistBioView: UIView {

    private let label = UILabel()
    private let toggleButton = UIButton(type: .system)
    private var isExpanded = false
    private var fullText: String = ""

    /// Called when the toggle is tapped, after the state changed.
    var onToggle: (() -> Void)?

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

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FlowTypography.bodyMedium
        label.numberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.titleLabel?.font = FlowTypography.labelLarge
        toggleButton.contentHorizontalAlignment = .leading
        toggleButton.addTarget(self, action: #selector(handleToggle), for: .touchUpInside)
        addSubview(toggleButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.screenMargin),
            label.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.md),

            toggleButton.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            toggleButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: FlowSpacing.xs),
            toggleButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.sm),
            toggleButton.heightAnchor.constraint(equalToConstant: 32.0),
        ])
        applyTheme()
    }

    /// Sets the description. A short one hides the toggle.
    func configure(text: String) {
        fullText = text
        isExpanded = false
        label.numberOfLines = 3
        label.text = text
        toggleButton.isHidden = text.count < 180
        toggleButton.setTitle("Show more", for: .normal)
    }

    /// Repaints the bio in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        label.textColor = scheme.onSurfaceVariant
        toggleButton.setTitleColor(scheme.primary, for: .normal)
    }

    @objc private func handleToggle() {
        isExpanded = !isExpanded
        label.numberOfLines = isExpanded ? 0 : 3
        toggleButton.setTitle(isExpanded ? "Show less" : "Show more", for: .normal)
        onToggle?()
    }
}

// MARK: - Artist page

/// An artist's page: the round portrait, the top songs, then the shelves YouTube groups around
/// them — albums, singles, featured-on appearances, videos and related artists.
///
/// The page's shelves are whatever the response carries, in its order; the top songs are lifted
/// out of their shelf and drawn as full-width rows, because that is the part of the page a viewer
/// came for.
final class ArtistViewController: UIViewController {

    // MARK: - State

    private enum Row {
        case bio(String)
        case songHeader(String)
        case song(SongItem)
        case carousel(ArtistSection)
    }

    private let artistId: String
    private let api: YouTubeAPI
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let heroView = ArtistHeroView()
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")

    private var page: ArtistPage?
    private var rows: [Row] = []
    private var topSongs: [SongItem] = []
    private var isSubscribed = false
    private var isLoading = false
    private var themeToken: ObservationToken?
    private var subscriptionsToken: ObservationToken?

    // MARK: - Construction

    init(artistId: String, api: YouTubeAPI = YouTubeAPI()) {
        self.artistId = artistId
        self.api = api
        super.init(nibName: nil, bundle: nil)
        title = "Artist"
    }

    required init?(coder: NSCoder) {
        artistId = ""
        api = YouTubeAPI()
        super.init(coder: coder)
        title = "Artist"
    }

    deinit {
        themeToken?.cancelObservation()
        subscriptionsToken?.cancelObservation()
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
        subscriptionsToken = FlowEventBus.shared.on("subscriptions") { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.refreshSubscriptionState()
            }
        }
        applyTheme()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        refreshSubscriptionState()
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
        heroView.onPlay = { [weak self] in self?.playTopSongs(shuffle: false) }
        heroView.onShuffle = { [weak self] in self?.playTopSongs(shuffle: true) }
        heroView.onSubscribe = { [weak self] in self?.toggleSubscription() }
        heroView.onShare = { [weak self] in self?.shareArtist() }

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

    // MARK: - Loading

    private func load(force: Bool = false) {
        if isLoading && !force { return }
        isLoading = true
        errorState.isHidden = true
        if page == nil {
            spinner.startAnimating()
        }

        api.artist(id: artistId) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoading = false
                self.spinner.stopAnimating()
                switch result {
                case .success(let page):
                    self.page = page
                    self.rebuildRows(page)
                case .failure(let error):
                    if self.page == nil {
                        self.errorState.isHidden = false
                        self.errorState.configure(
                            kind: .custom(icon: .wifi, title: "Couldn't load this artist", message: error.displayMessage),
                            actionTitle: "Retry"
                        )
                    } else {
                        FlowSnackbar.showError(error.displayMessage)
                    }
                }
            }
        }
    }

    /// Splits the page into the rows the table draws: the hero, the bio, the top songs, then one
    /// carousel per remaining shelf.
    private func rebuildRows(_ page: ArtistPage) {
        var newRows: [Row] = []
        if let description = page.description, !description.isEmpty {
            newRows.append(.bio(description))
        }

        var remaining: [ArtistSection] = []
        var songs: [SongItem] = []
        var songsTitle = "Popular"
        for section in page.sections {
            let sectionSongs = section.items.compactMap { item -> SongItem? in
                if case .song(let song) = item { return song }
                return nil
            }
            // The first all-song shelf is the top songs; a later one is a themed shelf and keeps
            // its carousel, because its title is what tells the viewer why those songs are there.
            if songs.isEmpty, !sectionSongs.isEmpty, sectionSongs.count == section.items.count {
                songs = sectionSongs
                songsTitle = section.title.isEmpty ? "Popular" : section.title
            } else {
                remaining.append(section)
            }
        }

        topSongs = songs
        if !songs.isEmpty {
            newRows.append(.songHeader(songsTitle))
            for song in songs {
                newRows.append(.song(song))
            }
        }
        for section in remaining {
            newRows.append(.carousel(section))
        }

        rows = newRows
        errorState.isHidden = true
        heroView.configure(page: page, isSubscribed: currentSubscriptionState())
        sizeHeader()
        tableView.reloadData()
    }

    /// The hero is a table header, so it has to be measured by hand whenever the width changes.
    private func sizeHeader() {
        guard page != nil else {
            tableView.tableHeaderView = nil
            return
        }
        let width = tableView.bounds.width
        guard width > 0.0 else { return }
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let height = heroView.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard height > 0.0 else { return }
        guard tableView.tableHeaderView?.frame.height != height || tableView.tableHeaderView?.frame.width != width else {
            return
        }
        heroView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableView.tableHeaderView = heroView
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeader()
    }

    // MARK: - Actions

    private func playTopSongs(shuffle: Bool) {
        guard !topSongs.isEmpty else {
            FlowSnackbar.showError("This artist has no songs here")
            return
        }
        let songs = shuffle ? topSongs.shuffled() : topSongs
        MusicItemRouter.play(songs: songs, startIndex: 0, title: page?.artist.title, from: self)
    }

    private func currentSubscriptionState() -> Bool {
        guard let channelId = subscriptionChannelId else { return false }
        return SubscriptionStore.shared.isSubscribed(channelId)
    }

    /// The channel a subscription is stored against: the artist's channel id when YouTube names
    /// one, otherwise the artist's own browse id, which is the only stable identity the page has.
    private var subscriptionChannelId: String? {
        guard let page = page else { return nil }
        if let channelId = page.artist.channelId, !channelId.isEmpty { return channelId }
        return page.artist.id.isEmpty ? nil : page.artist.id
    }

    private func refreshSubscriptionState() {
        isSubscribed = currentSubscriptionState()
        heroView.setSubscribed(isSubscribed)
    }

    private func toggleSubscription() {
        guard let page = page, let channelId = subscriptionChannelId else { return }
        let nowSubscribed = SubscriptionStore.shared.toggle(
            channelId: channelId,
            name: page.artist.title,
            avatarUrl: page.artist.thumbnailUrl,
            subscriberCount: ArtistViewController.subscriberCount(page.subscriberCountText)
        )
        isSubscribed = nowSubscribed
        heroView.setSubscribed(nowSubscribed)
        FlowSnackbar.show(nowSubscribed ? "Subscribed to " + page.artist.title : "Unsubscribed from " + page.artist.title)
    }

    /// YouTube sends the subscriber count as display text; only the leading number is stored.
    private static func subscriberCount(_ text: String?) -> Int {
        guard let text = text else { return 0 }
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        guard let value = Int(digits) else { return 0 }
        if text.lowercased().contains("m") { return value * 1_000_000 }
        if text.lowercased().contains("k") { return value * 1_000 }
        return value
    }

    private func shareArtist() {
        guard let page = page, let url = URL(string: page.artist.shareURL) else { return }
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

    private func openSong(_ song: SongItem) {
        guard let index = topSongs.firstIndex(where: { $0.id == song.id }) else {
            MusicItemRouter.play(songs: [song], startIndex: 0, title: page?.artist.title, from: self)
            return
        }
        MusicItemRouter.play(songs: topSongs, startIndex: index, title: page?.artist.title, from: self)
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
        if let albumId = song.albumId, !albumId.isEmpty {
            actions.append(FlowActionSheetContent.Action(title: "View Album", icon: .playlist) { [weak self] in
                guard let self = self else { return }
                MusicItemRouter.openAlbum(id: albumId, from: self, api: self.api)
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
        heroView.applyTheme()
        tableView.reloadData()
    }

    // MARK: - Carousels

    private func cards(for section: ArtistSection) -> [UIView] {
        var views: [UIView] = []
        for item in section.items {
            var circular = false
            if case .artist = item { circular = true }
            let card = MusicCollectionCardView(circularArtwork: circular)
            card.configure(
                title: item.title,
                subtitle: ArtistViewController.subtitle(for: item),
                artworkUrl: item.thumbnailUrl,
                isExplicit: item.isExplicit
            )
            card.onTap = { [weak self] in
                guard let self = self else { return }
                MusicItemRouter.open(item, from: self, api: self.api)
            }
            views.append(card)
        }
        return views
    }

    private static func subtitle(for item: MusicItem) -> String? {
        switch item {
        case .song(let song):
            return song.artistLine
        case .album(let album):
            return album.artistLine.isEmpty ? MusicFormat.year(album.year) : album.artistLine
        case .playlist(let playlist):
            return playlist.authorName ?? playlist.songCountText
        case .artist(let artist):
            return artist.subscriberCountText
        }
    }
}

// MARK: - Data source

extension ArtistViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let row = rows.element(at: indexPath.row) else {
            return UITableViewCell()
        }
        switch row {
        case .bio(let text):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            let bio = ArtistBioView()
            bio.configure(text: text)
            bio.applyTheme()
            cell.contentView.addSubviewForAutoLayout(bio)
            NSLayoutConstraint.activate([
                bio.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                bio.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                bio.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                bio.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
            ])
            return cell

        case .songHeader(let title):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            let header = FlowSectionHeader.make(title: title)
            header.applyTheme()
            cell.contentView.addSubviewForAutoLayout(header)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
                header.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
                header.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                header.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
            ])
            return cell

        case .song(let song):
            let cell = tableView.dequeueReusableCell(withIdentifier: MusicTrackRowCell.reuseIdentifier, for: indexPath)
            guard let trackCell = cell as? MusicTrackRowCell else { return cell }
            trackCell.onMenu = { [weak self] in self?.showSongMenu(song) }
            trackCell.configure(
                position: nil,
                title: song.title,
                subtitle: MusicFormat.metadata([song.artistLine, song.albumName]),
                artworkUrl: song.thumbnailUrl,
                duration: TimeInterval(song.duration ?? 0),
                isDownloaded: DownloadStore.shared.isDownloaded(videoId: song.id)
            )
            trackCell.applyTheme()
            return trackCell

        case .carousel(let section):
            let cell = tableView.dequeueReusableCell(withIdentifier: MusicCarouselCell.reuseIdentifier, for: indexPath)
            guard let carouselCell = cell as? MusicCarouselCell else { return cell }
            carouselCell.carousel.configure(title: section.title)
            carouselCell.carousel.setItems(cards(for: section))
            carouselCell.carousel.applyTheme()
            return carouselCell
        }
    }
}

// MARK: - Delegate

extension ArtistViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let row = rows.element(at: indexPath.row) else { return 0.0 }
        switch row {
        case .bio: return UITableView.automaticDimension
        case .songHeader: return 52.0
        case .song: return MusicMetrics.trackRowHeight
        case .carousel: return MusicMetrics.carouselRowHeight
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = rows.element(at: indexPath.row) else { return }
        if case .song(let song) = row {
            openSong(song)
        }
    }
}

// MARK: - Prefetching

extension ArtistViewController: UITableViewDataSourcePrefetching {

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        var urls: [String] = []
        for indexPath in indexPaths {
            guard let row = rows.element(at: indexPath.row) else { continue }
            switch row {
            case .song(let song):
                urls.append(song.thumbnailUrl)
            case .carousel(let section):
                urls.append(contentsOf: section.items.map { $0.thumbnailUrl })
            default:
                break
            }
        }
        ImageLoader.shared.prefetch(urls)
    }
}

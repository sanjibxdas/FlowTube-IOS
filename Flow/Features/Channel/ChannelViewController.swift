import UIKit

/// A channel's page: banner, avatar, name, subscriber count, subscribe button and the tabs the
/// channel exposes (Home, Videos, Shorts, Playlists, About).
///
/// The header scrolls with the content, like the Android screen, and the tab row stays pinned under
/// the navigation bar so the viewer can switch tabs from anywhere in a long grid.
final class ChannelViewController: UIViewController {

    // MARK: - Navigation

    /// Called with the video the viewer picked.
    var onOpenVideo: ((Video) -> Void)?
    /// Called with the playlist id the viewer picked.
    var onOpenPlaylist: ((String) -> Void)?
    /// Called when the viewer opens the channel's Shorts reel.
    var onOpenShorts: ((String) -> Void)?

    // MARK: - State

    private let channelId: String
    private let api: YouTubeAPI
    private let headerView = ChannelHeaderView()
    private let tabs = FlowSegmentedTabs()
    private let collectionView: UICollectionView
    private let layout = UICollectionViewFlowLayout()
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")
    private let emptyState = FlowEmptyState.make(kind: .noResults)
    private let sortButton = FlowIconButton.make(.sort, color: .clear, size: 22.0, target: nil, action: nil)

    private var page: ChannelPage?
    private var tabTitles: [String] = []
    private var tabKinds: [ChannelTabKind] = []
    private var selectedTab = 0
    private var items: [ChannelItem] = []
    private var isLoading = false
    private var sort: ChannelSort = .newest
    private var headerHeight: CGFloat = 0.0
    private var themeToken: ObservationToken?

    /// The tabs the screen can draw. YouTube's own tab list is server-driven; these are the ones
    /// the Android screen keeps, and they are matched to the response's tabs by title.
    enum ChannelTabKind {
        case home
        case videos
        case shorts
        case playlists
        case about
    }

    /// The order the Android screen sorts a channel's videos by.
    enum ChannelSort: Int, CaseIterable {
        case newest
        case oldest
        case popular

        var title: String {
            switch self {
            case .newest: return "Newest"
            case .oldest: return "Oldest"
            case .popular: return "Most popular"
            }
        }
    }

    /// One row of the selected tab.
    enum ChannelItem {
        case video(Video)
        case shelf(VideoShelf)
        case playlist(Playlist)
        case about
    }

    // MARK: - Construction

    init(channelId: String, api: YouTubeAPI = YouTubeAPI()) {
        self.channelId = channelId
        self.api = api
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        channelId = ""
        api = YouTubeAPI()
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(coder: coder)
    }

    deinit {
        themeToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildCollection()
        buildChrome()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        headerView.refreshSubscription()
    }

    // MARK: - Build

    private func buildCollection() {
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = FlowSpacing.lg
        layout.minimumLineSpacing = FlowSpacing.xl
        layout.sectionInset = UIEdgeInsets(top: FlowSpacing.md, left: FlowSpacing.screenMargin, bottom: FlowSpacing.xxl, right: FlowSpacing.screenMargin)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(ChannelVideoCell.self, forCellWithReuseIdentifier: ChannelVideoCell.reuseIdentifier)
        collectionView.register(ChannelShelfCell.self, forCellWithReuseIdentifier: ChannelShelfCell.reuseIdentifier)
        collectionView.register(ChannelPlaylistCell.self, forCellWithReuseIdentifier: ChannelPlaylistCell.reuseIdentifier)
        collectionView.register(ChannelAboutCell.self, forCellWithReuseIdentifier: ChannelAboutCell.reuseIdentifier)
        view.addSubview(collectionView)

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.onSubscribe = { [weak self] in self?.toggleSubscription() }
        headerView.onOpenShorts = { [weak self] in
            guard let self = self else { return }
            self.onOpenShorts?(self.channelId)
        }
        view.addSubview(headerView)

        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.onSelect = { [weak self] index in
            self?.selectTab(index)
        }
        view.addSubview(tabs)

        sortButton.translatesAutoresizingMaskIntoConstraints = false
        sortButton.accessibilityLabel = "Playlist sort options"
        sortButton.addTarget(self, action: #selector(handleSort), for: .touchUpInside)
        sortButton.isHidden = true
        view.addSubview(sortButton)

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
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: view.topAnchor),

            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor),
            tabs.topAnchor.constraint(equalTo: headerView.bottomAnchor),

            sortButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.sm),
            sortButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            sortButton.widthAnchor.constraint(equalToConstant: 40.0),

            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorState.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            errorState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildChrome() {
        // The header is sized by its own content; this only gives the collection a top inset that
        // matches it once the page arrives.
        headerView.isHidden = true
        tabs.isHidden = true
    }

    // MARK: - Loading

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        errorState.isHidden = true
        if page == nil {
            spinner.startAnimating()
        }
        api.channel(id: channelId) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoading = false
                self.spinner.stopAnimating()
                switch result {
                case .success(let page):
                    self.apply(page: page)
                case .failure(let error):
                    self.errorState.isHidden = false
                    self.errorState.configure(
                        kind: .custom(icon: .wifi, title: "Couldn't load this channel", message: error.displayMessage),
                        actionTitle: "Retry"
                    )
                }
            }
        }
    }

    private func apply(page: ChannelPage) {
        self.page = page
        headerView.configure(with: page.channel)
        headerView.isHidden = false
        tabs.isHidden = false
        buildTabs(from: page)
        selectTab(0)
        collectionView.reloadData()
    }

    private func buildTabs(from page: ChannelPage) {
        var kinds: [ChannelTabKind] = []
        var titles: [String] = []
        let available = page.tabs.map { $0.title.lowercased() }
        let has = { (name: String) -> Bool in
            return available.contains(name)
        }
        if has("home") || !page.homeSections.isEmpty {
            kinds.append(.home)
            titles.append("Home")
        }
        if has("videos") || has("video") || !page.videos.isEmpty {
            kinds.append(.videos)
            titles.append("Videos")
        }
        if has("shorts") || !page.shorts.isEmpty {
            kinds.append(.shorts)
            titles.append("Shorts")
        }
        if has("playlists") || !page.playlists.isEmpty {
            kinds.append(.playlists)
            titles.append("Playlists")
        }
        kinds.append(.about)
        titles.append("About")
        tabKinds = kinds
        tabTitles = titles
        tabs.setTitles(titles, selectedIndex: 0)
    }

    private func selectTab(_ index: Int) {
        guard let kind = tabKinds.element(at: index), let page = page else { return }
        selectedTab = index
        sortButton.isHidden = kind != .videos
        var built: [ChannelItem] = []
        switch kind {
        case .home:
            for shelf in page.homeSections where !shelf.items.isEmpty {
                built.append(.shelf(shelf))
            }
            if built.isEmpty {
                for video in page.videos {
                    built.append(.video(video))
                }
            }
        case .videos:
            for video in sorted(page.videos) {
                built.append(.video(video))
            }
        case .shorts:
            for video in page.shorts {
                built.append(.video(video))
            }
        case .playlists:
            for playlist in page.playlists {
                built.append(.playlist(playlist))
            }
        case .about:
            built.append(.about)
        }
        items = built
        emptyState.isHidden = !items.isEmpty
        if items.isEmpty {
            emptyState.configure(kind: .custom(
                icon: .subscriptions,
                title: "Nothing here yet",
                message: "This channel has not published anything in this tab."
            ))
        }
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
    }

    private func sorted(_ videos: [Video]) -> [Video] {
        switch sort {
        case .newest:
            return videos.sorted { $0.timestamp > $1.timestamp }
        case .oldest:
            return videos.sorted { $0.timestamp < $1.timestamp }
        case .popular:
            return videos.sorted { $0.viewCount > $1.viewCount }
        }
    }

    // MARK: - Actions

    private func toggleSubscription() {
        guard let channel = page?.channel else { return }
        let subscribed = SubscriptionStore.shared.toggle(
            channelId: channel.id,
            name: channel.name,
            avatarUrl: channel.thumbnailUrl,
            subscriberCount: Int(channel.subscriberCount)
        )
        headerView.setSubscribed(subscribed)
        FlowSnackbar.show(subscribed ? "Subscribed to " + channel.name : "Unsubscribed from " + channel.name)
    }

    @objc private func handleSort() {
        let actions = ChannelSort.allCases.map { option in
            FlowActionSheetContent.Action(title: option.title, icon: option == sort ? .check : nil) { [weak self] in
                guard let self = self else { return }
                self.sort = option
                self.selectTab(self.selectedTab)
            }
        }
        let content = FlowActionSheetContent(actions: actions)
        let sheet = FlowSheet(content: content, title: "Sort by", detent: .medium, showsGrabber: true)
        content.onActionSelected = { [weak sheet] in sheet?.dismissSheet() }
        sheet.present(from: self)
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        sortButton.setIconColor(scheme.onSurface)
        tabs.applyTheme()
        headerView.applyTheme()
        errorState.applyTheme()
        emptyState.applyTheme()
        collectionView.reloadData()
    }
}

// MARK: - Data source

extension ChannelViewController: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let item = items.element(at: indexPath.item) else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: ChannelVideoCell.reuseIdentifier, for: indexPath)
        }
        switch item {
        case .video(let video):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ChannelVideoCell.reuseIdentifier, for: indexPath)
            if let videoCell = cell as? ChannelVideoCell {
                videoCell.configure(with: video)
            }
            return cell
        case .shelf(let shelf):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ChannelShelfCell.reuseIdentifier, for: indexPath)
            if let shelfCell = cell as? ChannelShelfCell {
                shelfCell.configure(shelf: shelf)
                shelfCell.onSelect = { [weak self] video in self?.onOpenVideo?(video) }
            }
            return cell
        case .playlist(let playlist):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ChannelPlaylistCell.reuseIdentifier, for: indexPath)
            if let playlistCell = cell as? ChannelPlaylistCell {
                playlistCell.configure(with: playlist)
            }
            return cell
        case .about:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ChannelAboutCell.reuseIdentifier, for: indexPath)
            if let aboutCell = cell as? ChannelAboutCell, let channel = page?.channel {
                aboutCell.configure(with: channel)
            }
            return cell
        }
    }
}

// MARK: - Delegate

extension ChannelViewController: UICollectionViewDelegateFlowLayout {

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = collectionView.bounds.width
        guard let item = items.element(at: indexPath.item) else { return .zero }
        switch item {
        case .video:
            let available = width - FlowSpacing.screenMargin * 2.0
            let itemWidth = floor((available - FlowSpacing.lg) / 2.0)
            return CGSize(width: itemWidth, height: ChannelVideoCell.height(for: itemWidth))
        case .shelf:
            return CGSize(width: width - FlowSpacing.screenMargin * 2.0, height: ChannelShelfCell.height)
        case .playlist:
            let available = width - FlowSpacing.screenMargin * 2.0
            let itemWidth = floor((available - FlowSpacing.lg) / 2.0)
            return CGSize(width: itemWidth, height: ChannelPlaylistCell.height(for: itemWidth))
        case .about:
            return CGSize(width: width - FlowSpacing.screenMargin * 2.0, height: ChannelAboutCell.height)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = items.element(at: indexPath.item) else { return }
        switch item {
        case .video(let video):
            onOpenVideo?(video)
        case .playlist(let playlist):
            onOpenPlaylist?(playlist.id)
        case .shelf, .about:
            break
        }
    }
}

// MARK: - Prefetching

extension ChannelViewController: UICollectionViewDataSourcePrefetching {

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        var urls: [String] = []
        for indexPath in indexPaths {
            guard let item = items.element(at: indexPath.item) else { continue }
            switch item {
            case .video(let video):
                urls.append(video.thumbnailUrl)
            case .shelf(let shelf):
                urls.append(contentsOf: shelf.items.map { $0.thumbnailUrl })
            case .playlist(let playlist):
                urls.append(playlist.thumbnailUrl)
            case .about:
                break
            }
        }
        ImageLoader.shared.prefetch(urls)
    }
}

// MARK: - Header

/// The channel's banner, avatar, name, handle, subscriber count and subscribe button.
final class ChannelHeaderView: UIView {

    private let bannerView = AsyncImageView()
    private let avatarView = AsyncImageView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let subscribeButton = FlowButton.make("Subscribe", style: .filled)
    private let shortsButton = FlowButton.make("Shorts", style: .tonal, icon: .shorts)
    private var channel: Channel?

    /// Called when the subscribe button is tapped.
    var onSubscribe: (() -> Void)?
    /// Called when the Shorts button is tapped.
    var onOpenShorts: (() -> Void)?

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
        backgroundColor = .clear

        bannerView.translatesAutoresizingMaskIntoConstraints = false
        bannerView.contentMode = .scaleAspectFill
        bannerView.clipsToBounds = true
        bannerView.accessibilityLabel = "Channel banner"
        addSubview(bannerView)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.applyCornerRadius(36.0)
        avatarView.accessibilityLabel = "Channel avatar"
        addSubview(avatarView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = FlowTypography.headlineSmall
        nameLabel.numberOfLines = 2
        addSubview(nameLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodyMedium
        detailLabel.numberOfLines = 2
        addSubview(detailLabel)

        subscribeButton.translatesAutoresizingMaskIntoConstraints = false
        subscribeButton.onTap = { [weak self] in self?.onSubscribe?() }
        addSubview(subscribeButton)

        shortsButton.translatesAutoresizingMaskIntoConstraints = false
        shortsButton.onTap = { [weak self] in self?.onOpenShorts?() }
        addSubview(shortsButton)

        NSLayoutConstraint.activate([
            bannerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bannerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bannerView.topAnchor.constraint(equalTo: topAnchor),
            bannerView.heightAnchor.constraint(equalToConstant: 112.0),

            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            avatarView.topAnchor.constraint(equalTo: bannerView.bottomAnchor, constant: -FlowSpacing.xxl),
            avatarView.widthAnchor.constraint(equalToConstant: 72.0),
            avatarView.heightAnchor.constraint(equalToConstant: 72.0),

            nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: FlowSpacing.lg),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.screenMargin),
            nameLabel.topAnchor.constraint(equalTo: avatarView.topAnchor, constant: FlowSpacing.xs),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: FlowSpacing.xxs),

            subscribeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            subscribeButton.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: FlowSpacing.lg),
            subscribeButton.heightAnchor.constraint(equalToConstant: 36.0),
            subscribeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 112.0),

            shortsButton.leadingAnchor.constraint(equalTo: subscribeButton.trailingAnchor, constant: FlowSpacing.md),
            shortsButton.centerYAnchor.constraint(equalTo: subscribeButton.centerYAnchor),
            shortsButton.heightAnchor.constraint(equalToConstant: 36.0),

            bottomAnchor.constraint(equalTo: subscribeButton.bottomAnchor, constant: FlowSpacing.lg),
        ])
        applyTheme()
    }

    /// Fills the header from a channel.
    func configure(with channel: Channel) {
        self.channel = channel
        nameLabel.text = channel.name.isEmpty ? "Channel" : channel.name
        bannerView.setImage(url: channel.bannerUrl)
        avatarView.setImage(url: channel.thumbnailUrl)

        var parts: [String] = []
        if !channel.handle.isEmpty {
            parts.append(channel.handle.hasPrefix("@") ? channel.handle : "@" + channel.handle)
        }
        if !channel.subscriberCountText.isEmpty {
            parts.append(channel.subscriberCountText)
        } else if channel.subscriberCount > 0 {
            parts.append(Formatters.subscriberCount(Int(channel.subscriberCount)) + " subscribers")
        }
        if channel.videoCount > 0 {
            parts.append(String(channel.videoCount) + " videos")
        }
        detailLabel.text = parts.joined(separator: " · ")
        refreshSubscription()
    }

    /// Re-reads the local subscription state, which may have changed on another screen.
    func refreshSubscription() {
        guard let channel = channel else { return }
        setSubscribed(SubscriptionStore.shared.isSubscribed(channel.id))
    }

    /// Draws the subscribe button in its subscribed or unsubscribed form.
    func setSubscribed(_ subscribed: Bool) {
        subscribeButton.configure(title: subscribed ? "Subscribed" : "Subscribe", style: subscribed ? .outlined : .filled)
        subscribeButton.accessibilityValue = subscribed ? "Subscribed" : nil
    }

    /// Repaints the header in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        nameLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        subscribeButton.applyTheme()
        shortsButton.applyTheme()
    }
}

// MARK: - Cells

/// One video in a channel's grid.
final class ChannelVideoCell: UICollectionViewCell {

    static let reuseIdentifier = "ChannelVideoCell"

    private let thumbnailView = AsyncImageView()
    private let durationLabel = PaddedLabel()
    private let titleLabel = UILabel()
    private let metadataLabel = UILabel()

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

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.applyCornerRadius(FlowShapes.thumbnail)
        contentView.addSubview(thumbnailView)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = FlowTypography.labelMedium
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

        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.font = FlowTypography.bodySmall
        metadataLabel.numberOfLines = 2
        contentView.addSubview(metadataLabel)

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            thumbnailView.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumbnailView.heightAnchor.constraint(equalTo: thumbnailView.widthAnchor, multiplier: 9.0 / 16.0),

            durationLabel.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: -FlowSpacing.xs),
            durationLabel.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: -FlowSpacing.xs),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: FlowSpacing.md),

            metadataLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            metadataLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),
        ])
        applyTheme()
    }

    /// The height the cell needs for a given width.
    static func height(for width: CGFloat) -> CGFloat {
        return width * 9.0 / 16.0 + 64.0
    }

    /// Fills the cell from a video.
    func configure(with video: Video) {
        titleLabel.text = video.title
        thumbnailView.setImage(url: video.thumbnailUrl)
        durationLabel.text = video.isLive ? "LIVE" : Formatters.durationBadge(TimeInterval(video.duration))
        durationLabel.isHidden = durationLabel.text == nil
        var parts: [String] = []
        if video.viewCount > 0 { parts.append(Formatters.viewCount(Int(video.viewCount))) }
        if !video.uploadDate.isEmpty { parts.append(video.uploadDate) }
        metadataLabel.text = parts.joined(separator: " · ")
        accessibilityLabel = video.title
        applyTheme()
    }

    /// Repaints the cell in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        metadataLabel.textColor = scheme.onSurfaceVariant
    }
}

/// A shelf inside a channel's home tab.
final class ChannelShelfCell: UICollectionViewCell {

    static let reuseIdentifier = "ChannelShelfCell"
    static let height: CGFloat = 44.0 + 240.0 * 9.0 / 16.0 + 66.0

    private let shelf = FlowShelf()

    /// Called with the video the viewer picked.
    var onSelect: ((Video) -> Void)?

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
        shelf.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(shelf)
        NSLayoutConstraint.activate([
            shelf.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            shelf.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            shelf.topAnchor.constraint(equalTo: contentView.topAnchor),
            shelf.heightAnchor.constraint(equalToConstant: ChannelShelfCell.height),
        ])
    }

    /// Fills the shelf.
    func configure(shelf model: VideoShelf) {
        shelf.configure(title: model.title, subtitle: model.subtitle, actionTitle: nil)
        var cards: [UIView] = []
        for video in model.items {
            let card = FlowVideoCard()
            card.cardWidth = 240.0
            card.configure(with: video)
            card.onTap = { [weak self] in self?.onSelect?(video) }
            cards.append(card)
        }
        shelf.setItems(cards)
        shelf.applyTheme()
    }
}

/// One playlist in a channel's playlist tab.
final class ChannelPlaylistCell: UICollectionViewCell {

    static let reuseIdentifier = "ChannelPlaylistCell"

    private let coverView = AsyncImageView()
    private let countLabel = PaddedLabel()
    private let titleLabel = UILabel()

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

        coverView.translatesAutoresizingMaskIntoConstraints = false
        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.applyCornerRadius(FlowShapes.thumbnail)
        contentView.addSubview(coverView)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = FlowTypography.labelMedium
        countLabel.textColor = .white
        countLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        countLabel.layer.cornerRadius = 4.0
        countLabel.layer.masksToBounds = true
        countLabel.textInsets = UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        contentView.addSubview(countLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            coverView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverView.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverView.heightAnchor.constraint(equalTo: coverView.widthAnchor, multiplier: 9.0 / 16.0),

            countLabel.trailingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: -FlowSpacing.xs),
            countLabel.bottomAnchor.constraint(equalTo: coverView.bottomAnchor, constant: -FlowSpacing.xs),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: coverView.bottomAnchor, constant: FlowSpacing.sm),
        ])
        applyTheme()
    }

    /// The height the cell needs for a given width.
    static func height(for width: CGFloat) -> CGFloat {
        return width * 9.0 / 16.0 + 44.0
    }

    /// Fills the cell from a playlist.
    func configure(with playlist: Playlist) {
        titleLabel.text = playlist.name
        coverView.setImage(url: playlist.thumbnailUrl)
        countLabel.text = playlist.videoCount > 0 ? String(playlist.videoCount) : nil
        countLabel.isHidden = countLabel.text == nil
        accessibilityLabel = playlist.name
        applyTheme()
    }

    /// Repaints the cell in the current palette.
    func applyTheme() {
        titleLabel.textColor = FlowTheme.shared.scheme.onSurface
    }
}

/// The About tab: the channel's description and its figures.
final class ChannelAboutCell: UICollectionViewCell {

    static let reuseIdentifier = "ChannelAboutCell"
    static let height: CGFloat = 220.0

    private let descriptionLabel = UILabel()
    private let detailLabel = UILabel()

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

        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = FlowTypography.bodyMedium
        descriptionLabel.numberOfLines = 0
        contentView.addSubview(descriptionLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 0
        contentView.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            descriptionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            descriptionLabel.topAnchor.constraint(equalTo: contentView.topAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: FlowSpacing.lg),
        ])
        applyTheme()
    }

    /// Fills the tab from a channel.
    func configure(with channel: Channel) {
        let text = channel.description.trimmed
        descriptionLabel.text = text.isEmpty ? "Channel information is unavailable" : text
        var parts: [String] = []
        if !channel.handle.isEmpty {
            parts.append("Handle: " + (channel.handle.hasPrefix("@") ? channel.handle : "@" + channel.handle))
        }
        if !channel.subscriberCountText.isEmpty {
            parts.append(channel.subscriberCountText)
        } else if channel.subscriberCount > 0 {
            parts.append(Formatters.subscriberCount(Int(channel.subscriberCount)) + " subscribers")
        }
        if channel.videoCount > 0 {
            parts.append(String(channel.videoCount) + " videos")
        }
        detailLabel.text = parts.joined(separator: "\n")
        applyTheme()
    }

    /// Repaints the cell in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        descriptionLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
    }
}

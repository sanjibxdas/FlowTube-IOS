import UIKit

/// The filters the search screen's sheet edits.
///
/// YouTube's own search dialog encodes every group into one opaque `params` token. The facade
/// exposes only the type token, so the type is sent to the server and the remaining groups are
/// applied to the results on the device — the same narrowing, done locally, which also keeps the
/// filter instant when the viewer changes it without a new request.
struct SearchFilters {

    /// Which kind of result to ask for.
    var type: VideoSearchFilter = .all
    /// How recent a video must be.
    var uploadDate: UploadDate = .any
    /// How long a video may be.
    var duration: Duration = .any
    /// How to order the results.
    var sort: Sort = .relevance

    enum UploadDate: Int, CaseIterable {
        case any
        case today
        case week
        case month
        case year

        var title: String {
            switch self {
            case .any: return "Any"
            case .today: return "Today"
            case .week: return "This week"
            case .month: return "This month"
            case .year: return "This year"
            }
        }

        var seconds: TimeInterval? {
            switch self {
            case .any: return nil
            case .today: return 24 * 60 * 60
            case .week: return 7 * 24 * 60 * 60
            case .month: return 30 * 24 * 60 * 60
            case .year: return 365 * 24 * 60 * 60
            }
        }
    }

    enum Duration: Int, CaseIterable {
        case any
        case short
        case medium
        case long

        var title: String {
            switch self {
            case .any: return "Any"
            case .short: return "Under 4 minutes"
            case .medium: return "4–20 minutes"
            case .long: return "Over 20 minutes"
            }
        }

        func contains(_ seconds: Int) -> Bool {
            switch self {
            case .any: return true
            case .short: return seconds > 0 && seconds < 240
            case .medium: return seconds >= 240 && seconds <= 1200
            case .long: return seconds > 1200
            }
        }
    }

    enum Sort: Int, CaseIterable {
        case relevance
        case uploadDate
        case viewCount

        var title: String {
            switch self {
            case .relevance: return "Relevance"
            case .uploadDate: return "Upload date"
            case .viewCount: return "View count"
            }
        }
    }

    /// Whether the viewer has narrowed anything.
    var isDefault: Bool {
        return type == .all && uploadDate == .any && duration == .any && sort == .relevance
    }

    /// Applies the local groups and the ordering to a page of videos.
    func apply(to videos: [Video]) -> [Video] {
        var result = videos
        if let window = uploadDate.seconds {
            let cutoff = Date().addingTimeInterval(-window)
            result = result.filter { $0.timestamp >= cutoff }
        }
        if duration != .any {
            result = result.filter { duration.contains($0.duration) }
        }
        switch sort {
        case .relevance:
            break
        case .uploadDate:
            result.sort { $0.timestamp > $1.timestamp }
        case .viewCount:
            result.sort { $0.viewCount > $1.viewCount }
        }
        return result
    }
}

/// The result list for one query: channel and playlist shelves, then the videos in a grid or a
/// single column.
///
/// The controller owns loading and paging; the search screen owns the field and the filter sheet.
/// Splitting them keeps the search screen from turning into one object that does everything.
final class SearchResultsController: UIViewController {

    /// Called with the video the viewer picked.
    var onOpenVideo: ((Video) -> Void)?
    /// Called with the channel id the viewer picked.
    var onOpenChannel: ((String) -> Void)?
    /// Called with the playlist id the viewer picked.
    var onOpenPlaylist: ((String) -> Void)?
    /// Called when a page fails while results are already on screen.
    var onPagingFailure: ((String) -> Void)?

    private let api: YouTubeAPI
    private let collectionView: UICollectionView
    private let layout = UICollectionViewFlowLayout()
    private let emptyState = FlowEmptyState.make(kind: .noResults)
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let resultsLabel = UILabel()

    private enum Section {
        case channels([Channel])
        case playlists([Playlist])
        case videos([Video])
    }

    private var sections: [Section] = []
    private var videos: [Video] = []
    private var continuation: String?
    private var isLoading = false
    private var isLoadingMore = false
    private var requestToken = 0

    /// The current query.
    private(set) var query = ""
    /// The filters in effect.
    private(set) var filters = SearchFilters()
    /// Whether results are shown as a grid.
    private(set) var isGrid = true

    private var themeToken: ObservationToken?

    init(api: YouTubeAPI = YouTubeAPI()) {
        self.api = api
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
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
        buildOverlays()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
    }

    // MARK: - Build

    private func buildCollection() {
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = FlowSpacing.lg
        layout.minimumLineSpacing = FlowSpacing.xl
        layout.sectionInset = UIEdgeInsets(top: FlowSpacing.md, left: FlowSpacing.screenMargin, bottom: FlowSpacing.xxl, right: FlowSpacing.screenMargin)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(SearchVideoCell.self, forCellWithReuseIdentifier: SearchVideoCell.reuseIdentifier)
        collectionView.register(SearchChannelShelfCell.self, forCellWithReuseIdentifier: SearchChannelShelfCell.reuseIdentifier)
        collectionView.register(SearchPlaylistShelfCell.self, forCellWithReuseIdentifier: SearchPlaylistShelfCell.reuseIdentifier)
        collectionView.register(
            SearchSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: SearchSectionHeaderView.reuseIdentifier
        )
        view.addSubview(collectionView)

        resultsLabel.translatesAutoresizingMaskIntoConstraints = false
        resultsLabel.font = FlowTypography.bodySmall
        resultsLabel.numberOfLines = 1
        resultsLabel.isHidden = true
        view.addSubview(resultsLabel)

        NSLayoutConstraint.activate([
            resultsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.screenMargin),
            resultsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.screenMargin),
            resultsLabel.topAnchor.constraint(equalTo: view.topAnchor),

            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: resultsLabel.bottomAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildOverlays() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        view.addSubview(emptyState)

        errorState.translatesAutoresizingMaskIntoConstraints = false
        errorState.isHidden = true
        errorState.onAction = { [weak self] in
            guard let self = self else { return }
            self.search(query: self.query, filters: self.filters, force: true)
        }
        view.addSubview(errorState)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: resultsLabel.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            errorState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorState.topAnchor.constraint(equalTo: resultsLabel.bottomAnchor),
            errorState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Searching

    /// Runs a search, replacing whatever is on screen.
    ///
    /// `force` re-runs an identical query, which is what the retry button does.
    func search(query: String, filters: SearchFilters, force: Bool = false) {
        let trimmed = query.trimmed
        guard !trimmed.isEmpty else {
            reset()
            return
        }
        let sameRequest = trimmed == self.query && filters.type == self.filters.type
        if sameRequest && !force && !videos.isEmpty {
            self.filters = filters
            applyLocalFilters()
            return
        }

        self.query = trimmed
        self.filters = filters
        requestToken += 1
        let token = requestToken
        isLoading = true
        isLoadingMore = false
        continuation = nil
        showLoadingState()

        api.search(query: trimmed, filter: filters.type) { [weak self] result in
            guard let self = self, token == self.requestToken else { return }
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let page):
                    self.videos = page.videos
                    self.continuation = page.continuation
                    self.rebuildSections(channels: page.channels, playlists: page.playlists)
                    self.updateResultsLabel(estimated: page.estimatedResults)
                    self.showContentState()
                case .failure(let error):
                    self.videos = []
                    self.sections = []
                    self.showErrorState(error.displayMessage)
                }
            }
        }
    }

    /// Re-applies the local filter groups without a new request.
    func updateFilters(_ newFilters: SearchFilters) {
        let typeChanged = newFilters.type != filters.type
        filters = newFilters
        if typeChanged {
            search(query: query, filters: newFilters, force: true)
        } else {
            applyLocalFilters()
        }
    }

    /// Switches between the grid and the single column.
    func setGrid(_ grid: Bool) {
        guard grid != isGrid else { return }
        isGrid = grid
        layout.invalidateLayout()
        collectionView.reloadData()
    }

    /// Clears the results, for a search field that was emptied.
    func reset() {
        requestToken += 1
        query = ""
        videos = []
        sections = []
        continuation = nil
        isLoading = false
        isLoadingMore = false
        collectionView.reloadData()
        resultsLabel.isHidden = true
        emptyState.isHidden = true
        errorState.isHidden = true
        spinner.stopAnimating()
    }

    /// Scrolls the results back to the top.
    func scrollToTop() {
        guard !sections.isEmpty else { return }
        collectionView.setContentOffset(.zero, animated: true)
    }

    // MARK: - State

    private func rebuildSections(channels: [Channel], playlists: [Playlist]) {
        var built: [Section] = []
        if !channels.isEmpty {
            built.append(.channels(channels))
        }
        if !playlists.isEmpty {
            built.append(.playlists(playlists))
        }
        if !videos.isEmpty {
            built.append(.videos(videos))
        }
        sections = built
        collectionView.reloadData()
    }

    private func applyLocalFilters() {
        guard !sections.isEmpty else { return }
        var channels: [Channel] = []
        var playlists: [Playlist] = []
        for section in sections {
            switch section {
            case .channels(let values): channels = values
            case .playlists(let values): playlists = values
            case .videos: break
            }
        }
        rebuildSections(channels: channels, playlists: playlists)
    }

    private func updateResultsLabel(estimated: Int64?) {
        guard let count = estimated, count > 0 else {
            resultsLabel.isHidden = true
            return
        }
        resultsLabel.text = "About " + Formatters.compactCount(Int(count)) + " results"
        resultsLabel.isHidden = false
    }

    private func showLoadingState() {
        emptyState.isHidden = true
        errorState.isHidden = true
        collectionView.isHidden = true
        spinner.startAnimating()
    }

    private func showContentState() {
        spinner.stopAnimating()
        collectionView.isHidden = sections.isEmpty
        emptyState.isHidden = !sections.isEmpty
        errorState.isHidden = true
        if sections.isEmpty {
            emptyState.configure(kind: .custom(
                icon: .search,
                title: "No results",
                message: "No results found for \"" + query + "\""
            ))
        }
    }

    private func showErrorState(_ message: String) {
        spinner.stopAnimating()
        collectionView.isHidden = true
        emptyState.isHidden = true
        errorState.isHidden = false
        errorState.configure(kind: .custom(icon: .wifi, title: "Search failed", message: message), actionTitle: "Retry")
    }

    private func loadMore() {
        guard let token = continuation, !token.isEmpty, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        api.searchContinuation(token) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoadingMore = false
                switch result {
                case .success(let page):
                    var known = Set(self.videos.map { $0.id })
                    for video in page.videos where !known.contains(video.id) {
                        self.videos.append(video)
                        known.insert(video.id)
                    }
                    self.continuation = page.continuation
                    self.rebuildSections(channels: [], playlists: [])
                case .failure(let error):
                    self.onPagingFailure?(error.displayMessage)
                }
            }
        }
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        resultsLabel.textColor = scheme.onSurfaceVariant
        emptyState.applyTheme()
        errorState.applyTheme()
        collectionView.reloadData()
    }

    // MARK: - Sizing

    private func itemWidth(for width: CGFloat) -> CGFloat {
        let available = width - FlowSpacing.screenMargin * 2.0
        if isGrid {
            return floor((available - FlowSpacing.lg) / 2.0)
        }
        return available
    }
}

// MARK: - Data source

extension SearchResultsController: UICollectionViewDataSource {

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard let sectionValue = sections.element(at: section) else { return 0 }
        switch sectionValue {
        case .channels, .playlists:
            return 1
        case .videos(let values):
            return values.count
        }
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let section = sections.element(at: indexPath.section) else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: SearchVideoCell.reuseIdentifier, for: indexPath)
        }
        switch section {
        case .channels(let channels):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SearchChannelShelfCell.reuseIdentifier, for: indexPath)
            if let shelf = cell as? SearchChannelShelfCell {
                shelf.configure(channels: channels)
                shelf.onSelect = { [weak self] channelId in self?.onOpenChannel?(channelId) }
            }
            return cell
        case .playlists(let playlists):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SearchPlaylistShelfCell.reuseIdentifier, for: indexPath)
            if let shelf = cell as? SearchPlaylistShelfCell {
                shelf.configure(playlists: playlists)
                shelf.onSelect = { [weak self] playlistId in self?.onOpenPlaylist?(playlistId) }
            }
            return cell
        case .videos(let values):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SearchVideoCell.reuseIdentifier, for: indexPath)
            if let videoCell = cell as? SearchVideoCell, let video = values.element(at: indexPath.item) {
                videoCell.configure(with: video)
            }
            return cell
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let view = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: SearchSectionHeaderView.reuseIdentifier,
            for: indexPath
        )
        if let header = view as? SearchSectionHeaderView {
            header.configure(title: "Videos")
        }
        return view
    }
}

// MARK: - Delegate

extension SearchResultsController: UICollectionViewDelegateFlowLayout {

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = collectionView.bounds.width
        guard let section = sections.element(at: indexPath.section) else { return .zero }
        switch section {
        case .channels:
            return CGSize(width: width - FlowSpacing.screenMargin * 2.0, height: SearchChannelShelfCell.height)
        case .playlists:
            return CGSize(width: width - FlowSpacing.screenMargin * 2.0, height: SearchPlaylistShelfCell.height)
        case .videos:
            let itemWidth = self.itemWidth(for: width)
            return CGSize(width: itemWidth, height: SearchVideoCell.height(for: itemWidth))
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        guard let value = sections.element(at: section) else { return .zero }
        if case .videos = value {
            return CGSize(width: collectionView.bounds.width, height: 32.0)
        }
        return .zero
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let section = sections.element(at: indexPath.section) else { return }
        if case .videos(let values) = section, let video = values.element(at: indexPath.item) {
            onOpenVideo?(video)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
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

extension SearchResultsController: UICollectionViewDataSourcePrefetching {

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        var urls: [String] = []
        for indexPath in indexPaths {
            guard let section = sections.element(at: indexPath.section) else { continue }
            switch section {
            case .videos(let values):
                if let video = values.element(at: indexPath.item) {
                    urls.append(video.thumbnailUrl)
                }
            case .channels(let values):
                urls.append(contentsOf: values.map { $0.thumbnailUrl })
            case .playlists(let values):
                urls.append(contentsOf: values.map { $0.thumbnailUrl })
            }
        }
        ImageLoader.shared.prefetch(urls)
    }
}

// MARK: - Video cell

/// One video result. In the grid it is a narrow card; in the list it is a full-width row. The same
/// cell serves both because only its width changes.
final class SearchVideoCell: UICollectionViewCell {

    static let reuseIdentifier = "SearchVideoCell"

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
        return width * 9.0 / 16.0 + 66.0
    }

    /// Fills the cell from a video.
    func configure(with video: Video) {
        titleLabel.text = video.title
        thumbnailView.setImage(url: video.thumbnailUrl)
        durationLabel.text = video.isLive ? "LIVE" : Formatters.durationBadge(TimeInterval(video.duration))
        durationLabel.isHidden = durationLabel.text == nil

        var parts: [String] = []
        if !video.channelName.isEmpty { parts.append(video.channelName) }
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

// MARK: - Channel shelf

/// A horizontal row of channel results.
final class SearchChannelShelfCell: UICollectionViewCell {

    static let reuseIdentifier = "SearchChannelShelfCell"
    static let height: CGFloat = 44.0 + 104.0

    private let header = FlowSectionHeader.make(title: "Channels")
    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    /// Called with the channel id the viewer picked.
    var onSelect: ((String) -> Void)?

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

        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        contentView.addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = FlowSpacing.xl
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            header.topAnchor.constraint(equalTo: contentView.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 104.0),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    /// Fills the shelf with channels.
    func configure(channels: [Channel]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for channel in channels {
            let card = ChannelChipView()
            card.configure(with: channel)
            card.onTap = { [weak self] in self?.onSelect?(channel.id) }
            stack.addArrangedSubview(card)
        }
        header.applyTheme()
    }
}

/// One channel in a horizontal shelf: a round avatar, the name and the subscriber count.
final class ChannelChipView: UIControl {

    private let avatarView = AsyncImageView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()

    /// Called when the chip is tapped.
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
        widthAnchor.constraint(equalToConstant: 96.0).isActive = true

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.applyCornerRadius(32.0)
        addSubview(avatarView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = FlowTypography.titleSmall
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 1
        addSubview(nameLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 1
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            avatarView.centerXAnchor.constraint(equalTo: centerXAnchor),
            avatarView.topAnchor.constraint(equalTo: topAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 64.0),
            avatarView.heightAnchor.constraint(equalToConstant: 64.0),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameLabel.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: FlowSpacing.sm),

            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: FlowSpacing.xxs),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        accessibilityTraits = .button
        applyTheme()
    }

    /// Fills the chip from a channel.
    func configure(with channel: Channel) {
        nameLabel.text = channel.name
        avatarView.setImage(url: channel.thumbnailUrl)
        if !channel.subscriberCountText.isEmpty {
            detailLabel.text = channel.subscriberCountText
        } else if channel.subscriberCount > 0 {
            detailLabel.text = Formatters.subscriberCount(Int(channel.subscriberCount))
        } else {
            detailLabel.text = nil
        }
        accessibilityLabel = channel.name
    }

    /// Repaints the chip in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        nameLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
    }

    @objc private func handleTap() {
        onTap?()
    }
}

// MARK: - Playlist shelf

/// A horizontal row of playlist results.
final class SearchPlaylistShelfCell: UICollectionViewCell {

    static let reuseIdentifier = "SearchPlaylistShelfCell"
    static let height: CGFloat = 44.0 + 148.0

    private let header = FlowSectionHeader.make(title: "Playlists")
    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    /// Called with the playlist id the viewer picked.
    var onSelect: ((String) -> Void)?

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

        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        contentView.addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = FlowSpacing.lg
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            header.topAnchor.constraint(equalTo: contentView.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 148.0),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    /// Fills the shelf with playlists.
    func configure(playlists: [Playlist]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for playlist in playlists {
            let card = PlaylistChipView()
            card.configure(with: playlist)
            card.onTap = { [weak self] in self?.onSelect?(playlist.id) }
            stack.addArrangedSubview(card)
        }
        header.applyTheme()
    }
}

/// One playlist in a horizontal shelf: a 16:9 cover, the title and the item count.
final class PlaylistChipView: UIControl {

    private let coverView = AsyncImageView()
    private let countLabel = PaddedLabel()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    /// Called when the chip is tapped.
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
        widthAnchor.constraint(equalToConstant: 176.0).isActive = true

        coverView.translatesAutoresizingMaskIntoConstraints = false
        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.applyCornerRadius(FlowShapes.thumbnail)
        addSubview(coverView)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = FlowTypography.labelMedium
        countLabel.textColor = .white
        countLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        countLabel.layer.cornerRadius = 4.0
        countLabel.layer.masksToBounds = true
        countLabel.textInsets = UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        addSubview(countLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 1
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            coverView.leadingAnchor.constraint(equalTo: leadingAnchor),
            coverView.trailingAnchor.constraint(equalTo: trailingAnchor),
            coverView.topAnchor.constraint(equalTo: topAnchor),
            coverView.heightAnchor.constraint(equalTo: coverView.widthAnchor, multiplier: 9.0 / 16.0),

            countLabel.trailingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: -FlowSpacing.xs),
            countLabel.bottomAnchor.constraint(equalTo: coverView.bottomAnchor, constant: -FlowSpacing.xs),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: coverView.bottomAnchor, constant: FlowSpacing.sm),

            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        accessibilityTraits = .button
        applyTheme()
    }

    /// Fills the chip from a playlist.
    func configure(with playlist: Playlist) {
        titleLabel.text = playlist.name
        coverView.setImage(url: playlist.thumbnailUrl)
        countLabel.text = playlist.videoCount > 0 ? String(playlist.videoCount) : nil
        countLabel.isHidden = countLabel.text == nil
        detailLabel.text = playlist.authorName.isEmpty ? "Playlist" : playlist.authorName
        accessibilityLabel = playlist.name
    }

    /// Repaints the chip in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
    }

    @objc private func handleTap() {
        onTap?()
    }
}

// MARK: - Section header

/// The "Videos" header above the video results.
final class SearchSectionHeaderView: UICollectionReusableView {

    static let reuseIdentifier = "SearchSectionHeaderView"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FlowTypography.titleLarge
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.xs),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
    }

    /// Sets the header's title.
    func configure(title: String) {
        label.text = title
        label.font = FlowTypography.titleLarge
        applyTheme()
    }

    /// Repaints the header in the current palette.
    func applyTheme() {
        label.textColor = FlowTheme.shared.scheme.onSurface
    }
}

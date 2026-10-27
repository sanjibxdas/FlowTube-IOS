import UIKit

/// One upload in the subscriptions feed: the video, the moment it arrived and how far the viewer
/// has already watched it.
///
/// The browse response carries no absolute upload timestamp, only YouTube's relative wording
/// ("3 weeks ago"), so `uploadedAt` is derived from that text and falls back to the parse time.
struct SubscriptionFeedItem {
    let video: Video
    let uploadedAt: Date
    let progress: Double
}

/// The Subscriptions tab: the newest uploads from every channel the viewer follows, newest first,
/// grouped under the day they arrived.
///
/// YouTube's browse endpoint has no subscriptions feed the facade exposes, so the feed is assembled
/// the way the Android app's refresh pass assembles it: ask each subscribed channel for its recent
/// uploads, merge the answers, and keep the newest. The requests are bounded and run concurrently,
/// and a channel that fails does not hide the channels that answered.
///
/// Watched progress comes from `HistoryStore`, so a video the viewer already started shows the same
/// bar here as it does in History. The bell in the navigation bar carries the unread count from
/// `NotificationStore` and opens the inbox.
final class SubscriptionsViewController: UIViewController {

    // MARK: - Navigation

    /// Called with the video the viewer picked.
    var onOpenVideo: ((Video) -> Void)?
    /// Called with the channel id whose avatar the viewer tapped.
    var onOpenChannel: ((String) -> Void)?
    /// Called when the viewer asks to find channels to follow.
    var onOpenSearch: (() -> Void)?
    /// Called when the viewer opens the notification inbox.
    var onOpenNotifications: (() -> Void)?

    // MARK: - State

    /// One day's worth of uploads.
    private struct DaySection {
        let day: Date
        var items: [SubscriptionFeedItem]
    }

    private let loader: SubscriptionFeedLoader
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let emptyState = FlowEmptyState.make(
        kind: .custom(
            icon: .subscriptions,
            title: "No Subscriptions Yet",
            message: "Subscribe to channels to see their latest videos here"
        ),
        actionTitle: "Discover channels"
    )
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")
    /// Shown when the viewer does follow channels but none of them has a video the feed could read.
    private let noUploadsState = FlowEmptyState.make(
        kind: .custom(
            icon: .subscriptions,
            title: "No uploads yet",
            message: "New videos from the channels you follow will appear here."
        ),
        actionTitle: "Refresh"
    )
    /// Built without a target: the action is attached once the view is loaded, because a stored
    /// property cannot refer to `self` while the controller is still being initialised.
    private let bellButton: FlowIconButton = {
        let button = FlowIconButton()
        button.configure(icon: .notification, color: .clear, size: 22.0)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private let bellBadge = PaddedLabel()

    private var feed: [SubscriptionFeedItem] = []
    private var sections: [DaySection] = []
    private var tokens: [ObservationToken] = []
    private var isRefreshing = false
    private var pendingRefresh = false
    private var lastRefresh: Date?
    private var lastError: String?

    /// How long a loaded feed is considered fresh. Opening the tab again inside this window shows
    /// the feed already in memory instead of re-requesting every channel.
    private static let freshnessWindow: TimeInterval = 15.0 * 60.0

    // MARK: - Construction

    init(api: YouTubeAPI = FlowApp.shared.youtubeAPI) {
        loader = SubscriptionFeedLoader(api: api)
        super.init(nibName: nil, bundle: nil)
        title = "Subscriptions"
    }

    required init?(coder: NSCoder) {
        loader = SubscriptionFeedLoader(api: FlowApp.shared.youtubeAPI)
        super.init(coder: coder)
        title = "Subscriptions"
    }

    deinit {
        loader.cancel()
        for token in tokens {
            token.cancelObservation()
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildNavigation()
        buildTable()
        buildOverlays()
        observeSignals()
        applyTheme()
        refreshIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateNotificationBadge()
        // A subscription may have been added from a channel page while the tab was away.
        refreshIfNeeded()
    }

    // MARK: - Construction

    private func buildNavigation() {
        bellButton.configure(icon: .notification, color: FlowTheme.shared.scheme.onSurfaceVariant, size: 22.0)
        bellButton.accessibilityLabel = "Notifications"
        bellButton.addTarget(self, action: #selector(handleBell), for: .touchUpInside)
        bellButton.widthAnchor.constraint(equalToConstant: 44.0).isActive = true
        bellButton.heightAnchor.constraint(equalToConstant: 44.0).isActive = true

        bellBadge.translatesAutoresizingMaskIntoConstraints = false
        bellBadge.font = FlowTypography.labelSmall
        bellBadge.textAlignment = .center
        bellBadge.textInsets = UIEdgeInsets(top: 1.0, left: 4.0, bottom: 1.0, right: 4.0)
        bellBadge.layer.cornerRadius = 8.0
        bellBadge.layer.masksToBounds = true
        bellBadge.isHidden = true
        bellButton.addSubview(bellBadge)
        NSLayoutConstraint.activate([
            bellBadge.centerXAnchor.constraint(equalTo: bellButton.trailingAnchor, constant: -9.0),
            bellBadge.centerYAnchor.constraint(equalTo: bellButton.topAnchor, constant: 11.0),
            bellBadge.heightAnchor.constraint(equalToConstant: 16.0),
            bellBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16.0),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: bellButton)
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = FlowTheme.shared.background
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88.0
        tableView.sectionHeaderHeight = 40.0
        tableView.contentInset = UIEdgeInsets(top: 0.0, left: 0.0, bottom: FlowSpacing.xxl, right: 0.0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(SubscriptionFeedCell.self, forCellReuseIdentifier: SubscriptionFeedCell.reuseIdentifier)
        tableView.register(
            HistoryDayHeaderView.self,
            forHeaderFooterViewReuseIdentifier: HistoryDayHeaderView.reuseIdentifier
        )

        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        refreshControl.tintColor = FlowTheme.shared.scheme.onSurfaceVariant
        tableView.refreshControl = refreshControl
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildOverlays() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        emptyState.onAction = { [weak self] in
            self?.openSearch()
        }
        view.addSubview(emptyState)

        errorState.translatesAutoresizingMaskIntoConstraints = false
        errorState.isHidden = true
        errorState.onAction = { [weak self] in
            self?.refresh()
        }
        view.addSubview(errorState)

        noUploadsState.translatesAutoresizingMaskIntoConstraints = false
        noUploadsState.isHidden = true
        noUploadsState.onAction = { [weak self] in
            self?.refresh()
        }
        view.addSubview(noUploadsState)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            errorState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorState.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            errorState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            noUploadsState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            noUploadsState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            noUploadsState.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            noUploadsState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func observeSignals() {
        tokens.append(FlowEventBus.shared.on("subscriptions") { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.refresh()
            }
        })
        tokens.append(FlowEventBus.shared.on("notifications") { [weak self] _ in
            self?.updateNotificationBadge()
        })
        tokens.append(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
        tokens.append(FlowEventBus.shared.on("history") { [weak self] _ in
            // The progress bars read from the history cache, which a playback can change while
            // this tab is in the background.
            guard let self = self, !self.feed.isEmpty else { return }
            DispatchQueue.main.async {
                self.rebuildFeedProgress()
            }
        })
    }

    // MARK: - Loading

    private func refreshIfNeeded() {
        guard SubscriptionStore.shared.count > 0 else {
            feed = []
            rebuildSections()
            updateStates()
            return
        }
        if !feed.isEmpty, let last = lastRefresh, Date().timeIntervalSince(last) < SubscriptionsViewController.freshnessWindow {
            return
        }
        refresh()
    }

    /// Reloads every subscribed channel's uploads. A second call while a refresh is in flight is
    /// remembered and run when the first one finishes, so a subscription change is never lost.
    private func refresh() {
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }
        let subscriptions = SubscriptionStore.shared.all
        guard !subscriptions.isEmpty else {
            feed = []
            lastError = nil
            rebuildSections()
            updateStates()
            refreshControl.endRefreshing()
            return
        }

        isRefreshing = true
        lastError = nil
        setLoading(feed.isEmpty)
        loader.load(channels: subscriptions) { [weak self] result in
            guard let self = self else { return }
            self.isRefreshing = false
            self.setLoading(false)
            self.refreshControl.endRefreshing()

            switch result {
            case .success(let items):
                self.feed = items
                self.lastRefresh = Date()
                self.rebuildSections()
                self.recordUploadNotifications(items)
            case .failure(let error):
                self.lastError = error.displayMessage
                if self.feed.isEmpty {
                    self.errorState.configure(
                        kind: .custom(
                            icon: .wifi,
                            title: "Couldn't load subscriptions",
                            message: error.displayMessage
                        ),
                        actionTitle: "Retry"
                    )
                } else {
                    FlowSnackbar.showError(error.displayMessage)
                }
            }

            self.updateStates()
            if self.pendingRefresh {
                self.pendingRefresh = false
                self.refresh()
            }
        }
    }

    private func setLoading(_ loading: Bool) {
        if loading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }

    /// Rebuilds the day sections from `feed`, which is already newest first.
    private func rebuildSections() {
        var order: [Date] = []
        var buckets: [Date: [SubscriptionFeedItem]] = [:]
        for item in feed {
            let day = item.uploadedAt.startOfDay
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(item)
        }
        sections = order.sorted(by: >).map { DaySection(day: $0, items: buckets[$0] ?? []) }
        tableView.reloadData()
    }

    /// Re-reads the watched fraction for the videos already on screen. Called when history changes
    /// rather than rebuilding the feed, which would drop the day grouping for no reason.
    private func rebuildFeedProgress() {
        let progress = SubscriptionFeedLoader.progressByVideoId()
        feed = feed.map { item in
            SubscriptionFeedItem(
                video: item.video,
                uploadedAt: item.uploadedAt,
                progress: progress[item.video.id] ?? 0.0
            )
        }
        rebuildSections()
    }

    private func updateStates() {
        let hasSubscriptions = SubscriptionStore.shared.count > 0
        let hasContent = !sections.isEmpty
        let failed = hasSubscriptions && !hasContent && lastError != nil
        tableView.isHidden = !hasContent
        emptyState.isHidden = hasSubscriptions || hasContent
        errorState.isHidden = !failed
        noUploadsState.isHidden = !(hasSubscriptions && !hasContent && !failed && lastRefresh != nil)
    }

    /// Hands genuinely new uploads to the inbox.
    ///
    /// Only channels the viewer left notifications on for contribute, and the store seeds itself on
    /// the first successful refresh, so a fresh install does not announce every existing video.
    private func recordUploadNotifications(_ items: [SubscriptionFeedItem]) {
        let enabled = Set(
            SubscriptionStore.shared.all
                .filter { $0.notificationsEnabled }
                .map { $0.channelId }
        )
        let videos = items.map { $0.video }.filter { enabled.contains($0.channelId) }
        NotificationStore.shared.recordNewUploads(videos)
    }

    // MARK: - Theme

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        tableView.backgroundColor = scheme.background
        tableView.refreshControl?.tintColor = scheme.onSurfaceVariant
        spinner.color = scheme.onSurfaceVariant
        emptyState.applyTheme()
        errorState.applyTheme()
        noUploadsState.applyTheme()
        bellButton.setIconColor(scheme.onSurfaceVariant)
        bellBadge.backgroundColor = scheme.error
        bellBadge.textColor = scheme.onError
        for cell in tableView.visibleCells {
            (cell as? SubscriptionFeedCell)?.applyTheme()
        }
        for section in 0..<tableView.numberOfSections {
            (tableView.headerView(forSection: section) as? HistoryDayHeaderView)?.applyTheme()
        }
    }

    private func updateNotificationBadge() {
        let count = NotificationStore.shared.unreadCount
        bellBadge.isHidden = count == 0
        bellBadge.text = count > 9 ? "9+" : "\(count)"
        bellButton.accessibilityLabel = count > 0
            ? "Notifications, \(count) unread"
            : "Notifications"
    }

    // MARK: - Actions

    @objc private func handleRefresh() {
        refresh()
    }

    @objc private func handleBell() {
        openNotifications()
    }

    private func openNotifications() {
        if let handler = onOpenNotifications {
            handler()
            return
        }
        Router.shared.push(NotificationsViewController(), from: self)
    }

    private func openSearch() {
        if let handler = onOpenSearch {
            handler()
            return
        }
        Router.shared.openSearch(query: "")
    }

    private func open(video: Video) {
        if let handler = onOpenVideo {
            handler(video)
            return
        }
        Router.shared.openWatch(videoId: video.id)
    }

    private func open(channelId: String) {
        guard !channelId.isEmpty else { return }
        if let handler = onOpenChannel {
            handler(channelId)
            return
        }
        Router.shared.openChannel(id: channelId)
    }
}

// MARK: - Table data

extension SubscriptionsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections.element(at: section)?.items.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: SubscriptionFeedCell.reuseIdentifier,
            for: indexPath
        )
        guard let row = cell as? SubscriptionFeedCell,
              let section = sections.element(at: indexPath.section),
              let item = section.items.element(at: indexPath.row) else {
            return cell
        }
        let subscription = SubscriptionStore.shared.subscription(for: item.video.channelId)
        row.configure(with: item, subscription: subscription)
        row.onChannelTap = { [weak self] in
            self?.open(channelId: item.video.channelId)
        }
        row.applyTheme()
        return row
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: HistoryDayHeaderView.reuseIdentifier
        ) as? HistoryDayHeaderView, let day = sections.element(at: section)?.day else {
            return nil
        }
        header.configure(title: Formatters.dayHeading(day))
        header.applyTheme()
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 40.0
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = sections.element(at: indexPath.section),
              let item = section.items.element(at: indexPath.row) else { return }
        open(video: item.video)
    }
}

// MARK: - Feed loading

/// Fetches the recent uploads of a set of channels and merges them into one newest-first list.
///
/// Each channel is one browse request. They run a few at a time so a viewer with a hundred
/// subscriptions does not open a hundred sockets at once, and a generation counter makes a refresh
/// that is overtaken by a newer one discard its own results instead of overwriting fresher data.
final class SubscriptionFeedLoader {

    private let api: YouTubeAPI
    private let lock = NSLock()
    private var generation = 0
    private var running = false

    /// The most channels one refresh asks about. The remainder keep their previous rows.
    private static let maximumChannels = 40
    /// The most uploads taken from one channel's page.
    private static let maximumVideosPerChannel = 15
    /// How many channel requests may be in flight together.
    private static let concurrency = 5

    init(api: YouTubeAPI) {
        self.api = api
    }

    /// Whether a load is in flight.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Loads every channel's uploads. The completion runs on the main queue.
    ///
    /// The work is a bounded fan-out rather than a request per channel all at once: a small pool of
    /// workers pulls the next channel off a shared cursor, so at most `concurrency` requests are
    /// open and a slow channel holds up one worker rather than the whole refresh.
    func load(channels: [Subscription], completion: @escaping (Result<[SubscriptionFeedItem], FlowError>) -> Void) {
        let targets = Array(channels.prefix(SubscriptionFeedLoader.maximumChannels))

        lock.lock()
        generation += 1
        let token = generation
        running = !targets.isEmpty
        lock.unlock()

        guard !targets.isEmpty else {
            if Thread.isMainThread {
                completion(.success([]))
            } else {
                DispatchQueue.main.async {
                    completion(.success([]))
                }
            }
            return
        }

        let resultLock = NSLock()
        var collected: [String: Video] = [:]
        var firstError: FlowError?
        var cursor = 0
        let group = DispatchGroup()

        // One worker's turn: claim the next channel, request it, and either finish or take another.
        func drain() {
            resultLock.lock()
            let index = cursor
            cursor += 1
            resultLock.unlock()

            guard index < targets.count, self.isCurrent(token) else {
                group.leave()
                return
            }

            self.api.channel(id: targets[index].channelId) { result in
                resultLock.lock()
                switch result {
                case .success(let page):
                    // A channel whose Videos tab was not the selected one still carries its
                    // uploads in the home shelves, so those stand in when the tab is empty.
                    let uploads = page.videos.isEmpty
                        ? page.homeSections.flatMap { $0.items }
                        : page.videos
                    for video in uploads.prefix(SubscriptionFeedLoader.maximumVideosPerChannel) {
                        if collected[video.id] == nil {
                            collected[video.id] = video
                        }
                    }
                case .failure(let error):
                    if firstError == nil {
                        firstError = error
                    }
                }
                resultLock.unlock()
                drain()
            }
        }

        let workers = min(SubscriptionFeedLoader.concurrency, targets.count)
        for _ in 0..<workers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                drain()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self, self.isCurrent(token) else { return }

            self.lock.lock()
            self.running = false
            self.lock.unlock()

            resultLock.lock()
            let videos = Array(collected.values)
            let error = firstError
            resultLock.unlock()

            if videos.isEmpty, let error = error {
                completion(.failure(error))
                return
            }
            completion(.success(self.makeItems(from: videos)))
        }
    }

    /// Abandons the in-flight load. Its completion will not call back.
    func cancel() {
        lock.lock()
        generation += 1
        running = false
        lock.unlock()
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == token
    }

    /// The watched fraction of every recently watched video, keyed by video id.
    ///
    /// History is the source of truth for "how far in am I", so the feed and the History tab never
    /// disagree about the same video.
    static func progressByVideoId() -> [String: Double] {
        var result: [String: Double] = [:]
        for entry in HistoryStore.shared.recent(limit: 500) where entry.progress > 0.0 {
            result[entry.videoId] = entry.progress
        }
        return result
    }

    /// Sorts the merged videos newest first and attaches the watched fraction.
    private func makeItems(from videos: [Video]) -> [SubscriptionFeedItem] {
        let now = Date()
        let progress = SubscriptionFeedLoader.progressByVideoId()
        var items: [SubscriptionFeedItem] = []
        items.reserveCapacity(videos.count)
        for video in videos {
            let uploadedAt = SubscriptionUploadDate.date(from: video.uploadDate, now: now) ?? video.timestamp
            items.append(SubscriptionFeedItem(
                video: video,
                uploadedAt: uploadedAt,
                progress: progress[video.id] ?? 0.0
            ))
        }
        items.sort { first, second in
            if first.uploadedAt != second.uploadedAt {
                return first.uploadedAt > second.uploadedAt
            }
            return first.video.id < second.video.id
        }
        return items
    }
}

/// Turns YouTube's relative upload wording into a date.
///
/// The browse parser keeps the wording ("3 weeks ago", "Streamed 2 days ago") and stamps the
/// video with the parse time, because the response has no absolute date. Grouping the feed by day
/// needs the real moment, so the wording is read back here. Anything that cannot be read — a
/// scheduled premiere, an empty label — yields nil and the caller falls back to the parse time.
enum SubscriptionUploadDate {

    static func date(from text: String, now: Date = Date()) -> Date? {
        let lower = text.lowercased().trimmed
        guard !lower.isEmpty else { return nil }
        if lower.contains("just now") || lower.contains("moment ago") {
            return now
        }
        if lower.contains("today") {
            return now
        }
        if lower.contains("yesterday") {
            return now.addingTimeInterval(-86_400.0)
        }

        let digits = lower.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        guard let number = Double(digits) else { return nil }

        if lower.contains("second") { return now.addingTimeInterval(-number) }
        if lower.contains("minute") { return now.addingTimeInterval(-number * 60.0) }
        if lower.contains("hour") { return now.addingTimeInterval(-number * 3_600.0) }
        if lower.contains("day") { return now.addingTimeInterval(-number * 86_400.0) }
        if lower.contains("week") { return now.addingTimeInterval(-number * 604_800.0) }
        if lower.contains("month") { return now.addingTimeInterval(-number * 2_592_000.0) }
        if lower.contains("year") { return now.addingTimeInterval(-number * 31_536_000.0) }
        return nil
    }
}

// MARK: - Row

/// One upload: the still with its duration and resume bar, the title, the channel's avatar and
/// name, and the upload date, view count and watched fraction.
final class SubscriptionFeedCell: UITableViewCell {

    static let reuseIdentifier = "SubscriptionFeedCell"

    private static let thumbnailWidth: CGFloat = 112.0
    private static let thumbnailHeight: CGFloat = 63.0
    private static let avatarSize: CGFloat = 20.0

    private let thumbnail = AsyncImageView.make(cornerRadius: FlowShapes.thumbnail)
    private let durationLabel = PaddedLabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let titleLabel = UILabel()
    private let avatarView = AsyncImageView.make(cornerRadius: SubscriptionFeedCell.avatarSize / 2.0)
    private let channelLabel = UILabel()
    private let metaLabel = UILabel()

    private var progressWidth: NSLayoutConstraint?
    private var progress: Double = 0.0

    /// Called when the channel's avatar is tapped.
    var onChannelTap: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .default
        let selected = UIView()
        selected.backgroundColor = FlowTheme.shared.scheme.surfaceContainerHigh
        selectedBackgroundView = selected

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(thumbnail)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = FlowTypography.labelSmall
        durationLabel.textInsets = UIEdgeInsets(top: 1.0, left: 4.0, bottom: 1.0, right: 4.0)
        durationLabel.layer.cornerRadius = FlowShapes.extraSmall
        durationLabel.layer.masksToBounds = true
        contentView.addSubview(durationLabel)

        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.layer.cornerRadius = 1.0
        progressTrack.layer.masksToBounds = true
        contentView.addSubview(progressTrack)

        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.isUserInteractionEnabled = true
        avatarView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleAvatarTap)))
        contentView.addSubview(avatarView)

        channelLabel.translatesAutoresizingMaskIntoConstraints = false
        channelLabel.font = FlowTypography.bodySmall
        channelLabel.numberOfLines = 1
        contentView.addSubview(channelLabel)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = FlowTypography.bodySmall
        metaLabel.numberOfLines = 1
        contentView.addSubview(metaLabel)

        let fillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0.0)
        progressWidth = fillWidth

        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(
                greaterThanOrEqualToConstant: SubscriptionFeedCell.thumbnailHeight + FlowSpacing.md * 2.0
            ),

            thumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            thumbnail.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.md),
            thumbnail.widthAnchor.constraint(equalToConstant: SubscriptionFeedCell.thumbnailWidth),
            thumbnail.heightAnchor.constraint(equalToConstant: SubscriptionFeedCell.thumbnailHeight),

            durationLabel.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: -FlowSpacing.xs),
            durationLabel.bottomAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: -FlowSpacing.xs),

            progressTrack.leadingAnchor.constraint(equalTo: thumbnail.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor),
            progressTrack.bottomAnchor.constraint(equalTo: thumbnail.bottomAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 2.0),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            fillWidth,

            titleLabel.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.md),

            avatarView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            avatarView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xs),
            avatarView.widthAnchor.constraint(equalToConstant: SubscriptionFeedCell.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: SubscriptionFeedCell.avatarSize),

            channelLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: FlowSpacing.sm),
            channelLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            channelLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: FlowSpacing.xxs),
            metaLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.md),
        ])
        applyTheme()
    }

    /// Fills the row from a feed item and the channel row that owns it.
    func configure(with item: SubscriptionFeedItem, subscription: Subscription?) {
        let video = item.video
        thumbnail.setImage(
            url: video.thumbnail(width: 240),
            targetSize: CGSize(
                width: SubscriptionFeedCell.thumbnailWidth * 2.0,
                height: SubscriptionFeedCell.thumbnailHeight * 2.0
            )
        )
        titleLabel.text = video.title

        durationLabel.text = video.isLive ? "LIVE" : Formatters.durationBadge(TimeInterval(video.duration))
        durationLabel.isHidden = durationLabel.text == nil

        let avatarUrl = video.channelThumbnailUrl.isEmpty
            ? (subscription?.avatarUrl ?? "")
            : video.channelThumbnailUrl
        avatarView.setImage(url: avatarUrl)
        avatarView.isHidden = avatarUrl.isEmpty

        let channelName = video.channelName.isEmpty ? (subscription?.name ?? "") : video.channelName
        channelLabel.text = channelName
        channelLabel.isHidden = channelName.isEmpty

        var parts: [String] = []
        if !video.uploadDate.isEmpty {
            parts.append(video.uploadDate)
        } else {
            parts.append(Formatters.relativeDate(item.uploadedAt))
        }
        if video.viewCount > 0 {
            parts.append(Formatters.viewCount(Int(video.viewCount)))
        }
        if item.progress > 0.0 {
            parts.append("\(Formatters.percent(item.progress)) watched")
        }
        metaLabel.text = parts.joined(separator: " · ")

        setProgress(item.progress)
        accessibilityLabel = [video.title, channelName, metaLabel.text ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// Sets the watched fraction drawn along the bottom of the still.
    func setProgress(_ value: Double) {
        progress = min(max(value, 0.0), 1.0)
        progressTrack.isHidden = progress <= 0.0
        layoutProgress()
    }

    private func layoutProgress() {
        progressWidth?.constant = SubscriptionFeedCell.thumbnailWidth * CGFloat(progress)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutProgress()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.clearImage()
        avatarView.clearImage()
        onChannelTap = nil
        titleLabel.text = nil
        channelLabel.text = nil
        metaLabel.text = nil
        durationLabel.text = nil
        progress = 0.0
        setProgress(0.0)
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        thumbnail.applyTheme()
        avatarView.applyTheme()
        titleLabel.textColor = scheme.onSurface
        channelLabel.textColor = scheme.onSurfaceVariant
        metaLabel.textColor = scheme.onSurfaceVariant
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        progressTrack.backgroundColor = scheme.surfaceContainerHighest
        progressFill.backgroundColor = scheme.primary
        selectedBackgroundView?.backgroundColor = scheme.surfaceContainerHigh
    }

    @objc private func handleAvatarTap() {
        onChannelTap?()
    }
}

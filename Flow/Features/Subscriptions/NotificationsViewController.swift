import UIKit

// MARK: - Model

/// What a stored notification is about.
enum FlowNotificationKind: String {
    /// A video a subscribed channel published.
    case newVideo = "NEW_VIDEO"
    /// Someone mentioned the viewer in a comment.
    case mention = "MENTION"
    /// Flow itself speaking: a failed sync, a finished download, a storage warning.
    case system = "SYSTEM"

    init(stored: String) {
        switch stored {
        case "MENTION": self = .mention
        case "SYSTEM": self = .system
        default: self = .newVideo
        }
    }

    /// The glyph a row of this kind shows when it has no still to show.
    var icon: FlowIcon {
        switch self {
        case .newVideo: return .notification
        case .mention: return .comment
        case .system: return .sync
        }
    }

    /// The word a row of this kind carries beside its channel and time. Uploads need none: they are
    /// the inbox's default and a label on every row would be noise.
    var label: String? {
        switch self {
        case .newVideo: return nil
        case .mention: return "Mention"
        case .system: return "System"
        }
    }
}

/// An upload the subscriptions feed wants the inbox to consider.
///
/// `arrivedAt` is the moment the video was published, not the moment the feed saw it: a channel
/// page lists a week of uploads at once, and every one of them should keep its own place in the
/// timeline rather than all claiming to have arrived during the refresh.
struct NotificationCandidate {
    let video: Video
    let arrivedAt: Date
}

/// One row of the inbox.
struct FlowNotification {
    let id: Int
    let videoId: String
    let title: String
    let channelName: String
    let thumbnailUrl: String
    let timestamp: Date
    let isRead: Bool
    let kind: FlowNotificationKind

    /// The video this notification points at, when it has one.
    var video: Video? {
        guard !videoId.isEmpty else { return nil }
        return Video(
            id: videoId,
            title: title,
            channelName: channelName,
            thumbnailUrl: thumbnailUrl,
            timestamp: timestamp
        )
    }
}

// MARK: - Store

/// The inbox's storage: a `notifications` table in the app database.
///
/// The table is created on first use rather than in `FlowDB`'s schema, so an install that never
/// opens the inbox carries no extra table and an upgrade from an older build needs no migration.
/// Every mutation posts the `"notifications"` event, which is what keeps the tab bar's badge and
/// the Subscriptions tab's bell in step with the list.
final class NotificationStore {

    static let shared = NotificationStore()

    private let database: FlowDB
    private let lock = NSLock()
    private var tableReady = false

    /// Set once the store has seen its first subscription refresh. Until then the videos already
    /// on YouTube are treated as history, not news, so a fresh install does not open with an inbox
    /// full of uploads the viewer has never had a chance to watch.
    private static let seededKey = "notifications.seeded"

    init(database: FlowDB = FlowDB.shared) {
        self.database = database
    }

    // MARK: Reading

    /// Every notification, newest first.
    func all() -> [FlowNotification] {
        ensureTable()
        let rows = database.query(
            "SELECT * FROM notifications ORDER BY timestamp DESC, id DESC;"
        )
        return rows.map { row in
            FlowNotification(
                id: row.int("id"),
                videoId: row.string("video_id"),
                title: row.string("title"),
                channelName: row.string("channel_name"),
                thumbnailUrl: row.string("thumbnail_url"),
                timestamp: row.date("timestamp") ?? Date(timeIntervalSince1970: 0),
                isRead: row.bool("is_read"),
                kind: FlowNotificationKind(stored: row.string("type"))
            )
        }
    }

    /// How many notifications are unread.
    var unreadCount: Int {
        ensureTable()
        return database.scalarInt(
            "SELECT COUNT(*) AS value FROM notifications WHERE is_read = 0;"
        )
    }

    /// The badge's text: the count, capped at "9+" the way the Android app caps it. Nil when there
    /// is nothing unread, which is what hides the badge.
    var badgeText: String? {
        let count = unreadCount
        if count == 0 { return nil }
        return count > 9 ? "9+" : "\(count)"
    }

    // MARK: Writing

    /// Adds a notification, ignoring one for a video already in the inbox.
    @discardableResult
    func insert(
        videoId: String,
        title: String,
        channelName: String,
        thumbnailUrl: String,
        kind: FlowNotificationKind = .newVideo,
        timestamp: Date = Date(),
        isRead: Bool = false
    ) -> Bool {
        ensureTable()
        let changed = database.execute(
            """
            INSERT OR IGNORE INTO notifications
                (video_id, title, channel_name, thumbnail_url, timestamp, is_read, type)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(videoId),
                .text(title),
                .text(channelName),
                .text(thumbnailUrl),
                .double(timestamp.timeIntervalSince1970),
                .bool(isRead),
                .text(kind.rawValue),
            ]
        )
        if changed > 0 {
            FlowEventBus.shared.post("notifications")
        }
        return changed > 0
    }

    /// Files the uploads found by a subscription refresh.
    ///
    /// The first successful refresh after an install only marks the store as seeded: everything it
    /// saw predates the viewer's subscriptions being known here, so announcing it would open the
    /// app with an inbox full of videos that are already old news.
    func recordNewUploads(_ candidates: [NotificationCandidate]) {
        ensureTable()

        if !UserDefaults.standard.bool(forKey: NotificationStore.seededKey) {
            UserDefaults.standard.set(true, forKey: NotificationStore.seededKey)
            return
        }

        guard !candidates.isEmpty else { return }

        var inserted = 0
        database.transaction { transaction in
            for candidate in candidates {
                inserted += transaction.execute(
                    """
                    INSERT OR IGNORE INTO notifications
                        (video_id, title, channel_name, thumbnail_url, timestamp, is_read, type)
                    VALUES (?, ?, ?, ?, ?, 0, ?);
                    """,
                    [
                        .text(candidate.video.id),
                        .text(candidate.video.title),
                        .text(candidate.video.channelName),
                        .text(candidate.video.thumbnailUrl),
                        .double(candidate.arrivedAt.timeIntervalSince1970),
                        .text(FlowNotificationKind.newVideo.rawValue),
                    ]
                )
            }
        }
        if inserted > 0 {
            FlowEventBus.shared.post("notifications")
        }
    }

    /// Marks every notification read. The badge clears; the rows keep their place.
    func markAllAsRead() {
        ensureTable()
        let changed = database.execute("UPDATE notifications SET is_read = 1 WHERE is_read = 0;")
        if changed > 0 {
            FlowEventBus.shared.post("notifications")
        }
    }

    /// Removes one notification.
    func delete(id: Int) {
        ensureTable()
        let changed = database.execute("DELETE FROM notifications WHERE id = ?;", [.int(id)])
        if changed > 0 {
            FlowEventBus.shared.post("notifications")
        }
    }

    /// Puts a removed notification back, as read — undoing a delete should not re-raise the badge.
    func restore(_ notification: FlowNotification) {
        insert(
            videoId: notification.videoId,
            title: notification.title,
            channelName: notification.channelName,
            thumbnailUrl: notification.thumbnailUrl,
            kind: notification.kind,
            timestamp: notification.timestamp,
            isRead: true
        )
    }

    /// Empties the inbox.
    func clearAll() {
        ensureTable()
        let changed = database.execute("DELETE FROM notifications;")
        if changed > 0 {
            FlowEventBus.shared.post("notifications")
        }
    }

    // MARK: Schema

    private func ensureTable() {
        lock.lock()
        defer { lock.unlock() }
        guard !tableReady else { return }
        database.execute(
            """
            CREATE TABLE IF NOT EXISTS notifications (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                video_id TEXT NOT NULL DEFAULT '',
                title TEXT NOT NULL DEFAULT '',
                channel_name TEXT NOT NULL DEFAULT '',
                thumbnail_url TEXT NOT NULL DEFAULT '',
                timestamp REAL NOT NULL DEFAULT 0,
                is_read INTEGER NOT NULL DEFAULT 0,
                type TEXT NOT NULL DEFAULT 'NEW_VIDEO'
            );
            """
        )
        // One notification per video, so a refresh that sees the same upload twice does not
        // duplicate the row. System notices carry no video id and are exempt from the rule.
        database.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS notifications_video ON notifications (video_id) WHERE video_id <> '';"
        )
        tableReady = true
    }
}

// MARK: - Grouping

/// The inbox's sections, in the order they are shown.
enum NotificationBucket: CaseIterable {
    case new
    case today
    case yesterday
    case lastWeek
    case earlier

    /// The heading above the section.
    var title: String {
        switch self {
        case .new: return "New"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .lastWeek: return "Last 7 days"
        case .earlier: return "Earlier"
        }
    }

    /// How a row in this section shows its moment.
    var timeStyle: NotificationTimeStyle {
        switch self {
        case .new, .today: return .relative
        case .yesterday: return .timeOfDay
        case .lastWeek: return .weekday
        case .earlier: return .date
        }
    }
}

/// How a notification's timestamp is written out.
enum NotificationTimeStyle {
    /// "3 hours ago".
    case relative
    /// "14:32", or "2:32 PM" where the device uses a twelve-hour clock.
    case timeOfDay
    /// "Tuesday".
    case weekday
    /// "12 Mar 2024".
    case date
}

/// The calendar section a moment belongs to. Anything stamped after today counts as today, so a
/// device clock a few minutes behind the server does not push a fresh notification into "Yesterday".
enum NotificationGrouping {

    private static let lastWeekDays = 6

    static func bucket(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> NotificationBucket {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        if day >= today { return .today }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return .earlier }
        if day == yesterday { return .yesterday }
        guard let weekStart = calendar.date(byAdding: .day, value: -lastWeekDays, to: today) else { return .earlier }
        if day >= weekStart { return .lastWeek }
        return .earlier
    }

    /// Splits `items` (newest first) into sections: everything still marked new first, then the rest
    /// by calendar day. Order inside a section is kept, which is what makes the inbox read as a
    /// timeline rather than a re-sorted list.
    static func sections(
        from items: [FlowNotification],
        newIds: Set<Int>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [(bucket: NotificationBucket, items: [FlowNotification])] {
        var fresh: [FlowNotification] = []
        var seen: [NotificationBucket: [FlowNotification]] = [:]
        for item in items {
            if newIds.contains(item.id) {
                fresh.append(item)
            } else {
                let bucket = bucket(for: item.timestamp, now: now, calendar: calendar)
                seen[bucket, default: []].append(item)
            }
        }

        var result: [(bucket: NotificationBucket, items: [FlowNotification])] = []
        if !fresh.isEmpty {
            result.append((.new, fresh))
        }
        for bucket in NotificationBucket.allCases where bucket != .new {
            if let bucketItems = seen[bucket], !bucketItems.isEmpty {
                result.append((bucket, bucketItems))
            }
        }
        return result
    }

    /// The moment as its row writes it.
    static func label(for date: Date, style: NotificationTimeStyle) -> String {
        switch style {
        case .relative:
            return Formatters.relativeDate(date)
        case .timeOfDay:
            // "jm" asks for the hour and minute in whatever order and clock the locale uses, so a
            // twelve-hour device reads "2:32 PM" and a twenty-four-hour one "14:32".
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.setLocalizedDateFormatFromTemplate("jm")
            return formatter.string(from: date)
        case .weekday:
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: date)
        case .date:
            return Formatters.absoluteDate(date)
        }
    }
}

// MARK: - Screen

/// The notification inbox: new uploads from subscribed channels, mentions and Flow's own notices,
/// newest first, split into the sections the Android app uses.
///
/// Opening the inbox takes a snapshot of what was unread and then clears the badge, so the rows the
/// viewer came to see stay marked "New" for the rest of the visit while the tab bar stops nagging.
final class NotificationsViewController: UIViewController {

    // MARK: - Configuration

    /// Called when the viewer picks a notification that names a video.
    var onOpenVideo: ((String) -> Void)?
    /// Called when the viewer asks for notification settings.
    var onOpenSettings: (() -> Void)?

    // MARK: - State

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyState = FlowEmptyState.make(
        kind: .custom(
            icon: .notification,
            title: "Peace and quiet",
            message: "You're all caught up! New updates from your subscriptions will appear here."
        ),
        actionTitle: "Notification settings"
    )
    /// Built without targets: the actions are attached once the view is loaded, because a stored
    /// property cannot refer to `self` while the controller is still being initialised.
    private let settingsButton: FlowIconButton = {
        let button = FlowIconButton()
        button.configure(icon: .settings, color: .clear, size: 22.0)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private let clearButton: FlowIconButton = {
        let button = FlowIconButton()
        button.configure(icon: .trash, color: .clear, size: 22.0)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private var items: [FlowNotification] = []
    private var sections: [(bucket: NotificationBucket, items: [FlowNotification])] = []
    private var newIds: Set<Int> = []
    private var tokens: [ObservationToken] = []
    private var hasOpenedInbox = false
    /// Whether the bar currently omits the clear-all action, so the items are only rebuilt when
    /// that actually changes rather than on every reload. It starts false because `buildNavigation`
    /// installs both buttons.
    private var isChromeEmpty = false

    /// The number of notifications still unread. Opening the inbox clears it, so this is only
    /// non-zero before the screen has appeared.
    var unreadCount: Int {
        return NotificationStore.shared.unreadCount
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notifications"
        view.backgroundColor = FlowTheme.shared.background
        buildNavigation()
        buildTable()
        buildEmptyState()
        observeSignals()
        applyTheme()
        openInbox()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A notification may have arrived while the inbox was covered by a pushed video.
        reload()
    }

    deinit {
        for token in tokens {
            token.cancelObservation()
        }
    }

    // MARK: - Build

    private func buildNavigation() {
        settingsButton.configure(icon: .settings, color: FlowTheme.shared.scheme.onSurfaceVariant, size: 22.0)
        settingsButton.accessibilityLabel = "Notification settings"
        settingsButton.addTarget(self, action: #selector(handleSettings), for: .touchUpInside)
        settingsButton.widthAnchor.constraint(equalToConstant: 44.0).isActive = true

        clearButton.configure(icon: .trash, color: FlowTheme.shared.scheme.onSurfaceVariant, size: 22.0)
        clearButton.accessibilityLabel = "Clear all notifications"
        clearButton.addTarget(self, action: #selector(handleClearAll), for: .touchUpInside)
        clearButton.widthAnchor.constraint(equalToConstant: 44.0).isActive = true

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(customView: clearButton),
            UIBarButtonItem(customView: settingsButton),
        ]
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = FlowTheme.shared.background
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 92.0
        tableView.sectionHeaderHeight = 40.0
        tableView.contentInset = UIEdgeInsets(top: 0.0, left: 0.0, bottom: FlowSpacing.xxl, right: 0.0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(
            NotificationRowCell.self,
            forCellReuseIdentifier: NotificationRowCell.reuseIdentifier
        )
        tableView.register(
            NotificationSectionHeaderView.self,
            forHeaderFooterViewReuseIdentifier: NotificationSectionHeaderView.reuseIdentifier
        )
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildEmptyState() {
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        emptyState.onAction = { [weak self] in
            self?.openSettings()
        }
        view.addSubview(emptyState)

        NSLayoutConstraint.activate([
            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func observeSignals() {
        tokens.append(FlowEventBus.shared.on("notifications") { [weak self] _ in
            self?.reload()
        })
        tokens.append(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
    }

    // MARK: - Loading

    /// Takes the unread snapshot and clears the badge. Only the inbox does this: the badge reads
    /// the store directly and must never mark anything read on its own.
    private func openInbox() {
        guard !hasOpenedInbox else { return }
        hasOpenedInbox = true
        let unread = NotificationStore.shared.all().filter { !$0.isRead }
        newIds = Set(unread.map { $0.id })
        NotificationStore.shared.markAllAsRead()
        reload()
    }

    private func reload() {
        items = NotificationStore.shared.all()
        sections = NotificationGrouping.sections(from: items, newIds: newIds)
        tableView.reloadData()
        updateChrome()
    }

    private func updateChrome() {
        let empty = sections.isEmpty
        tableView.isHidden = empty
        emptyState.isHidden = !empty
        guard empty != isChromeEmpty else { return }
        isChromeEmpty = empty
        // The clear-all action only exists while there is something to clear.
        navigationItem.rightBarButtonItems = empty
            ? [UIBarButtonItem(customView: settingsButton)]
            : [UIBarButtonItem(customView: clearButton), UIBarButtonItem(customView: settingsButton)]
    }

    // MARK: - Theme

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        tableView.backgroundColor = scheme.background
        emptyState.applyTheme()
        settingsButton.setIconColor(scheme.onSurfaceVariant)
        clearButton.setIconColor(scheme.onSurfaceVariant)
        for cell in tableView.visibleCells {
            (cell as? NotificationRowCell)?.applyTheme()
        }
        for section in 0..<tableView.numberOfSections {
            (tableView.headerView(forSection: section) as? NotificationSectionHeaderView)?.applyTheme()
        }
    }

    // MARK: - Actions

    @objc private func handleSettings() {
        openSettings()
    }

    private func openSettings() {
        if let handler = onOpenSettings {
            handler()
            return
        }
        Router.shared.openSettings()
    }

    private func open(videoId: String) {
        // A system notice carries no video, so there is nowhere for it to lead.
        guard !videoId.isEmpty else { return }
        if let handler = onOpenVideo {
            handler(videoId)
            return
        }
        Router.shared.openWatch(videoId: videoId)
    }

    @objc private func handleClearAll() {
        guard !items.isEmpty else { return }
        let alert = UIAlertController(
            title: "Clear all notifications?",
            message: clearAllMessage(count: items.count),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Clear all", style: .destructive) { [weak self] _ in
            // The snapshot refers to rows that are about to be deleted, so it is dropped first;
            // the store's own event then reloads the list.
            self?.newIds = []
            NotificationStore.shared.clearAll()
        })
        present(alert, animated: true, completion: nil)
    }

    /// "This removes 1 notification. You can't undo this." with the right plural.
    private func clearAllMessage(count: Int) -> String {
        let noun = count == 1 ? "notification" : "notifications"
        return "This removes \(count) \(noun). You can't undo this."
    }

    /// Removes a notification and offers the undo the Android app offers.
    private func remove(_ notification: FlowNotification) {
        // The snapshot is updated before the delete, because the delete posts the event that
        // reloads the list.
        newIds.remove(notification.id)
        NotificationStore.shared.delete(id: notification.id)
        FlowSnackbar.show("Notification removed", actionTitle: "Undo") {
            NotificationStore.shared.restore(notification)
        }
    }

    /// Saves the notification's video to Watch Later, or says it is already there.
    ///
    /// Watch Later is a local playlist named "Watch Later" on iOS, created the first time something
    /// is saved to it — the same list the video menus write to.
    private func saveToWatchLater(_ notification: FlowNotification) {
        guard let video = notification.video else { return }
        let playlistId = watchLaterPlaylistId()
        guard !playlistId.isEmpty else {
            FlowSnackbar.showError("Failed to save to library")
            return
        }
        if PlaylistStore.shared.contains(videoId: video.id, in: playlistId) {
            FlowSnackbar.show("Already in Watch Later")
            return
        }
        let added = PlaylistStore.shared.addVideo(
            videoId: video.id,
            title: video.title,
            channelName: video.channelName,
            thumbnailUrl: video.thumbnailUrl,
            duration: TimeInterval(video.duration),
            to: playlistId
        )
        guard added else {
            FlowSnackbar.show("Already in Watch Later")
            return
        }
        FlowSnackbar.show("Added to Watch Later", actionTitle: "Undo") {
            PlaylistStore.shared.removeVideo(videoId: video.id, from: playlistId)
        }
    }

    /// The id of the local Watch Later playlist, creating it when it does not exist yet.
    private func watchLaterPlaylistId() -> String {
        let existing = PlaylistStore.shared.allPlaylists().first { playlist in
            playlist.isLocal && playlist.title == "Watch Later"
        }
        if let playlist = existing {
            return playlist.playlistId
        }
        return PlaylistStore.shared.createPlaylist(
            title: "Watch Later",
            description: "Videos you saved for later"
        )
    }

    /// The notification at `indexPath`, if the sections still hold it.
    private func notification(at indexPath: IndexPath) -> FlowNotification? {
        return sections.element(at: indexPath.section)?.items.element(at: indexPath.row)
    }
}

// MARK: - Table data

extension NotificationsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections.element(at: section)?.items.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: NotificationRowCell.reuseIdentifier,
            for: indexPath
        )
        guard let row = cell as? NotificationRowCell,
              let section = sections.element(at: indexPath.section),
              let item = section.items.element(at: indexPath.row) else {
            return cell
        }
        let isNew = section.bucket == .new
        let time = NotificationGrouping.label(
            for: item.timestamp,
            style: section.bucket.timeStyle
        )
        row.configure(with: item, isNew: isNew, time: time)
        row.applyTheme()
        return row
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: NotificationSectionHeaderView.reuseIdentifier
        ) as? NotificationSectionHeaderView,
            let bucket = sections.element(at: section)?.bucket else {
            return nil
        }
        header.configure(title: bucket.title)
        header.applyTheme()
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 40.0
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let item = notification(at: indexPath) else { return }
        open(videoId: item.videoId)
    }

    /// Swiping towards the leading edge saves the video to Watch Later and leaves the row in place.
    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let item = notification(at: indexPath), item.video != nil else { return nil }
        let save = UIContextualAction(style: .normal, title: "Save to Watch Later") { [weak self] _, _, completion in
            self?.saveToWatchLater(item)
            completion(true)
        }
        save.backgroundColor = FlowTheme.shared.scheme.primary
        save.image = FlowIcon.clock.image(size: 22.0, color: .white)
        let configuration = UISwipeActionsConfiguration(actions: [save])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    /// Swiping towards the trailing edge removes the notification, with an undo.
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let item = notification(at: indexPath) else { return nil }
        let remove = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            // The row finishes its swipe animation before the data source drops it; reloading the
            // table inside the handler would pull the row out from under that animation.
            completion(true)
            DispatchQueue.main.async {
                self?.remove(item)
            }
        }
        remove.backgroundColor = FlowTheme.shared.scheme.error
        remove.image = FlowIcon.trash.image(size: 22.0, color: .white)
        return UISwipeActionsConfiguration(actions: [remove])
    }
}

// MARK: - Section header

/// The heading above a group of notifications.
final class NotificationSectionHeaderView: UITableViewHeaderFooterView {

    static let reuseIdentifier = "NotificationSectionHeaderView"

    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        let background = UIView()
        background.backgroundColor = .clear
        backgroundView = background

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FlowTypography.titleSmallEmphasized
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.xs),
        ])
        applyTheme()
    }

    /// Sets the section's heading.
    func configure(title: String) {
        label.text = title
        accessibilityLabel = title
    }

    /// Repaints the heading in the current palette.
    func applyTheme() {
        label.textColor = FlowTheme.shared.scheme.onSurface
    }
}

// MARK: - Row

/// One notification: the still, the title, and "channel · when", with a dot while it is new.
final class NotificationRowCell: UITableViewCell {

    static let reuseIdentifier = "NotificationRowCell"

    private static let thumbnailWidth: CGFloat = 120.0
    private static let thumbnailHeight: CGFloat = 68.0
    private static let dotSize: CGFloat = 6.0

    private let thumbnail = AsyncImageView.make(cornerRadius: FlowShapes.thumbnail)
    private let placeholderIcon = FlowIconView()
    private let titleLabel = UILabel()
    private let dot = UIView()
    private let metaLabel = UILabel()
    private let metaRow = UIStackView()

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

        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.icon = .notification
        placeholderIcon.iconSize = 24.0
        placeholderIcon.isHidden = true
        contentView.addSubview(placeholderIcon)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = NotificationRowCell.dotSize / 2.0
        dot.layer.masksToBounds = true
        dot.isHidden = true

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = FlowTypography.bodySmall
        metaLabel.numberOfLines = 1

        metaRow.translatesAutoresizingMaskIntoConstraints = false
        metaRow.axis = .horizontal
        metaRow.alignment = .center
        metaRow.spacing = FlowSpacing.sm
        metaRow.addArrangedSubview(dot)
        metaRow.addArrangedSubview(metaLabel)
        contentView.addSubview(metaRow)

        NSLayoutConstraint.activate([
            // The still is taller than a one-line title and its meta, so the row keeps the
            // Android app's 92-point rhythm rather than collapsing around short titles.
            contentView.heightAnchor.constraint(
                greaterThanOrEqualToConstant: NotificationRowCell.thumbnailHeight + FlowSpacing.lg * 2.0
            ),

            thumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            thumbnail.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: NotificationRowCell.thumbnailWidth),
            thumbnail.heightAnchor.constraint(equalToConstant: NotificationRowCell.thumbnailHeight),

            placeholderIcon.centerXAnchor.constraint(equalTo: thumbnail.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: thumbnail.centerYAnchor),
            placeholderIcon.widthAnchor.constraint(equalToConstant: 24.0),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 24.0),

            titleLabel.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),

            metaRow.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaRow.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.trailingAnchor),
            metaRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.sm),
            // An inequality, not an equality: a one-line title must not force the row shorter than
            // the still beside it.
            metaRow.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),

            dot.widthAnchor.constraint(equalToConstant: NotificationRowCell.dotSize),
            dot.heightAnchor.constraint(equalToConstant: NotificationRowCell.dotSize),
        ])
        applyTheme()
    }

    /// Fills the row. `isNew` bolds the title and shows the dot.
    func configure(with notification: FlowNotification, isNew: Bool, time: String) {
        let url = notification.thumbnailUrl.isEmpty
            ? (notification.video?.thumbnail(width: 240) ?? "")
            : notification.thumbnailUrl
        thumbnail.setImage(
            url: url,
            targetSize: CGSize(
                width: NotificationRowCell.thumbnailWidth * 2.0,
                height: NotificationRowCell.thumbnailHeight * 2.0
            )
        )
        thumbnail.isHidden = url.isEmpty
        placeholderIcon.isHidden = !url.isEmpty
        placeholderIcon.icon = notification.kind.icon

        titleLabel.text = notification.title
        titleLabel.font = isNew ? FlowTypography.titleSmallEmphasized : FlowTypography.titleSmall

        dot.isHidden = !isNew
        // "channel · time", with the mention or system label standing in for a missing channel.
        var parts: [String] = []
        if !notification.channelName.isEmpty {
            parts.append(notification.channelName)
        } else if let label = notification.kind.label {
            parts.append(label)
        }
        parts.append(time)
        metaLabel.text = parts.joined(separator: " · ")

        accessibilityLabel = [notification.title, metaLabel.text ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if isNew {
            accessibilityValue = "New"
        } else {
            accessibilityValue = nil
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.clearImage()
        titleLabel.text = nil
        metaLabel.text = nil
        dot.isHidden = true
        placeholderIcon.isHidden = true
        accessibilityValue = nil
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        thumbnail.applyTheme()
        placeholderIcon.iconColor = scheme.onSurfaceVariant
        thumbnail.backgroundColor = scheme.surfaceContainerHigh
        titleLabel.textColor = scheme.onSurface
        metaLabel.textColor = scheme.onSurfaceVariant
        dot.backgroundColor = scheme.primary
        selectedBackgroundView?.backgroundColor = scheme.surfaceContainerHigh
    }
}

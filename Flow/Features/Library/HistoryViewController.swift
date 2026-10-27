import UIKit

/// Watch history: every video the viewer has played, newest first, grouped under the day it was
/// watched.
///
/// The Android screen offers a search field, kind filters, a sort order and a year filter. All four
/// are here, applied to the store's cached list so filtering never touches the database. Swiping a
/// row removes it and offers an undo, which writes the entry back with its original timestamp.
final class HistoryViewController: UIViewController {

    // MARK: - Filters

    /// Which entries the list shows.
    enum Kind: Int, CaseIterable {
        case all
        case videos
        case shorts
        case music
        case localVideos
        case localMusic

        var title: String {
            switch self {
            case .all: return "All"
            case .videos: return "Videos"
            case .shorts: return "Shorts"
            case .music: return "Music"
            case .localVideos: return "Local videos"
            case .localMusic: return "Local music"
            }
        }
    }

    /// The order the days and the entries inside them are shown in.
    enum Order: Int {
        case newestFirst
        case oldestFirst

        var title: String {
            switch self {
            case .newestFirst: return "Newest first"
            case .oldestFirst: return "Oldest first"
            }
        }
    }

    /// One day's worth of entries.
    private struct DayGroup {
        let day: Date
        var entries: [HistoryEntry]
    }

    // MARK: - Views

    private let searchField = LibrarySearchField(placeholder: "Search watch history")
    private let filterRow = FlowChipRow()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyState = FlowEmptyState.make(kind: .custom(
        icon: .clock,
        title: "No Watch History",
        message: "Videos you watch will appear here"
    ))
    private let noResultsState = FlowEmptyState.make(kind: .custom(
        icon: .search,
        title: "No matching history",
        message: "Try a different search or filter"
    ))
    private let moreButton = FlowIconButton.make(.more, color: .clear, size: 22.0, target: nil, action: nil)

    // MARK: - State

    private var allEntries: [HistoryEntry] = []
    private var groups: [DayGroup] = []
    private var query = ""
    private var kind: Kind = .all
    private var order: Order = .newestFirst
    private var yearFilter: Int?
    private var tokens: [ObservationToken] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "History"
        view.backgroundColor = FlowTheme.shared.background
        buildViews()
        observeStores()
        applyTheme()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    deinit {
        for token in tokens {
            token.cancelObservation()
        }
    }

    // MARK: - Construction

    private func buildViews() {
        searchField.onChange = { [weak self] text in
            self?.query = text
            self?.applyFilters()
        }

        filterRow.onSelect = { [weak self] index in
            guard let self = self, let selected = Kind(rawValue: index) else { return }
            self.kind = selected
            self.applyFilters()
        }
        filterRow.setTitles(Kind.allCases.map { $0.title }, selectedIndex: Kind.all.rawValue)

        moreButton.accessibilityLabel = "History options"
        moreButton.addTarget(self, action: #selector(showOptions), for: .touchUpInside)
        moreButton.widthAnchor.constraint(equalToConstant: 40.0).isActive = true

        let searchRow = UIStackView(arrangedSubviews: [searchField, moreButton])
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.axis = .horizontal
        searchRow.spacing = FlowSpacing.xs
        searchRow.alignment = .center
        view.addSubview(searchRow)

        view.addSubviewForAutoLayout(filterRow)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 84.0
        tableView.estimatedRowHeight = 84.0
        tableView.sectionHeaderHeight = 40.0
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(HistoryRowCell.self, forCellReuseIdentifier: HistoryRowCell.reuseIdentifier)
        tableView.register(
            HistoryDayHeaderView.self,
            forHeaderFooterViewReuseIdentifier: HistoryDayHeaderView.reuseIdentifier
        )
        view.addSubview(tableView)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        view.addSubview(emptyState)

        noResultsState.translatesAutoresizingMaskIntoConstraints = false
        noResultsState.isHidden = true
        view.addSubview(noResultsState)

        NSLayoutConstraint.activate([
            searchRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.screenMargin),
            searchRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.md),
            searchRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: FlowSpacing.md),

            filterRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filterRow.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: FlowSpacing.xs),

            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: filterRow.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: filterRow.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            noResultsState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            noResultsState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            noResultsState.topAnchor.constraint(equalTo: filterRow.bottomAnchor),
            noResultsState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func observeStores() {
        tokens.append(FlowEventBus.shared.on("history") { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async { self.reload() }
        })
        tokens.append(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
    }

    // MARK: - Loading

    private func reload() {
        allEntries = HistoryStore.shared.recent(limit: 500)
        applyFilters()
    }

    /// Applies the search text, the kind filter, the year filter and the order, then rebuilds the
    /// day groups. Runs on every keystroke, so it works on the cached list only.
    private func applyFilters() {
        let trimmed = query.trimmed.lowercased()
        var filtered = allEntries.filter { entry in
            guard matchesKind(entry) else { return false }
            if let year = yearFilter {
                let entryYear = Calendar.current.component(.year, from: entry.watchedAt)
                guard entryYear == year else { return false }
            }
            guard !trimmed.isEmpty else { return true }
            return entry.title.lowercased().contains(trimmed)
                || entry.channelName.lowercased().contains(trimmed)
        }

        if order == .oldestFirst {
            filtered.reverse()
        }
        groups = HistoryViewController.group(filtered, order: order)
        tableView.reloadData()
        updateEmptyStates()
    }

    private func matchesKind(_ entry: HistoryEntry) -> Bool {
        switch kind {
        case .all:
            return true
        case .videos:
            return !entry.isMusic
        case .shorts:
            // A Short is a vertical video; the store keeps no flag for it, so the length is the
            // signal that a row came from the Shorts player.
            return HistoryViewController.isShort(entry)
        case .music:
            return entry.isMusic
        case .localVideos:
            return !entry.isMusic && DownloadStore.shared.isDownloaded(videoId: entry.videoId)
        case .localMusic:
            return entry.isMusic && DownloadStore.shared.isDownloaded(videoId: entry.videoId)
        }
    }

    private static func isShort(_ entry: HistoryEntry) -> Bool {
        return !entry.isMusic && entry.duration > 0 && entry.duration <= 60
    }

    private static func group(_ entries: [HistoryEntry], order: Order) -> [DayGroup] {
        var result: [DayGroup] = []
        for entry in entries {
            let day = entry.watchedAt.startOfDay
            if let last = result.last, last.day == day {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append(DayGroup(day: day, entries: [entry]))
            }
        }
        if order == .oldestFirst {
            result.sort { $0.day < $1.day }
        }
        return result
    }

    private func updateEmptyStates() {
        let hasAnything = !allEntries.isEmpty
        emptyState.isHidden = hasAnything
        noResultsState.isHidden = !hasAnything || !groups.isEmpty
        tableView.isHidden = groups.isEmpty
    }

    // MARK: - Theme

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        tableView.backgroundColor = scheme.background
        searchField.applyTheme()
        filterRow.applyTheme()
        emptyState.applyTheme()
        noResultsState.applyTheme()
        moreButton.setIconColor(scheme.onSurfaceVariant)
        for cell in tableView.visibleCells {
            (cell as? HistoryRowCell)?.applyTheme()
        }
        for section in 0..<tableView.numberOfSections {
            (tableView.headerView(forSection: section) as? HistoryDayHeaderView)?.applyTheme()
        }
    }

    // MARK: - Actions

    @objc private func showOptions() {
        var actions: [FlowActionSheetContent.Action] = []
        let nextOrder: Order = order == .newestFirst ? .oldestFirst : .newestFirst
        actions.append(FlowActionSheetContent.Action(title: nextOrder.title, icon: .sort) { [weak self] in
            self?.order = nextOrder
            self?.applyFilters()
        })

        let years = availableYears()
        if !years.isEmpty {
            actions.append(FlowActionSheetContent.Action(
                title: yearFilter == nil ? "Filter by year" : "All years",
                icon: .filter
            ) { [weak self] in
                guard let self = self else { return }
                self.presentYearPicker(years)
            })
        }

        actions.append(FlowActionSheetContent.Action(title: "Delete Shorts", icon: .trash, isDestructive: true) { [weak self] in
            self?.deleteShorts()
        })
        actions.append(FlowActionSheetContent.Action(title: "Clear all", icon: .trash, isDestructive: true) { [weak self] in
            self?.confirmClearAll()
        })

        LibraryMenu.present(from: self, title: "History", actions: actions)
    }

    private func availableYears() -> [Int] {
        var years: Set<Int> = []
        for entry in allEntries {
            years.insert(Calendar.current.component(.year, from: entry.watchedAt))
        }
        return years.sorted(by: >)
    }

    private func presentYearPicker(_ years: [Int]) {
        let alert = UIAlertController(title: "Filter by year", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "All years", style: .default) { [weak self] _ in
            self?.yearFilter = nil
            self?.applyFilters()
        })
        for year in years {
            alert.addAction(UIAlertAction(title: String(year), style: .default) { [weak self] _ in
                self?.yearFilter = year
                self?.applyFilters()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.popoverPresentationController?.sourceView = moreButton
        alert.popoverPresentationController?.sourceRect = moreButton.bounds
        present(alert, animated: true, completion: nil)
    }

    private func deleteShorts() {
        let shorts = allEntries.filter { HistoryViewController.isShort($0) }
        guard !shorts.isEmpty else {
            FlowSnackbar.show("No Shorts in your history")
            return
        }
        let alert = UIAlertController(
            title: "Delete Shorts?",
            message: "\(shorts.count) Short\(shorts.count == 1 ? "" : "s") will be removed from your watch history.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            for entry in shorts {
                HistoryStore.shared.remove(videoId: entry.videoId)
            }
            FlowSnackbar.show("Removed \(shorts.count) Short\(shorts.count == 1 ? "" : "s") from history")
            self?.reload()
        })
        present(alert, animated: true, completion: nil)
    }

    private func confirmClearAll() {
        let alert = UIAlertController(
            title: "Clear watch history?",
            message: "This will remove all videos from your watch history. This action cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            HistoryStore.shared.clear()
            self?.reload()
            FlowSnackbar.show("Watch history cleared")
        })
        present(alert, animated: true, completion: nil)
    }

    /// Removes one entry and offers to put it back exactly as it was.
    private func remove(_ entry: HistoryEntry) {
        HistoryStore.shared.remove(videoId: entry.videoId)
        FlowSnackbar.show("Removed from history", actionTitle: "Undo") {
            HistoryStore.shared.record(
                videoId: entry.videoId,
                title: entry.title,
                channelId: entry.channelId,
                channelName: entry.channelName,
                thumbnailUrl: entry.thumbnailUrl,
                duration: entry.duration,
                position: entry.position,
                isMusic: entry.isMusic,
                watchedAt: entry.watchedAt
            )
        }
    }

    /// Plays an entry. A downloaded video plays from its file, so a history row still works offline.
    private func play(_ entry: HistoryEntry) {
        var item = PlaybackQueueItem(
            videoId: entry.videoId,
            title: entry.title,
            channelName: entry.channelName,
            channelId: entry.channelId,
            thumbnailUrl: entry.thumbnailUrl,
            duration: entry.duration,
            isMusic: entry.isMusic
        )
        if let record = DownloadStore.shared.record(videoId: entry.videoId) {
            item.localFileURL = record.fileURL ?? record.audioURL
        }
        FlowApp.shared.playback.play(items: [item], startIndex: 0, title: "History", autoplay: true)
        if entry.isMusic {
            Router.shared.present(MusicPlayerViewController(service: FlowApp.shared.playback), from: self)
        } else {
            Router.shared.openWatch(videoId: entry.videoId)
        }
    }
}

// MARK: - Table data

extension HistoryViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        return groups.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return groups.element(at: section)?.entries.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: HistoryRowCell.reuseIdentifier, for: indexPath)
        guard let row = cell as? HistoryRowCell,
              let group = groups.element(at: indexPath.section),
              let entry = group.entries.element(at: indexPath.row) else {
            return cell
        }
        row.configure(with: entry)
        row.applyTheme()
        return row
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: HistoryDayHeaderView.reuseIdentifier
        ) as? HistoryDayHeaderView, let group = groups.element(at: section) else {
            return nil
        }
        header.configure(title: Formatters.dayHeading(group.day))
        header.applyTheme()
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 40.0
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let group = groups.element(at: indexPath.section),
              let entry = group.entries.element(at: indexPath.row) else { return }
        play(entry)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let group = groups.element(at: indexPath.section),
              let entry = group.entries.element(at: indexPath.row) else { return nil }
        let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, completion in
            self?.remove(entry)
            completion(true)
        }
        remove.backgroundColor = FlowTheme.shared.scheme.error
        return UISwipeActionsConfiguration(actions: [remove])
    }
}

// MARK: - Row

/// One history entry: the still with a resume bar, the title, the channel and when it was watched.
final class HistoryRowCell: UITableViewCell {

    static let reuseIdentifier = "HistoryRowCell"

    private static let thumbnailWidth: CGFloat = 112.0
    private static let thumbnailHeight: CGFloat = 63.0

    private let thumbnail = AsyncImageView.make(cornerRadius: FlowShapes.thumbnail)
    private let durationLabel = PaddedLabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private var progressWidth: NSLayoutConstraint?
    private var progress: Double = 0.0

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
        durationLabel.textInsets = UIEdgeInsets(top: 1, left: 4, bottom: 1, right: 4)
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

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 2
        contentView.addSubview(detailLabel)

        let fillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0.0)
        progressWidth = fillWidth

        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            thumbnail.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: HistoryRowCell.thumbnailWidth),
            thumbnail.heightAnchor.constraint(equalToConstant: HistoryRowCell.thumbnailHeight),

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

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -FlowSpacing.md),
        ])
        applyTheme()
    }

    /// Sets the row's content from a history entry.
    func configure(with entry: HistoryEntry) {
        thumbnail.setImage(url: entry.thumbnailUrl, targetSize: CGSize(width: 224.0, height: 126.0))
        titleLabel.text = entry.title
        durationLabel.text = Formatters.durationBadge(entry.duration)
        durationLabel.isHidden = durationLabel.text == nil
        progressTrack.isHidden = entry.progress <= 0.0
        setProgress(entry.progress)

        var parts: [String] = []
        if !entry.channelName.isEmpty {
            parts.append(entry.channelName)
        }
        parts.append(Formatters.relativeDate(entry.watchedAt))
        if entry.isFinished {
            parts.append("Watched")
        } else if entry.position > 0 {
            parts.append("\(Formatters.playbackTime(entry.position)) watched")
        }
        detailLabel.text = parts.joined(separator: " · ")
        accessibilityLabel = "\(entry.title), \(detailLabel.text ?? "")"
    }

    /// Sets the watched fraction drawn along the bottom of the still.
    func setProgress(_ value: Double) {
        progress = min(max(value, 0.0), 1.0)
        progressWidth?.constant = HistoryRowCell.thumbnailWidth * CGFloat(progress)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        progressWidth?.constant = HistoryRowCell.thumbnailWidth * CGFloat(progress)
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        thumbnail.applyTheme()
        titleLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        progressTrack.backgroundColor = scheme.outlineVariant
        progressFill.backgroundColor = scheme.primary
        selectedBackgroundView?.backgroundColor = scheme.surfaceContainerHigh
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.clearImage()
        titleLabel.text = nil
        detailLabel.text = nil
        durationLabel.text = nil
        progress = 0.0
        progressWidth?.constant = 0.0
    }
}

// MARK: - Day header

/// The heading above a day's entries: "Today", "Yesterday", or a long date.
final class HistoryDayHeaderView: UITableViewHeaderFooterView {

    static let reuseIdentifier = "HistoryDayHeaderView"

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

    /// Sets the day's heading.
    func configure(title: String) {
        label.text = title
        accessibilityLabel = title
    }

    /// Repaints the heading in the current palette.
    func applyTheme() {
        label.textColor = FlowTheme.shared.scheme.onSurface
    }
}

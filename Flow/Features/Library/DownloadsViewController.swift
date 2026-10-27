import UIKit

/// Downloads: what is on the device, what is still arriving, and how much space it takes.
///
/// The Android screen splits the list into an "In progress" block and a "Downloaded" block, with a
/// kind switch, search, sort and a storage card. The iOS port keeps that structure. A finished row
/// plays from its local file through `PlaybackService`, so it needs no network at all.
final class DownloadsViewController: UIViewController {

    // MARK: - Filters

    /// Which downloads the list shows.
    enum Kind: Int {
        case videos
        case music

        var title: String {
            switch self {
            case .videos: return "Videos"
            case .music: return "Music"
            }
        }
    }

    /// The order the finished downloads are shown in.
    enum Sort: Int, CaseIterable {
        case newest
        case oldest
        case largest
        case title
        case channel

        var title: String {
            switch self {
            case .newest: return "Newest"
            case .oldest: return "Oldest"
            case .largest: return "Largest"
            case .title: return "Title"
            case .channel: return "Channel"
            }
        }
    }

    // MARK: - Views

    private let kindControl = FlowSegmentedControl()
    private let searchField = LibrarySearchField(placeholder: "Search downloads")
    /// Built without a target: the action is attached once the view is loaded, because a stored
    /// property cannot refer to `self` while the controller is still being initialised.
    private let sortButton: FlowIconButton = {
        let button = FlowIconButton()
        button.configure(icon: .sort, color: .clear, size: 22.0)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyState = FlowEmptyState.make(kind: .custom(
        icon: .download,
        title: "No downloads yet",
        message: "Your downloaded videos will appear here.\nEnjoy your content even without internet."
    ), actionTitle: "Go to Home")
    private let noResultsState = FlowEmptyState.make(kind: .custom(
        icon: .search,
        title: "No downloads match your search",
        message: "Try a different search or filter"
    ))

    // MARK: - State

    private var active: [DownloadRecord] = []
    private var completed: [DownloadRecord] = []
    private var kind: Kind = .videos
    private var sort: Sort = .newest
    private var query = ""
    private var tokens: [ObservationToken] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloads"
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
        kindControl.setTitles([Kind.videos.title, Kind.music.title], selectedIndex: kind.rawValue)
        kindControl.onSelect = { [weak self] index in
            guard let self = self, let selected = Kind(rawValue: index) else { return }
            self.kind = selected
            self.reload()
        }

        searchField.onChange = { [weak self] text in
            self?.query = text
            self?.reload()
        }

        sortButton.accessibilityLabel = "Sort downloads"
        sortButton.addTarget(self, action: #selector(showSortMenu), for: .touchUpInside)
        sortButton.widthAnchor.constraint(equalToConstant: 40.0).isActive = true

        let searchRow = UIStackView(arrangedSubviews: [searchField, sortButton])
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.axis = .horizontal
        searchRow.spacing = FlowSpacing.xs
        searchRow.alignment = .center

        let header = UIStackView(arrangedSubviews: [kindControl, searchRow])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.axis = .vertical
        header.spacing = FlowSpacing.md
        view.addSubview(header)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 96.0
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 52.0
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(DownloadRowCell.self, forCellReuseIdentifier: DownloadRowCell.reuseIdentifier)
        tableView.register(DownloadsStorageCell.self, forCellReuseIdentifier: DownloadsStorageCell.reuseIdentifier)
        tableView.register(
            DownloadsSectionHeader.self,
            forHeaderFooterViewReuseIdentifier: DownloadsSectionHeader.reuseIdentifier
        )
        view.addSubview(tableView)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        emptyState.onAction = {
            Router.shared.selectTab(.home)
        }
        view.addSubview(emptyState)

        noResultsState.translatesAutoresizingMaskIntoConstraints = false
        noResultsState.isHidden = true
        view.addSubview(noResultsState)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.screenMargin),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.md),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: FlowSpacing.md),

            kindControl.widthAnchor.constraint(equalToConstant: 240.0),

            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: FlowSpacing.sm),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            noResultsState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            noResultsState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            noResultsState.topAnchor.constraint(equalTo: header.bottomAnchor),
            noResultsState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func observeStores() {
        tokens.append(FlowEventBus.shared.on("downloads") { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async { self.reload() }
        })
        tokens.append(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
    }

    // MARK: - Loading

    private func reload() {
        let everything = DownloadStore.shared.all()
        let forKind = everything.filter { $0.isMusic == (kind == .music) }
        active = forKind.filter { $0.state.isActive || $0.state == .paused || $0.state == .failed }
        var finished = forKind.filter { $0.state == .completed }

        let trimmed = query.trimmed.lowercased()
        if !trimmed.isEmpty {
            active = active.filter {
                $0.title.lowercased().contains(trimmed) || $0.channelName.lowercased().contains(trimmed)
            }
            finished = finished.filter {
                $0.title.lowercased().contains(trimmed) || $0.channelName.lowercased().contains(trimmed)
            }
        }

        switch sort {
        case .newest:
            finished.sort { $0.createdAt > $1.createdAt }
        case .oldest:
            finished.sort { $0.createdAt < $1.createdAt }
        case .largest:
            finished.sort { $0.byteSize > $1.byteSize }
        case .title:
            finished.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .channel:
            finished.sort { $0.channelName.localizedCaseInsensitiveCompare($1.channelName) == .orderedAscending }
        }
        completed = finished

        tableView.reloadData()
        updateEmptyStates()
    }

    private func updateEmptyStates() {
        let hasAnything = !active.isEmpty || !completed.isEmpty
        let isSearching = !query.trimmed.isEmpty
        emptyState.isHidden = hasAnything || isSearching
        noResultsState.isHidden = hasAnything || !isSearching
        tableView.isHidden = !hasAnything
    }

    // MARK: - Theme

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        tableView.backgroundColor = scheme.background
        kindControl.applyTheme()
        searchField.applyTheme()
        sortButton.setIconColor(scheme.onSurfaceVariant)
        emptyState.applyTheme()
        noResultsState.applyTheme()
        for cell in tableView.visibleCells {
            (cell as? DownloadRowCell)?.applyTheme()
        }
        for section in 0..<tableView.numberOfSections {
            (tableView.headerView(forSection: section) as? DownloadsSectionHeader)?.applyTheme()
        }
    }

    // MARK: - Actions

    @objc private func showSortMenu() {
        let actions = Sort.allCases.map { option in
            FlowActionSheetContent.Action(title: option.title, icon: .sort) { [weak self] in
                self?.sort = option
                self?.reload()
            }
        }
        LibraryMenu.present(from: self, title: "Sort by", actions: actions)
    }

    /// Plays a finished download from its file. Nothing is fetched, so this works in airplane mode.
    private func play(_ record: DownloadRecord) {
        guard let url = record.fileURL ?? record.audioURL else {
            FlowSnackbar.showError("This download's file is missing.")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            FlowSnackbar.showError("This download's file is missing.")
            return
        }
        let item = PlaybackQueueItem(
            videoId: record.videoId,
            title: record.title,
            channelName: record.channelName,
            thumbnailUrl: record.thumbnailUrl,
            duration: record.duration,
            isMusic: record.isMusic,
            localFileURL: url
        )
        FlowApp.shared.playback.play(items: [item], startIndex: 0, title: "Downloads", autoplay: true)
        if record.isMusic {
            Router.shared.present(MusicPlayerViewController(service: FlowApp.shared.playback), from: self)
        } else {
            Router.shared.openWatch(videoId: record.videoId)
        }
    }

    private func confirmDelete(_ record: DownloadRecord) {
        let alert = UIAlertController(
            title: "Delete download?",
            message: "\(record.title) will be removed from this device.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            DownloadStore.shared.remove(videoId: record.videoId)
            self?.reload()
            FlowSnackbar.show("Download deleted")
        })
        present(alert, animated: true, completion: nil)
    }

    private func cancel(_ record: DownloadRecord) {
        DownloadStore.shared.remove(videoId: record.videoId)
        reload()
        FlowSnackbar.show("Download cancelled")
    }

    private func clearIncomplete() {
        let incomplete = DownloadStore.shared.all().filter { !$0.state.isFinished }
        guard !incomplete.isEmpty else {
            FlowSnackbar.show("No incomplete downloads")
            return
        }
        let alert = UIAlertController(
            title: "Remove incomplete downloads?",
            message: "\(incomplete.count) unfinished download\(incomplete.count == 1 ? "" : "s") will be removed from this device.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            for record in incomplete {
                DownloadStore.shared.remove(videoId: record.videoId)
            }
            self?.reload()
            FlowSnackbar.show("Incomplete downloads removed")
        })
        present(alert, animated: true, completion: nil)
    }

    /// The storage card's figures: what Flow uses, what the device has left, and the split.
    private func storageFigures() -> (used: Int64, free: Int64, videos: Int64, music: Int64) {
        let records = DownloadStore.shared.completed()
        var videoBytes: Int64 = 0
        var musicBytes: Int64 = 0
        for record in records {
            if record.isMusic {
                musicBytes += record.byteSize
            } else {
                videoBytes += record.byteSize
            }
        }
        return (
            videoBytes + musicBytes,
            DownloadStoreViewController.freeSpace(),
            videoBytes,
            musicBytes
        )
    }
}

// MARK: - Table data

extension DownloadsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return active.isEmpty ? 0 : active.count + 1
        }
        return completed.isEmpty ? 0 : completed.count + 1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row == 0 {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: DownloadsStorageCell.reuseIdentifier,
                for: indexPath
            )
            guard let storage = cell as? DownloadsStorageCell else { return cell }
            let figures = storageFigures()
            storage.configure(
                used: figures.used,
                free: figures.free,
                videos: figures.videos,
                music: figures.music,
                showsWifiOnly: FlowApp.shared.prefs.bool(for: PrefsStore.Key.downloadWifiOnly, fallback: false)
            )
            storage.applyTheme()
            return storage
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: DownloadRowCell.reuseIdentifier, for: indexPath)
        guard let row = cell as? DownloadRowCell else { return cell }
        let record: DownloadRecord?
        if indexPath.section == 0 {
            record = active.element(at: indexPath.row - 1)
        } else {
            record = completed.element(at: indexPath.row - 1)
        }
        guard let item = record else { return cell }

        row.configure(with: item)
        row.onPlay = { [weak self] in self?.play(item) }
        row.onPause = { DownloadStore.shared.pause(videoId: item.videoId) }
        row.onResume = { DownloadStore.shared.resume(videoId: item.videoId) }
        row.onRetry = { DownloadStore.shared.resume(videoId: item.videoId) }
        row.onCancel = { [weak self] in self?.cancel(item) }
        row.onDelete = { [weak self] in self?.confirmDelete(item) }
        row.applyTheme()
        return row
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let hasRows = tableView.numberOfRows(inSection: section) > 0
        guard hasRows, let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: DownloadsSectionHeader.reuseIdentifier
        ) as? DownloadsSectionHeader else {
            return nil
        }
        if section == 0 {
            header.configure(title: "In progress", actionTitle: "Cancel all")
            header.onAction = { [weak self] in self?.clearIncomplete() }
        } else {
            header.configure(title: "Downloaded", actionTitle: "Remove incomplete")
            header.onAction = { [weak self] in self?.clearIncomplete() }
        }
        header.applyTheme()
        return header
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row > 0, indexPath.section == 1,
              let record = completed.element(at: indexPath.row - 1) else { return }
        play(record)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.row > 0 else { return nil }
        let record = indexPath.section == 0
            ? active.element(at: indexPath.row - 1)
            : completed.element(at: indexPath.row - 1)
        guard let item = record else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            if item.state == .completed {
                self?.confirmDelete(item)
            } else {
                self?.cancel(item)
            }
            completion(true)
        }
        delete.backgroundColor = FlowTheme.shared.scheme.error
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

// MARK: - Storage card

/// The summary at the top of the list: how much Flow uses, how much is left, and the video/music
/// split, followed by the Wi-Fi-only notice when that preference is on.
final class DownloadsStorageCard: UIView {

    private let titleLabel = UILabel()
    private let freeLabel = UILabel()
    private let bar = UIView()
    private let videoFill = UIView()
    private let musicFill = UIView()
    private let videosLabel = UILabel()
    private let musicLabel = UILabel()
    private let wifiBanner = UIView()
    private let wifiLabel = UILabel()
    private let wifiIcon = FlowIconView()
    private var videoWidth: NSLayoutConstraint?
    private var musicWidth: NSLayoutConstraint?
    private var videoFraction: CGFloat = 0.0
    private var musicFraction: CGFloat = 0.0

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
        layer.cornerRadius = FlowShapes.medium
        layer.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleMediumEmphasized
        titleLabel.numberOfLines = 1
        addSubview(titleLabel)

        freeLabel.translatesAutoresizingMaskIntoConstraints = false
        freeLabel.font = FlowTypography.bodySmall
        freeLabel.numberOfLines = 1
        addSubview(freeLabel)

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.layer.cornerRadius = 3.0
        bar.layer.masksToBounds = true
        addSubview(bar)

        videoFill.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(videoFill)

        musicFill.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(musicFill)

        videosLabel.translatesAutoresizingMaskIntoConstraints = false
        videosLabel.font = FlowTypography.labelMedium
        videosLabel.numberOfLines = 1
        addSubview(videosLabel)

        musicLabel.translatesAutoresizingMaskIntoConstraints = false
        musicLabel.font = FlowTypography.labelMedium
        musicLabel.numberOfLines = 1
        addSubview(musicLabel)

        wifiBanner.translatesAutoresizingMaskIntoConstraints = false
        wifiBanner.layer.cornerRadius = FlowShapes.small
        wifiBanner.layer.masksToBounds = true
        addSubview(wifiBanner)

        wifiIcon.translatesAutoresizingMaskIntoConstraints = false
        wifiIcon.icon = .wifi
        wifiIcon.iconSize = 16.0
        wifiBanner.addSubview(wifiIcon)

        wifiLabel.translatesAutoresizingMaskIntoConstraints = false
        wifiLabel.font = FlowTypography.bodySmall
        wifiLabel.text = "Downloads wait for Wi-Fi"
        wifiLabel.numberOfLines = 1
        wifiBanner.addSubview(wifiLabel)

        let videoWidthConstraint = videoFill.widthAnchor.constraint(equalToConstant: 0.0)
        let musicWidthConstraint = musicFill.widthAnchor.constraint(equalToConstant: 0.0)
        videoWidth = videoWidthConstraint
        musicWidth = musicWidthConstraint

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: freeLabel.leadingAnchor, constant: -FlowSpacing.md),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.lg),

            freeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            freeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            bar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.md),
            bar.heightAnchor.constraint(equalToConstant: 6.0),

            videoFill.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            videoFill.topAnchor.constraint(equalTo: bar.topAnchor),
            videoFill.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            videoWidthConstraint,

            musicFill.leadingAnchor.constraint(equalTo: videoFill.trailingAnchor),
            musicFill.topAnchor.constraint(equalTo: bar.topAnchor),
            musicFill.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            musicWidthConstraint,

            videosLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            videosLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: FlowSpacing.sm),

            musicLabel.leadingAnchor.constraint(equalTo: videosLabel.trailingAnchor, constant: FlowSpacing.xl),
            musicLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -FlowSpacing.xl),
            musicLabel.centerYAnchor.constraint(equalTo: videosLabel.centerYAnchor),

            wifiBanner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            wifiBanner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            wifiBanner.topAnchor.constraint(equalTo: videosLabel.bottomAnchor, constant: FlowSpacing.md),
            wifiBanner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.lg),
            wifiBanner.heightAnchor.constraint(equalToConstant: 32.0),

            wifiIcon.leadingAnchor.constraint(equalTo: wifiBanner.leadingAnchor, constant: FlowSpacing.md),
            wifiIcon.centerYAnchor.constraint(equalTo: wifiBanner.centerYAnchor),
            wifiIcon.widthAnchor.constraint(equalToConstant: 16.0),
            wifiIcon.heightAnchor.constraint(equalToConstant: 16.0),

            wifiLabel.leadingAnchor.constraint(equalTo: wifiIcon.trailingAnchor, constant: FlowSpacing.sm),
            wifiLabel.trailingAnchor.constraint(equalTo: wifiBanner.trailingAnchor, constant: -FlowSpacing.md),
            wifiLabel.centerYAnchor.constraint(equalTo: wifiBanner.centerYAnchor),
        ])
        applyTheme()
    }

    /// Sets the card's figures, in bytes.
    func configure(used: Int64, free: Int64, videos: Int64, music: Int64, showsWifiOnly: Bool) {
        let usedText = Formatters.fileSize(used)
        let freeText = Formatters.fileSize(free)
        let videoText = Formatters.fileSize(videos)
        let musicText = Formatters.fileSize(music)
        titleLabel.text = "\(usedText) in Flow"
        freeLabel.text = "\(freeText) free"
        videosLabel.text = "Videos \(videoText)"
        musicLabel.text = "Music \(musicText)"
        wifiBanner.isHidden = !showsWifiOnly

        let total = max(Double(videos + music), 1.0)
        videoFraction = CGFloat(Double(videos) / total)
        musicFraction = CGFloat(Double(music) / total)
        accessibilityLabel = "\(usedText) used by Flow, \(freeText) free. Videos \(videoText), music \(musicText)."
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(bar.bounds.width, 0.0)
        videoWidth?.constant = width * videoFraction
        musicWidth?.constant = width * musicFraction
    }

    /// Repaints the card in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = scheme.surfaceContainerLow
        titleLabel.textColor = scheme.onSurface
        freeLabel.textColor = scheme.onSurfaceVariant
        bar.backgroundColor = scheme.surfaceContainerHighest
        videoFill.backgroundColor = scheme.primary
        musicFill.backgroundColor = scheme.secondary
        videosLabel.textColor = scheme.onSurfaceVariant
        musicLabel.textColor = scheme.onSurfaceVariant
        wifiBanner.backgroundColor = scheme.secondaryContainer
        wifiIcon.iconColor = scheme.onSecondaryContainer
        wifiLabel.textColor = scheme.onSecondaryContainer
    }

}

/// The table cell that hosts `DownloadsStorageCard`, kept as its own type so the card is built once
/// per reuse rather than once per reload.
final class DownloadsStorageCell: UITableViewCell {

    static let reuseIdentifier = "DownloadsStorageCell"

    private let card = DownloadsStorageCard()

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
        selectionStyle = .none
        contentView.addSubviewForAutoLayout(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.xs),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.xs),
        ])
    }

    /// Sets the card's figures, in bytes.
    func configure(used: Int64, free: Int64, videos: Int64, music: Int64, showsWifiOnly: Bool) {
        card.configure(used: used, free: free, videos: videos, music: music, showsWifiOnly: showsWifiOnly)
    }

    /// Repaints the card in the current palette.
    func applyTheme() {
        card.applyTheme()
    }
}

// MARK: - Section header

/// "In progress" / "Downloaded", with the one bulk action each block offers.
final class DownloadsSectionHeader: UITableViewHeaderFooterView {

    static let reuseIdentifier = "DownloadsSectionHeader"

    private let label = UILabel()
    private let actionButton = FlowButton.make("", style: .text)

    /// Called when the trailing action is tapped.
    var onAction: (() -> Void)?

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

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.onTap = { [weak self] in self?.onAction?() }
        contentView.addSubview(actionButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            actionButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            actionButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            actionButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: FlowSpacing.md),

            contentView.heightAnchor.constraint(equalToConstant: 52.0),
        ])
        applyTheme()
    }

    /// Sets the heading and its action.
    func configure(title: String, actionTitle: String?) {
        label.text = title
        actionButton.isHidden = (actionTitle ?? "").isEmpty
        if let action = actionTitle {
            actionButton.setTitle(action)
        }
    }

    /// Repaints the header in the current palette.
    func applyTheme() {
        label.textColor = FlowTheme.shared.scheme.onSurface
        actionButton.applyTheme()
    }
}

// MARK: - Row

/// One download. An in-flight row shows its progress and pause/resume/cancel; a finished row shows
/// its size and plays on tap.
final class DownloadRowCell: UITableViewCell {

    static let reuseIdentifier = "DownloadRowCell"

    private let thumbnail = AsyncImageView.make(cornerRadius: FlowShapes.thumbnail)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let progressLabel = UILabel()
    private let primaryButton: FlowIconButton = {
        let button = FlowIconButton()
        button.configure(icon: .pause, color: .clear, size: 22.0)
        return button
    }()
    private let cancelButton: FlowIconButton = {
        let button = FlowIconButton()
        button.configure(icon: .close, color: .clear, size: 20.0)
        return button
    }()
    private var progressWidth: NSLayoutConstraint?
    private var fraction: CGFloat = 0.0
    private var record: DownloadRecord?

    /// Called when a finished row is tapped.
    var onPlay: (() -> Void)?
    /// Called when the pause control is tapped.
    var onPause: (() -> Void)?
    /// Called when the resume control is tapped.
    var onResume: (() -> Void)?
    /// Called when a failed row's retry control is tapped.
    var onRetry: (() -> Void)?
    /// Called when the cancel control is tapped.
    var onCancel: (() -> Void)?
    /// Called when a finished row's delete control is tapped.
    var onDelete: (() -> Void)?

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

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 1
        contentView.addSubview(detailLabel)

        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.layer.cornerRadius = 2.0
        progressTrack.layer.masksToBounds = true
        contentView.addSubview(progressTrack)

        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)

        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = FlowTypography.labelSmall
        progressLabel.textAlignment = .right
        contentView.addSubview(progressLabel)

        primaryButton.addTarget(self, action: #selector(handlePrimary), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(handleCancel), for: .touchUpInside)
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(primaryButton)
        contentView.addSubview(cancelButton)

        let fillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0.0)
        progressWidth = fillWidth

        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            thumbnail.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.md),
            thumbnail.widthAnchor.constraint(equalToConstant: 96.0),
            thumbnail.heightAnchor.constraint(equalToConstant: 54.0),

            titleLabel.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -FlowSpacing.xs),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.md),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),

            progressTrack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: progressLabel.leadingAnchor, constant: -FlowSpacing.md),
            progressTrack.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: FlowSpacing.sm),
            progressTrack.heightAnchor.constraint(equalToConstant: 4.0),
            progressTrack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            fillWidth,

            progressLabel.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -FlowSpacing.md),
            progressLabel.centerYAnchor.constraint(equalTo: progressTrack.centerYAnchor),
            progressLabel.widthAnchor.constraint(equalToConstant: 40.0),

            primaryButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -FlowSpacing.xs),
            primaryButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            primaryButton.widthAnchor.constraint(equalToConstant: 40.0),
            primaryButton.heightAnchor.constraint(equalToConstant: 40.0),

            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.sm),
            cancelButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 40.0),
            cancelButton.heightAnchor.constraint(equalToConstant: 40.0),
        ])
        applyTheme()
    }

    /// Sets the row's content from a download record.
    func configure(with record: DownloadRecord) {
        self.record = record
        thumbnail.setImage(url: record.thumbnailUrl, targetSize: CGSize(width: 192.0, height: 108.0))
        titleLabel.text = record.title

        var parts: [String] = []
        if !record.channelName.isEmpty {
            parts.append(record.channelName)
        }
        if record.state == .completed {
            parts.append(Formatters.fileSize(record.byteSize))
            if !record.quality.isEmpty {
                parts.append(record.quality)
            }
        } else {
            parts.append(record.state.displayName)
        }
        detailLabel.text = parts.joined(separator: " · ")

        let isFinished = record.state == .completed
        progressTrack.isHidden = isFinished
        progressLabel.isHidden = isFinished
        fraction = CGFloat(min(max(record.progress, 0.0), 1.0))
        progressWidth?.constant = 0.0
        progressLabel.text = Formatters.percent(record.progress)

        switch record.state {
        case .completed:
            primaryButton.setIcon(.downloaded)
            primaryButton.accessibilityLabel = "Delete download"
            cancelButton.isHidden = true
        case .paused:
            primaryButton.setIcon(.play)
            primaryButton.accessibilityLabel = "Resume"
            cancelButton.isHidden = false
            cancelButton.accessibilityLabel = "Cancel download"
        case .failed:
            primaryButton.setIcon(.sync)
            primaryButton.accessibilityLabel = "Retry"
            cancelButton.isHidden = false
            cancelButton.accessibilityLabel = "Cancel download"
        case .queued, .downloading:
            primaryButton.setIcon(.pause)
            primaryButton.accessibilityLabel = "Pause"
            cancelButton.isHidden = false
            cancelButton.accessibilityLabel = "Cancel download"
        case .cancelled:
            primaryButton.setIcon(.sync)
            primaryButton.accessibilityLabel = "Retry"
            cancelButton.isHidden = false
            cancelButton.accessibilityLabel = "Remove download"
        }
        accessibilityLabel = "\(record.title), \(detailLabel.text ?? "")"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        progressWidth?.constant = max(progressTrack.bounds.width, 0.0) * fraction
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        thumbnail.applyTheme()
        titleLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        progressLabel.textColor = scheme.onSurfaceVariant
        progressTrack.backgroundColor = scheme.surfaceContainerHighest
        progressFill.backgroundColor = scheme.primary
        primaryButton.setIconColor(scheme.onSurfaceVariant)
        cancelButton.setIconColor(scheme.onSurfaceVariant)
        selectedBackgroundView?.backgroundColor = scheme.surfaceContainerHigh
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        record = nil
        thumbnail.clearImage()
        titleLabel.text = nil
        detailLabel.text = nil
        progressLabel.text = nil
        fraction = 0.0
        progressWidth?.constant = 0.0
        onPlay = nil
        onPause = nil
        onResume = nil
        onRetry = nil
        onCancel = nil
        onDelete = nil
    }

    @objc private func handlePrimary() {
        guard let record = record else { return }
        switch record.state {
        case .completed:
            onDelete?()
        case .paused, .cancelled:
            onResume?()
        case .failed:
            onRetry?()
        case .queued, .downloading:
            onPause?()
        }
    }

    @objc private func handleCancel() {
        onCancel?()
    }
}

// MARK: - Free space

/// The storage card's free-space figure. It lives on its own type so the arithmetic is in one place.
enum DownloadStoreViewController {

    /// The bytes free on the volume the media directory lives on.
    static func freeSpace() -> Int64 {
        let url = DownloadStore.mediaDirectory
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        let values = try? url.resourceValues(forKeys: keys)
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return Int64(max(capacity, 0))
        }
        // Devices that do not report the modern key fall back to the older one, which is present on
        // every iOS 12 volume.
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        if let free = attributes?[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return 0
    }
}

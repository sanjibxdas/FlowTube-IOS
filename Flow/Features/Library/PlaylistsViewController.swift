import UIKit

/// Playlists: the ones the viewer made and the ones saved from YouTube, with create, rename, delete
/// and reorder.
///
/// The Android screen offers kind chips, an ownership filter, four orders and a grid/list toggle.
/// The store keeps no video/music kind for a playlist — a local playlist holds whatever was added to
/// it — so the port keeps the ownership filter, the orders and the toggle, and leaves the kind chips
/// out rather than inventing a classification the data cannot support. Custom order is persisted here
/// under a key this screen owns, because the store orders playlists by their last update.
final class PlaylistsViewController: UIViewController {

    // MARK: - Filters

    /// Which playlists are shown.
    enum Ownership: Int, CaseIterable {
        case all
        case owned
        case saved

        var title: String {
            switch self {
            case .all: return "All"
            case .owned: return "Owned"
            case .saved: return "Saved"
            }
        }
    }

    /// The order the list is shown in.
    enum Order: Int, CaseIterable {
        case newest
        case oldest
        case name
        case custom

        var title: String {
            switch self {
            case .newest: return "Newest"
            case .oldest: return "Oldest"
            case .name: return "Name"
            case .custom: return "Custom order"
            }
        }
    }

    // MARK: - Views

    private let filterRow = FlowChipRow()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let collectionView: UICollectionView
    private let layout = UICollectionViewFlowLayout()
    private let emptyState = FlowEmptyState.make(kind: .noPlaylists)
    /// Built without a target: the action is attached once the owner is loaded, because a
    /// stored property cannot refer to `self` while the owner is still being initialised.
    private let addButton: FlowIconButton = {
        let button = FlowIconButton()
        button.configure(icon: .add, color: .clear, size: 24.0)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private let reorderButton = UIBarButtonItem()

    // MARK: - State

    /// Set before presentation when the screen should open the create dialog immediately.
    var startsInCreateMode = false

    private var playlists: [StoredPlaylist] = []
    private var visible: [StoredPlaylist] = []
    private var ownership: Ownership = .all
    private var order: Order = .newest
    private var showsGrid = false
    private var isReordering = false
    private var tokens: [ObservationToken] = []

    /// The saved custom order, as playlist ids. Ids the store no longer has are ignored.
    private var customOrder: [String] = []

    private static let customOrderKey = "library.playlistOrder"
    private static let gridKey = "library.playlistsAsGrid"

    // MARK: - Construction

    init() {
        layout.minimumLineSpacing = FlowSpacing.lg
        layout.minimumInteritemSpacing = FlowSpacing.lg
        layout.sectionInset = UIEdgeInsets(
            top: FlowSpacing.md,
            left: FlowSpacing.screenMargin,
            bottom: FlowSpacing.xxl,
            right: FlowSpacing.screenMargin
        )
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        layout.minimumLineSpacing = FlowSpacing.lg
        layout.minimumInteritemSpacing = FlowSpacing.lg
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(coder: coder)
    }

    deinit {
        for token in tokens {
            token.cancelObservation()
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Playlists"
        view.backgroundColor = FlowTheme.shared.background
        loadPreferences()
        buildViews()
        observeStores()
        applyTheme()
        reload()
        if startsInCreateMode {
            startsInCreateMode = false
            DispatchQueue.main.async { [weak self] in
                self?.presentCreateDialog()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    // MARK: - Build

    private func buildViews() {
        filterRow.onSelect = { [weak self] index in
            guard let self = self else { return }
            // The first three chips are the ownership filter; the last is the order menu.
            if index < Ownership.allCases.count {
                self.ownership = Ownership(rawValue: index) ?? .all
                self.applyFilters()
            } else {
                self.presentOrderMenu()
                self.filterRow.select(index: self.ownership.rawValue)
            }
        }
        rebuildFilterChips()

        addButton.accessibilityLabel = "Create playlist"
        addButton.addTarget(self, action: #selector(showCreateMenu), for: .touchUpInside)
        addButton.widthAnchor.constraint(equalToConstant: 44.0).isActive = true

        reorderButton.target = self
        reorderButton.action = #selector(toggleReorder)
        reorderButton.title = "Reorder"
        navigationItem.rightBarButtonItems = [UIBarButtonItem(customView: addButton), reorderButton]

        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubviewForAutoLayout(filterRow)
        view.addSubview(header)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 76.0
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(PlaylistRowCell.self, forCellReuseIdentifier: PlaylistRowCell.reuseIdentifier)
        view.addSubview(tableView)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PlaylistGridCell.self, forCellWithReuseIdentifier: PlaylistGridCell.reuseIdentifier)
        collectionView.isHidden = true
        view.addSubview(collectionView)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        emptyState.onAction = { [weak self] in
            self?.presentCreateDialog()
        }
        view.addSubview(emptyState)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 48.0),

            filterRow.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            filterRow.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            filterRow.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: header.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func rebuildFilterChips() {
        var titles = Ownership.allCases.map { $0.title }
        titles.append(order.title)
        filterRow.setTitles(titles, selectedIndex: ownership.rawValue)
    }

    private func observeStores() {
        tokens.append(FlowEventBus.shared.on("playlists") { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async { self.reload() }
        })
        tokens.append(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
    }

    // MARK: - Preferences

    private func loadPreferences() {
        customOrder = UserDefaults.standard.stringArray(forKey: PlaylistsViewController.customOrderKey) ?? []
        showsGrid = UserDefaults.standard.bool(forKey: PlaylistsViewController.gridKey)
    }

    private func persistCustomOrder() {
        UserDefaults.standard.set(customOrder, forKey: PlaylistsViewController.customOrderKey)
    }

    // MARK: - Loading

    private func reload() {
        playlists = PlaylistStore.shared.allPlaylists()
        applyFilters()
    }

    private func applyFilters() {
        var result = playlists
        switch ownership {
        case .all:
            break
        case .owned:
            result = result.filter { $0.isLocal }
        case .saved:
            result = result.filter { !$0.isLocal }
        }

        switch order {
        case .newest:
            result.sort { $0.updatedAt > $1.updatedAt }
        case .oldest:
            result.sort { $0.updatedAt < $1.updatedAt }
        case .name:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .custom:
            // Playlists with no place in the saved order keep the store's order behind the ones that
            // have one, so a newly created playlist still appears.
            var ranked: [String: Int] = [:]
            for (index, identifier) in customOrder.enumerated() {
                ranked[identifier] = index
            }
            result.sort { left, right in
                let leftRank = ranked[left.playlistId] ?? Int.max
                let rightRank = ranked[right.playlistId] ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                return left.updatedAt > right.updatedAt
            }
        }
        visible = result
        emptyState.isHidden = !visible.isEmpty
        tableView.isHidden = visible.isEmpty || showsGrid
        collectionView.isHidden = visible.isEmpty || !showsGrid
        tableView.reloadData()
        collectionView.reloadData()
    }

    // MARK: - Theme

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        tableView.backgroundColor = scheme.background
        collectionView.backgroundColor = scheme.background
        filterRow.applyTheme()
        emptyState.applyTheme()
        addButton.setIconColor(scheme.onSurface)
        for cell in tableView.visibleCells {
            (cell as? PlaylistRowCell)?.applyTheme()
        }
        for cell in collectionView.visibleCells {
            (cell as? PlaylistGridCell)?.applyTheme()
        }
    }

    // MARK: - Creating

    @objc private func showCreateMenu() {
        let actions: [FlowActionSheetContent.Action] = [
            FlowActionSheetContent.Action(title: "New playlist", icon: .playlist) { [weak self] in
                self?.presentCreateDialog()
            },
            FlowActionSheetContent.Action(title: "Show as grid", icon: .library) { [weak self] in
                self?.setGrid(true)
            },
            FlowActionSheetContent.Action(title: "Show as list", icon: .queue) { [weak self] in
                self?.setGrid(false)
            },
        ]
        LibraryMenu.present(from: self, title: "Playlists", actions: actions)
    }

    /// The order menu the last chip opens. The chip itself shows the current order, so the sheet
    /// carries a check against the active one rather than a title that repeats it.
    private func presentOrderMenu() {
        let actions: [FlowActionSheetContent.Action] = Order.allCases.map { candidate in
            FlowActionSheetContent.Action(
                title: candidate.title,
                icon: candidate == order ? FlowIcon.check : nil
            ) { [weak self] in
                guard let self = self else { return }
                self.order = candidate
                self.rebuildFilterChips()
                self.applyFilters()
            }
        }
        LibraryMenu.present(from: self, title: "Sort playlists", actions: actions)
    }

    private func setGrid(_ grid: Bool) {
        guard showsGrid != grid else { return }
        showsGrid = grid
        UserDefaults.standard.set(grid, forKey: PlaylistsViewController.gridKey)
        applyFilters()
    }

    private func presentCreateDialog() {
        let alert = UIAlertController(
            title: "Create new playlist",
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Name"
            field.autocapitalizationType = .sentences
        }
        alert.addTextField { field in
            field.placeholder = "Description (optional)"
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let fields = alert?.textFields ?? []
            let title = (fields.first?.text ?? "").trimmed
            guard !title.isEmpty else {
                FlowSnackbar.showError("A playlist needs a name.")
                return
            }
            let description = fields.count > 1 ? (fields[1].text ?? "").trimmed : ""
            let identifier = PlaylistStore.shared.createPlaylist(title: title, description: description)
            self.reload()
            self.openPlaylist(identifier)
        })
        present(alert, animated: true, completion: nil)
    }

    // MARK: - Editing

    private func presentRenameDialog(_ playlist: StoredPlaylist) {
        let alert = UIAlertController(title: "Rename Playlist", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = playlist.title
            field.placeholder = "Name"
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            let title = (alert.textFields?.first?.text ?? "").trimmed
            guard !title.isEmpty else {
                FlowSnackbar.showError("A playlist needs a name.")
                return
            }
            PlaylistStore.shared.renamePlaylist(id: playlist.playlistId, title: title)
            self?.reload()
        })
        present(alert, animated: true, completion: nil)
    }

    private func confirmDelete(_ playlist: StoredPlaylist) {
        let alert = UIAlertController(
            title: "Delete playlist?",
            message: "This will permanently delete '\(playlist.title)' and all its videos.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            PlaylistStore.shared.deletePlaylist(id: playlist.playlistId)
            self?.customOrder.removeAll { $0 == playlist.playlistId }
            self?.persistCustomOrder()
            self?.reload()
            FlowSnackbar.show("Playlist deleted")
        })
        present(alert, animated: true, completion: nil)
    }

    private func presentActions(for playlist: StoredPlaylist) {
        var actions: [FlowActionSheetContent.Action] = [
            FlowActionSheetContent.Action(title: "Open", icon: .playlist) { [weak self] in
                self?.openPlaylist(playlist.playlistId)
            },
            FlowActionSheetContent.Action(title: "Download", icon: .download) { [weak self] in
                self?.downloadAll(playlist)
            },
        ]
        if playlist.isLocal {
            actions.append(FlowActionSheetContent.Action(title: "Rename", icon: .edit) { [weak self] in
                self?.presentRenameDialog(playlist)
            })
        }
        actions.append(FlowActionSheetContent.Action(title: "Delete", icon: .trash, isDestructive: true) { [weak self] in
            self?.confirmDelete(playlist)
        })
        LibraryMenu.present(from: self, title: playlist.title, actions: actions)
    }

    /// Queues every item of the playlist for download at the configured quality.
    private func downloadAll(_ playlist: StoredPlaylist) {
        let quality = FlowApp.shared.prefs.string(for: PrefsStore.Key.downloadQuality) ?? "720"
        var queued = 0
        for item in playlist.items where !DownloadStore.shared.isDownloaded(videoId: item.videoId) {
            DownloadStore.shared.enqueue(
                videoId: item.videoId,
                title: item.title,
                channelName: item.channelName,
                thumbnailUrl: item.thumbnailUrl,
                quality: quality,
                duration: item.duration,
                isMusic: false
            )
            queued += 1
        }
        if queued == 0 {
            FlowSnackbar.show("Everything in this playlist is already downloaded")
        } else {
            FlowSnackbar.show("Queued \(queued) video\(queued == 1 ? "" : "s") for download")
        }
    }

    private func openPlaylist(_ identifier: String) {
        let controller = PlaylistViewController(playlistId: identifier, api: FlowApp.shared.youtubeAPI)
        navigationController?.pushViewController(controller, animated: true)
    }

    // MARK: - Reordering

    @objc private func toggleReorder() {
        guard order == .custom else {
            // Reordering only means something in custom order, so switching the mode is the first
            // step rather than a silent no-op.
            order = .custom
            rebuildFilterChips()
            applyFilters()
            FlowSnackbar.show("Switched to custom order. Drag to arrange.")
            return
        }
        isReordering.toggle()
        reorderButton.title = isReordering ? "Done" : "Reorder"
        addButton.isEnabled = !isReordering
        tableView.setEditing(isReordering, animated: true)
        collectionView.isHidden = true
        tableView.isHidden = visible.isEmpty
    }

    private func persistOrderFromVisible() {
        customOrder = visible.map { $0.playlistId }
        persistCustomOrder()
    }
}

// MARK: - Table data

extension PlaylistsViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return visible.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: PlaylistRowCell.reuseIdentifier, for: indexPath)
        guard let row = cell as? PlaylistRowCell, let playlist = visible.element(at: indexPath.row) else {
            return cell
        }
        row.configure(with: playlist, count: PlaylistStore.shared.itemCount(in: playlist.playlistId))
        row.applyTheme()
        return row
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isReordering, let playlist = visible.element(at: indexPath.row) else { return }
        openPlaylist(playlist.playlistId)
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard !isReordering, let playlist = visible.element(at: indexPath.row) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.confirmDelete(playlist)
            completion(true)
        }
        delete.backgroundColor = FlowTheme.shared.scheme.error
        return UISwipeActionsConfiguration(actions: [delete])
    }

    func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        return .none
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        return false
    }

    func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        guard sourceIndexPath.row < visible.count, destinationIndexPath.row < visible.count else { return }
        let moved = visible.remove(at: sourceIndexPath.row)
        visible.insert(moved, at: destinationIndexPath.row)
        persistOrderFromVisible()
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return isReordering && order == .custom
    }
}

// MARK: - Grid data

extension PlaylistsViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return visible.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PlaylistGridCell.reuseIdentifier,
            for: indexPath
        )
        guard let tile = cell as? PlaylistGridCell, let playlist = visible.element(at: indexPath.item) else {
            return cell
        }
        tile.configure(with: playlist, count: PlaylistStore.shared.itemCount(in: playlist.playlistId))
        tile.applyTheme()
        return tile
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let available = collectionView.bounds.width
            - FlowSpacing.screenMargin * 2.0
            - FlowSpacing.lg
        let columns: CGFloat = available > 520.0 ? 3.0 : 2.0
        let width = floor((available - FlowSpacing.lg * (columns - 1.0)) / columns)
        return CGSize(width: max(width, 120.0), height: max(width, 120.0) + 56.0)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let playlist = visible.element(at: indexPath.item) else { return }
        openPlaylist(playlist.playlistId)
    }
}

// MARK: - Row

/// One playlist in list mode: cover, name, item count and an overflow button.
final class PlaylistRowCell: UITableViewCell {

    static let reuseIdentifier = "PlaylistRowCell"

    private let cover = AsyncImageView.make(cornerRadius: FlowShapes.small)
    private let coverPlaceholder = FlowIconView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    /// Built without a target: the action is attached once the owner is loaded, because a
    /// stored property cannot refer to `self` while the owner is still being initialised.
    private let moreButton: FlowIconButton = {
        let button = FlowIconButton()
        button.configure(icon: .more, color: .clear, size: 20.0)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    /// Called when the overflow button is tapped.
    var onMore: (() -> Void)?

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

        cover.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cover)

        coverPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        coverPlaceholder.icon = .playlist
        coverPlaceholder.iconSize = 24.0
        coverPlaceholder.isUserInteractionEnabled = false
        contentView.addSubview(coverPlaceholder)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 1
        contentView.addSubview(detailLabel)

        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.addTarget(self, action: #selector(handleMore), for: .touchUpInside)
        moreButton.accessibilityLabel = "Playlist actions"
        contentView.addSubview(moreButton)

        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            cover.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            cover.widthAnchor.constraint(equalToConstant: 56.0),
            cover.heightAnchor.constraint(equalToConstant: 56.0),

            coverPlaceholder.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            coverPlaceholder.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            coverPlaceholder.widthAnchor.constraint(equalToConstant: 24.0),
            coverPlaceholder.heightAnchor.constraint(equalToConstant: 24.0),

            titleLabel.leadingAnchor.constraint(equalTo: cover.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -FlowSpacing.xs),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),

            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.sm),
            moreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 40.0),
            moreButton.heightAnchor.constraint(equalToConstant: 40.0),
        ])
        applyTheme()
    }

    /// Sets the row's content.
    func configure(with playlist: StoredPlaylist, count: Int) {
        titleLabel.text = playlist.title
        var parts: [String] = []
        parts.append("\(count) \(count == 1 ? "video" : "videos")")
        if !playlist.isLocal {
            parts.append("Saved")
        }
        detailLabel.text = parts.joined(separator: " · ")
        cover.setImage(url: playlist.thumbnailUrl, targetSize: CGSize(width: 112.0, height: 112.0))
        coverPlaceholder.isHidden = !playlist.thumbnailUrl.isEmpty
        accessibilityLabel = "\(playlist.title), \(detailLabel.text ?? "")"
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        cover.applyTheme()
        coverPlaceholder.iconColor = scheme.onSurfaceVariant
        titleLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        moreButton.setIconColor(scheme.onSurfaceVariant)
        selectedBackgroundView?.backgroundColor = scheme.surfaceContainerHigh
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cover.clearImage()
        titleLabel.text = nil
        detailLabel.text = nil
        onMore = nil
    }

    @objc private func handleMore() {
        onMore?()
    }
}

// MARK: - Grid tile

/// One playlist in grid mode: the cover with the name and count underneath.
final class PlaylistGridCell: UICollectionViewCell {

    static let reuseIdentifier = "PlaylistGridCell"

    private let cover = AsyncImageView.make(cornerRadius: FlowShapes.small)
    private let coverPlaceholder = FlowIconView()
    private let titleLabel = UILabel()
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

        cover.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cover)

        coverPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        coverPlaceholder.icon = .playlist
        coverPlaceholder.iconSize = 28.0
        coverPlaceholder.isUserInteractionEnabled = false
        contentView.addSubview(coverPlaceholder)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 1
        contentView.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cover.topAnchor.constraint(equalTo: contentView.topAnchor),
            cover.heightAnchor.constraint(equalTo: cover.widthAnchor),

            coverPlaceholder.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            coverPlaceholder.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            coverPlaceholder.widthAnchor.constraint(equalToConstant: 28.0),
            coverPlaceholder.heightAnchor.constraint(equalToConstant: 28.0),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: FlowSpacing.md),

            detailLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),
        ])
        applyTheme()
    }

    /// Sets the tile's content.
    func configure(with playlist: StoredPlaylist, count: Int) {
        titleLabel.text = playlist.title
        detailLabel.text = "\(count) \(count == 1 ? "video" : "videos")"
        cover.setImage(url: playlist.thumbnailUrl, targetSize: CGSize(width: 320.0, height: 320.0))
        coverPlaceholder.isHidden = !playlist.thumbnailUrl.isEmpty
        accessibilityLabel = "\(playlist.title), \(detailLabel.text ?? "")"
    }

    /// Repaints the tile in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        cover.applyTheme()
        coverPlaceholder.iconColor = scheme.onSurfaceVariant
        titleLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cover.clearImage()
        titleLabel.text = nil
        detailLabel.text = nil
    }
}

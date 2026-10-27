import UIKit

/// The Library tab: the viewer's own content, one row per destination, each carrying a live count.
///
/// The Android screen draws preview shelves above these rows. On a phone-sized screen the rows are
/// the part that stays useful, so the port keeps the row list, the counts and the section order and
/// leaves the previews to the screens themselves. Long-pressing a row opens the actions the Android
/// overflow menu offers for that section, and Edit mode hides a section the viewer does not use.
final class LibraryViewController: UIViewController {

    // MARK: - Sections

    /// Everything the library can link to, in the order the Android screen lists it.
    enum Section: String, CaseIterable {
        case history
        case playlists
        case downloads
        case savedShorts
        case localMedia
        case notes
        case settings

        var title: String {
            switch self {
            case .history: return "History"
            case .playlists: return "Playlists"
            case .downloads: return "Downloads"
            case .savedShorts: return "Saved Shorts"
            case .localMedia: return "Local media"
            case .notes: return "Notes"
            case .settings: return "Settings"
            }
        }

        var icon: FlowIcon {
            switch self {
            case .history: return .clock
            case .playlists: return .playlist
            case .downloads: return .download
            case .savedShorts: return .shorts
            case .localMedia: return .importIcon
            case .notes: return .notes
            case .settings: return .settings
            }
        }

        /// The sections that hold content, listed under "Your Content".
        var isContent: Bool {
            switch self {
            case .history, .playlists, .downloads, .savedShorts:
                return true
            case .localMedia, .notes, .settings:
                return false
            }
        }
    }

    /// The counts the rows show. Read once per appearance and after any store change, so a row never
    /// shows a stale number.
    private struct Counts {
        var history = 0
        var playlists = 0
        var downloadedVideos = 0
        var downloadedMusic = 0
        var savedShorts = 0
        var notes = 0
    }

    // MARK: - Views

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let editButton = UIBarButtonItem()

    // MARK: - State

    private var counts = Counts()
    private var isEditingSections = false
    private var hiddenSections: Set<String> = []
    private var tokens: [ObservationToken] = []

    /// Where the viewer's hidden sections are remembered. `PrefsStore` has no key for a library-only
    /// display choice, and the value must survive a preferences reset, so it lives under a key this
    /// screen owns.
    private static let hiddenSectionsKey = "library.hiddenSections"

    private var contentSections: [Section] {
        let all = Section.allCases.filter { $0.isContent }
        guard !isEditingSections else { return all }
        return all.filter { !hiddenSections.contains($0.rawValue) }
    }

    private var dataSections: [Section] {
        let all = Section.allCases.filter { !$0.isContent }
        guard !isEditingSections else { return all }
        return all.filter { !hiddenSections.contains($0.rawValue) }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        view.backgroundColor = FlowTheme.shared.background
        loadHiddenSections()
        buildTable()
        buildNavigation()
        observeStores()
        reloadCounts()
        applyTheme()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadCounts()
        tableView.reloadData()
    }

    deinit {
        for token in tokens {
            token.cancelObservation()
        }
    }

    // MARK: - Construction

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 72.0
        tableView.estimatedRowHeight = 72.0
        tableView.sectionHeaderHeight = 44.0
        tableView.contentInset = UIEdgeInsets(top: FlowSpacing.md, left: 0, bottom: FlowSpacing.xxl, right: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(LibrarySectionRowCell.self, forCellReuseIdentifier: LibrarySectionRowCell.reuseIdentifier)
        tableView.register(
            LibraryGroupHeaderView.self,
            forHeaderFooterViewReuseIdentifier: LibraryGroupHeaderView.reuseIdentifier
        )
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        tableView.addGestureRecognizer(longPress)
    }

    private func buildNavigation() {
        editButton.target = self
        editButton.action = #selector(toggleEditingSections)
        editButton.title = "Edit"
        navigationItem.rightBarButtonItem = editButton
    }

    /// Re-reads every count. Each call is a handful of indexed SQLite queries, so it is cheap enough
    /// to run whenever the screen appears or a store reports a change.
    private func reloadCounts() {
        var fresh = Counts()
        fresh.history = HistoryStore.shared.count
        fresh.playlists = PlaylistStore.shared.allPlaylists().count
        for record in DownloadStore.shared.completed() {
            if record.isMusic {
                fresh.downloadedMusic += 1
            } else {
                fresh.downloadedVideos += 1
            }
        }
        fresh.savedShorts = SavedShortsStore.shared.all().count
        fresh.notes = NoteStore.shared.totalCount
        counts = fresh
    }

    private func observeStores() {
        let names = ["history", "playlists", "downloads", "notes", "shorts"]
        for name in names {
            tokens.append(FlowEventBus.shared.on(name) { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.reloadCounts()
                    self.tableView.reloadData()
                }
            })
        }
        tokens.append(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
    }

    // MARK: - Theme

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        tableView.backgroundColor = scheme.background
        tableView.separatorColor = scheme.outlineVariant
        for cell in tableView.visibleCells {
            (cell as? LibrarySectionRowCell)?.applyTheme()
        }
        for section in 0..<tableView.numberOfSections {
            (tableView.headerView(forSection: section) as? LibraryGroupHeaderView)?.applyTheme()
        }
        navigationController?.navigationBar.tintColor = scheme.primary
    }

    // MARK: - Editing

    @objc private func toggleEditingSections() {
        isEditingSections.toggle()
        editButton.title = isEditingSections ? "Done" : "Edit"
        tableView.reloadData()
        FlowMotion.animate {
            self.tableView.layoutIfNeeded()
        }
    }

    private func loadHiddenSections() {
        hiddenSections = Set(UserDefaults.standard.stringArray(forKey: LibraryViewController.hiddenSectionsKey) ?? [])
    }

    private func persistHiddenSections() {
        UserDefaults.standard.set(Array(hiddenSections), forKey: LibraryViewController.hiddenSectionsKey)
    }

    private func setSection(_ section: Section, hidden: Bool) {
        if hidden {
            hiddenSections.insert(section.rawValue)
        } else {
            hiddenSections.remove(section.rawValue)
        }
        persistHiddenSections()
        tableView.reloadData()
    }

    // MARK: - Lookup

    private func section(at indexPath: IndexPath) -> Section? {
        let list = indexPath.section == 0 ? contentSections : dataSections
        guard indexPath.row >= 0, indexPath.row < list.count else { return nil }
        return list[indexPath.row]
    }

    private func subtitle(for section: Section) -> String {
        switch section {
        case .history:
            return LibraryViewController.countText(counts.history, singular: "item", plural: "items")
        case .playlists:
            return LibraryViewController.countText(counts.playlists, singular: "playlist", plural: "playlists")
        case .downloads:
            if counts.downloadedVideos == 0 && counts.downloadedMusic == 0 {
                return "No downloads yet"
            }
            var parts: [String] = []
            if counts.downloadedVideos > 0 {
                parts.append(LibraryViewController.countText(counts.downloadedVideos, singular: "video", plural: "videos"))
            }
            if counts.downloadedMusic > 0 {
                parts.append(LibraryViewController.countText(counts.downloadedMusic, singular: "song", plural: "songs"))
            }
            return parts.joined(separator: " · ")
        case .savedShorts:
            return LibraryViewController.countText(counts.savedShorts, singular: "Short", plural: "Shorts")
        case .localMedia:
            return "Play videos and music on this device"
        case .notes:
            if counts.notes == 0 {
                return "Your notes on videos and channels"
            }
            return LibraryViewController.countText(counts.notes, singular: "note", plural: "notes")
        case .settings:
            return "Playback, downloads, appearance and data"
        }
    }

    private static func countText(_ count: Int, singular: String, plural: String) -> String {
        return "\(count) \(count == 1 ? singular : plural)"
    }

    // MARK: - Navigation

    private func open(_ section: Section) {
        switch section {
        case .history:
            navigationController?.pushViewController(HistoryViewController(), animated: true)
        case .playlists:
            navigationController?.pushViewController(PlaylistsViewController(), animated: true)
        case .downloads:
            navigationController?.pushViewController(DownloadsViewController(), animated: true)
        case .savedShorts:
            navigationController?.pushViewController(SavedShortsViewController(), animated: true)
        case .localMedia:
            navigationController?.pushViewController(LocalMediaViewController(), animated: true)
        case .notes:
            navigationController?.pushViewController(LibraryNotesListController(), animated: true)
        case .settings:
            // The settings feature registers this route during launch; the router reports a link it
            // cannot open instead of dropping the tap.
            Router.shared.openSettings()
        }
    }

    // MARK: - Long press

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let point = recognizer.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point), let section = section(at: indexPath) else {
            return
        }
        presentMenu(for: section)
    }

    private func presentMenu(for section: Section) {
        var actions: [FlowActionSheetContent.Action] = []
        actions.append(FlowActionSheetContent.Action(title: "Open \(section.title)", icon: section.icon) { [weak self] in
            self?.open(section)
        })

        switch section {
        case .history:
            actions.append(FlowActionSheetContent.Action(title: "Clear watch history", icon: .trash, isDestructive: true) { [weak self] in
                self?.confirmClearHistory()
            })
        case .playlists:
            actions.append(FlowActionSheetContent.Action(title: "New playlist", icon: .add) { [weak self] in
                let controller = PlaylistsViewController()
                controller.startsInCreateMode = true
                self?.navigationController?.pushViewController(controller, animated: true)
            })
        case .downloads:
            actions.append(FlowActionSheetContent.Action(title: "Delete all downloads", icon: .trash, isDestructive: true) { [weak self] in
                self?.confirmDeleteAllDownloads()
            })
        case .savedShorts:
            actions.append(FlowActionSheetContent.Action(title: "Clear saved Shorts", icon: .trash, isDestructive: true) { [weak self] in
                self?.confirmClearSavedShorts()
            })
        case .notes:
            actions.append(FlowActionSheetContent.Action(title: "Delete all notes", icon: .trash, isDestructive: true) { [weak self] in
                self?.confirmDeleteAllNotes()
            })
        case .localMedia, .settings:
            break
        }

        let isHidden = hiddenSections.contains(section.rawValue)
        actions.append(FlowActionSheetContent.Action(
            title: isHidden ? "Show section" : "Hide section",
            icon: isHidden ? .add : .close
        ) { [weak self] in
            self?.setSection(section, hidden: !isHidden)
        })

        LibraryMenu.present(from: self, title: section.title, actions: actions)
    }

    // MARK: - Confirmations

    private func confirmClearHistory() {
        let alert = UIAlertController(
            title: "Clear watch history?",
            message: "This will remove all videos from your watch history. This action cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            HistoryStore.shared.clear()
            FlowSnackbar.show("Watch history cleared")
        })
        present(alert, animated: true, completion: nil)
    }

    private func confirmDeleteAllDownloads() {
        let alert = UIAlertController(
            title: "Delete all downloads?",
            message: "Every downloaded video and song will be removed from this device.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            DownloadStore.shared.removeAll()
            FlowSnackbar.show("Downloads deleted")
        })
        present(alert, animated: true, completion: nil)
    }

    private func confirmClearSavedShorts() {
        let alert = UIAlertController(
            title: "Clear saved Shorts?",
            message: "Every saved Short will be removed from your library.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            SavedShortsStore.shared.clear()
            FlowSnackbar.show("Saved Shorts cleared")
        })
        present(alert, animated: true, completion: nil)
    }

    private func confirmDeleteAllNotes() {
        let alert = UIAlertController(
            title: "Delete all notes?",
            message: "Every note you have written will be deleted. This action cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            NoteStore.shared.deleteAll()
            FlowSnackbar.show("Notes deleted")
        })
        present(alert, animated: true, completion: nil)
    }
}

// MARK: - Table data

extension LibraryViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? contentSections.count : dataSections.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: LibrarySectionRowCell.reuseIdentifier,
            for: indexPath
        )
        guard let row = cell as? LibrarySectionRowCell, let section = section(at: indexPath) else {
            return cell
        }
        let isHidden = hiddenSections.contains(section.rawValue)
        row.configure(
            icon: section.icon,
            title: section.title,
            subtitle: subtitle(for: section),
            isVisible: !isHidden,
            editing: isEditingSections
        )
        row.onToggle = { [weak self] visible in
            self?.setSection(section, hidden: !visible)
        }
        row.applyTheme()
        return row
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: LibraryGroupHeaderView.reuseIdentifier
        ) as? LibraryGroupHeaderView else {
            return nil
        }
        header.configure(title: section == 0 ? "Your Content" : "Settings & Data")
        header.applyTheme()
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 44.0
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return FlowSpacing.md
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return UIView(frame: .zero)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isEditingSections, let section = section(at: indexPath) else { return }
        open(section)
    }
}

// MARK: - Row

/// One destination: a circular icon, the section name, its live count and a chevron. In Edit mode a
/// switch replaces the chevron and controls whether the section appears in the library.
final class LibrarySectionRowCell: UITableViewCell {

    static let reuseIdentifier = "LibrarySectionRowCell"

    private let iconContainer = UIView()
    private let iconView = FlowIconView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevron = FlowIconView()
    private let toggle = UISwitch()

    private var toggleHandler: ((Bool) -> Void)?

    /// Called when the Edit-mode switch changes.
    var onToggle: ((Bool) -> Void)? {
        get { return toggleHandler }
        set { toggleHandler = newValue }
    }

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

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.cornerRadius = 24.0
        iconContainer.layer.masksToBounds = true
        contentView.addSubview(iconContainer)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.iconSize = 24.0
        iconContainer.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleMediumEmphasized
        titleLabel.numberOfLines = 1
        contentView.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = FlowTypography.bodyMedium
        subtitleLabel.numberOfLines = 2
        contentView.addSubview(subtitleLabel)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.icon = .chevronRight
        chevron.iconSize = 20.0
        contentView.addSubview(chevron)

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.isHidden = true
        toggle.addTarget(self, action: #selector(handleToggle), for: .valueChanged)
        contentView.addSubview(toggle)

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            iconContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 48.0),
            iconContainer.heightAnchor.constraint(equalToConstant: 48.0),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24.0),
            iconView.heightAnchor.constraint(equalToConstant: 24.0),

            titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: FlowSpacing.xl),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -FlowSpacing.md),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -FlowSpacing.md),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),

            chevron.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 20.0),
            chevron.heightAnchor.constraint(equalToConstant: 20.0),

            toggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            toggle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        applyTheme()
    }

    /// Sets the row's content.
    func configure(icon: FlowIcon, title: String, subtitle: String, isVisible: Bool, editing: Bool) {
        iconView.icon = icon
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        chevron.isHidden = editing
        toggle.isHidden = !editing
        toggle.isOn = isVisible
        toggle.accessibilityLabel = "Show \(title) in the library"
        contentView.alpha = editing && !isVisible ? 0.55 : 1.0
        accessibilityLabel = subtitle.isEmpty ? title : "\(title), \(subtitle)"
        accessibilityTraits = .button
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        iconContainer.backgroundColor = scheme.secondaryContainer
        iconView.iconColor = scheme.onSecondaryContainer
        titleLabel.textColor = scheme.onSurface
        subtitleLabel.textColor = scheme.onSurfaceVariant
        chevron.iconColor = scheme.onSurfaceVariant
        toggle.onTintColor = scheme.primary
        selectedBackgroundView?.backgroundColor = scheme.surfaceContainerHigh
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggle = nil
        toggle.isHidden = true
        chevron.isHidden = false
        contentView.alpha = 1.0
    }

    @objc private func handleToggle() {
        onToggle?(toggle.isOn)
    }
}

// MARK: - Group header

/// "Your Content" and "Settings & Data": a caption in the accent colour above each group.
final class LibraryGroupHeaderView: UITableViewHeaderFooterView {

    static let reuseIdentifier = "LibraryGroupHeaderView"

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
        label.font = FlowTypography.titleMediumEmphasized
        label.numberOfLines = 1
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.sm),
        ])
        applyTheme()
    }

    /// Sets the group's caption.
    func configure(title: String) {
        label.text = title
        accessibilityLabel = title
    }

    /// Repaints the caption in the current palette.
    func applyTheme() {
        label.textColor = FlowTheme.shared.scheme.primary
    }
}

// MARK: - Shared library pieces

/// A rounded search field in the Material 3 style, used by the library's list screens. iOS 12 has no
/// `searchTextField`, so the field is built from a container, a glyph and a plain `UITextField`.
final class LibrarySearchField: UIView, UITextFieldDelegate {

    private let container = UIView()
    private let textField = UITextField()
    private let iconView = FlowIconView()
    private var placeholderText: String

    /// Called on every edit.
    var onChange: ((String) -> Void)?

    /// The field's current text.
    var text: String {
        return textField.text ?? ""
    }

    init(placeholder: String) {
        placeholderText = placeholder
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) {
        placeholderText = "Search"
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 20.0
        container.layer.masksToBounds = true
        addSubview(container)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.icon = .search
        iconView.iconSize = 18.0
        container.addSubview(iconView)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = FlowTypography.bodyMedium
        textField.returnKeyType = .search
        textField.clearButtonMode = .whileEditing
        textField.autocorrectionType = .no
        textField.delegate = self
        textField.addTarget(self, action: #selector(handleChange), for: .editingChanged)
        container.addSubview(textField)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 40.0),

            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: FlowSpacing.lg),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18.0),
            iconView.heightAnchor.constraint(equalToConstant: 18.0),

            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: FlowSpacing.md),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -FlowSpacing.lg),
            textField.topAnchor.constraint(equalTo: container.topAnchor),
            textField.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        applyTheme()
    }

    /// Clears the field without notifying the owner.
    func clear() {
        textField.text = ""
    }

    /// Gives up first responder.
    func resign() {
        textField.resignFirstResponder()
    }

    /// Repaints the field in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        container.backgroundColor = scheme.surfaceContainerHigh
        textField.textColor = scheme.onSurface
        textField.tintColor = scheme.primary
        iconView.iconColor = scheme.onSurfaceVariant
        textField.attributedPlaceholder = NSAttributedString(
            string: placeholderText,
            attributes: [.foregroundColor: scheme.onSurfaceVariant]
        )
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func handleChange() {
        onChange?(text)
    }
}

/// Presents a `FlowSheet` holding a list of actions, the iOS 12 equivalent of the Android overflow
/// menu. The sheet closes itself once an action has run.
enum LibraryMenu {

    static func present(
        from controller: UIViewController,
        title: String?,
        actions: [FlowActionSheetContent.Action]
    ) {
        let content = FlowActionSheetContent(actions: actions)
        let sheet = FlowSheet(content: content, title: title, detent: .medium)
        content.onActionSelected = { [weak sheet] in
            sheet?.dismissSheet()
        }
        sheet.present(from: controller)
    }
}

// MARK: - Notes

/// The library's entry point into notes: every note the viewer has written, newest first, with
/// search, swipe-to-delete and a tap that opens the video the note belongs to.
///
/// The Notes feature owns the editing screen; this list is the library row's destination and reads
/// the same `NoteStore`.
final class LibraryNotesListController: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let searchField = LibrarySearchField(placeholder: "Search notes")
    private let emptyState = FlowEmptyState.make(kind: .noNotes)

    private var notes: [VideoNote] = []
    private var query = ""
    private var tokens: [ObservationToken] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notes"
        view.backgroundColor = FlowTheme.shared.background
        buildViews()
        tokens.append(FlowEventBus.shared.on("notes") { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async { self.reload() }
        })
        tokens.append(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
        applyTheme()
        reload()
    }

    deinit {
        for token in tokens {
            token.cancelObservation()
        }
    }

    private func buildViews() {
        searchField.onChange = { [weak self] text in
            self?.query = text
            self?.reload()
        }
        view.addSubviewForAutoLayout(searchField)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 96.0
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(LibraryNoteCell.self, forCellReuseIdentifier: LibraryNoteCell.reuseIdentifier)
        view.addSubview(tableView)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        view.addSubview(emptyState)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.screenMargin),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.screenMargin),
            searchField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: FlowSpacing.md),

            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: FlowSpacing.md),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: searchField.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func reload() {
        let trimmed = query.trimmed
        notes = trimmed.isEmpty ? NoteStore.shared.all() : NoteStore.shared.search(trimmed)
        emptyState.isHidden = !notes.isEmpty
        tableView.reloadData()
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        tableView.backgroundColor = scheme.background
        searchField.applyTheme()
        emptyState.applyTheme()
        for cell in tableView.visibleCells {
            (cell as? LibraryNoteCell)?.applyTheme()
        }
    }

    private func delete(_ note: VideoNote) {
        NoteStore.shared.delete(id: note.id)
        reload()
        FlowSnackbar.show("Note deleted", actionTitle: "Undo") {
            NoteStore.shared.create(
                videoId: note.videoId,
                videoTitle: note.videoTitle,
                channelName: note.channelName,
                body: note.body,
                timestamp: note.timestamp
            )
        }
    }
}

extension LibraryNotesListController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return notes.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LibraryNoteCell.reuseIdentifier, for: indexPath)
        guard let row = cell as? LibraryNoteCell, let note = notes.element(at: indexPath.row) else {
            return cell
        }
        row.configure(with: note)
        row.applyTheme()
        return row
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let note = notes.element(at: indexPath.row) else { return }
        Router.shared.openWatch(videoId: note.videoId)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let note = notes.element(at: indexPath.row) else { return nil }
        let remove = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.delete(note)
            completion(true)
        }
        remove.backgroundColor = FlowTheme.shared.scheme.error
        return UISwipeActionsConfiguration(actions: [remove])
    }
}

/// One note: the video it belongs to, the note body and the moment it was written.
final class LibraryNoteCell: UITableViewCell {

    static let reuseIdentifier = "LibraryNoteCell"

    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let detailLabel = UILabel()

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

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 1
        contentView.addSubview(titleLabel)

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = FlowTypography.bodyMedium
        bodyLabel.numberOfLines = 2
        contentView.addSubview(bodyLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.labelMedium
        detailLabel.numberOfLines = 1
        contentView.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),

            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: FlowSpacing.xs),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),
        ])
        applyTheme()
    }

    /// Sets the row's content from a note.
    func configure(with note: VideoNote) {
        titleLabel.text = note.videoTitle.isEmpty ? note.channelName : note.videoTitle
        bodyLabel.text = note.body
        var parts: [String] = []
        if note.timestamp > 0 {
            parts.append(Formatters.playbackTime(note.timestamp))
        }
        if !note.channelName.isEmpty {
            parts.append(note.channelName)
        }
        parts.append(Formatters.relativeDate(note.updatedAt))
        detailLabel.text = parts.joined(separator: " · ")
        accessibilityLabel = "\(titleLabel.text ?? ""). \(note.body)"
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        bodyLabel.textColor = scheme.onSurfaceVariant
        detailLabel.textColor = scheme.onSurfaceVariant
        selectedBackgroundView?.backgroundColor = scheme.surfaceContainerHigh
    }
}

import UIKit

// MARK: - Search field

/// The music search field: a pill with a magnifier, a text field and a clear button. It is a plain
/// `UITextField` in a rounded container rather than `UISearchController`, because styling the
/// controller's field on iOS 12 needs private key paths.
final class MusicSearchField: UIView, UITextFieldDelegate {

    private let container = UIView()
    private let iconView = FlowIconView()
    private let textField = UITextField()
    private let clearButton = UIButton(type: .custom)

    /// Called on every edit.
    var onChange: ((String) -> Void)?
    /// Called when the keyboard's search key is tapped.
    var onSubmit: ((String) -> Void)?
    /// Called when the field is cleared.
    var onClear: (() -> Void)?

    /// The field's text.
    var text: String {
        return textField.text ?? ""
    }

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

        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = FlowShapes.pill(for: MusicMetrics.searchEntryHeight)
        container.layer.masksToBounds = true
        addSubview(container)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.icon = .search
        iconView.iconSize = 20.0
        container.addSubview(iconView)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = FlowTypography.bodyLarge
        textField.returnKeyType = .search
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.clearButtonMode = .never
        textField.delegate = self
        textField.addTarget(self, action: #selector(handleEditingChanged), for: .editingChanged)
        container.addSubview(textField)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.accessibilityLabel = "Close search"
        clearButton.isHidden = true
        clearButton.addTarget(self, action: #selector(handleClear), for: .touchUpInside)
        container.addSubview(clearButton)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: FlowSpacing.lg),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20.0),
            iconView.heightAnchor.constraint(equalToConstant: 20.0),

            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: FlowSpacing.md),
            textField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -FlowSpacing.xs),
            textField.topAnchor.constraint(equalTo: container.topAnchor),
            textField.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            clearButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -FlowSpacing.sm),
            clearButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 32.0),
            clearButton.heightAnchor.constraint(equalToConstant: 32.0),
        ])
        applyTheme()
    }

    /// Sets the field's text without firing a change.
    func setText(_ text: String) {
        textField.text = text
        clearButton.isHidden = text.isEmpty
    }

    /// Focuses the field.
    func focus() {
        textField.becomeFirstResponder()
    }

    /// Dismisses the keyboard.
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
        clearButton.setImage(FlowIcon.close.image(size: 16.0, color: scheme.onSurfaceVariant), for: .normal)
        let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: scheme.onSurfaceVariant]
        textField.attributedPlaceholder = NSAttributedString(string: "Search songs, albums, artists", attributes: attributes)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onSubmit?(textField.text ?? "")
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        clearButton.isHidden = (textField.text ?? "").isEmpty
    }

    @objc private func handleEditingChanged() {
        let value = textField.text ?? ""
        clearButton.isHidden = value.isEmpty
        onChange?(value)
    }

    @objc private func handleClear() {
        textField.text = ""
        clearButton.isHidden = true
        onChange?("")
        onClear?()
    }
}

// MARK: - Collection row

/// A row for an album, playlist or artist: square (or round) artwork, a title and a subtitle.
final class MusicCollectionRowCell: UITableViewCell {

    static let reuseIdentifier = "MusicCollectionRowCell"

    private let artworkView = AsyncImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let menuButton = FlowIconButton()
    private var artworkSize: CGFloat = MusicMetrics.trackArtworkSize

    /// Called when the row's menu button is tapped.
    var onMenu: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.applyCornerRadius(FlowShapes.extraSmall)
        contentView.addSubview(artworkView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.bodyLarge
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = FlowTypography.bodySmall
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(subtitleLabel)

        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.accessibilityLabel = "More options"
        menuButton.addTarget(self, action: #selector(handleMenu), for: .touchUpInside)
        contentView.addSubview(menuButton)

        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            artworkView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: artworkSize),
            artworkView.heightAnchor.constraint(equalToConstant: artworkSize),

            titleLabel.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.topAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -19.0),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -FlowSpacing.md),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -FlowSpacing.md),

            menuButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.sm),
            menuButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 44.0),
            menuButton.heightAnchor.constraint(equalToConstant: 44.0),
        ])
        applyTheme()
    }

    /// Fills the row. An artist's artwork is round, matching the artist tiles elsewhere.
    func configure(title: String, subtitle: String?, artworkUrl: String?, circularArtwork: Bool, showsMenu: Bool = true) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        artworkView.setImage(url: artworkUrl)
        artworkView.layer.cornerRadius = circularArtwork ? artworkSize / 2.0 : FlowShapes.extraSmall
        menuButton.isHidden = !showsMenu
        accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ", ")
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        subtitleLabel.textColor = scheme.onSurfaceVariant
        menuButton.setIconColor(scheme.onSurfaceVariant)
        artworkView.applyTheme()
    }

    override var isHighlighted: Bool {
        didSet {
            contentView.alpha = isHighlighted ? 0.7 : 1.0
        }
    }

    @objc private func handleMenu() {
        onMenu?()
    }
}

// MARK: - Search

/// Music search: one field, a segmented row of result kinds, and the results below it.
///
/// The screen searches with `MusicSearchFilter`, so a kind's chip is a real request parameter
/// rather than a client-side filter — YouTube returns a different ranking for each kind, and the
/// app shows what YouTube ranked.
final class MusicSearchViewController: UIViewController {

    // MARK: - State

    /// One block of results: the kind's heading and the items under it.
    private struct ResultSection {
        let title: String
        let items: [MusicItem]
    }

    /// The result kinds the segmented row offers, in the order YouTube Music lists them.
    private static let filters: [MusicSearchFilter] = [.all, .songs, .videos, .albums, .artists, .playlists]

    private let api: YouTubeAPI
    private let backButton = FlowIconButton()
    private let searchField = MusicSearchField()
    private let segmentedTabs = FlowSegmentedTabs()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let emptyState = FlowEmptyState.make(kind: .noResults)
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")
    private let debouncer = FlowDebouncer(interval: 0.3)

    private var filter: MusicSearchFilter = .all
    private var query: String = ""
    private var sections: [ResultSection] = []
    private var history: [String] = []
    private var suggestions: [String] = []
    private var isLoading = false
    private var hasSearched = false
    private var themeToken: ObservationToken?

    /// The query the screen was opened with, when it came from a link or from recognition.
    var initialQuery: String?

    // MARK: - Construction

    init(api: YouTubeAPI = YouTubeAPI()) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
        title = "Search"
    }

    required init?(coder: NSCoder) {
        api = YouTubeAPI()
        super.init(coder: coder)
        title = "Search"
    }

    deinit {
        themeToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildBar()
        buildTable()
        buildOverlays()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
        reloadHistory()
        if let query = initialQuery, !query.isBlank {
            searchField.setText(query)
            performSearch(query)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasSearched {
            searchField.focus()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Build

    private func buildBar() {
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.configure(icon: .back, color: FlowTheme.shared.onSurface, size: 22.0)
        backButton.accessibilityLabel = "Back"
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        view.addSubview(backButton)

        searchField.onChange = { [weak self] text in
            self?.handleTextChange(text)
        }
        searchField.onSubmit = { [weak self] text in
            self?.performSearch(text)
        }
        searchField.onClear = { [weak self] in
            self?.showSuggestions()
        }
        view.addSubview(searchField)

        segmentedTabs.translatesAutoresizingMaskIntoConstraints = false
        segmentedTabs.setTitles(MusicSearchViewController.filters.map { MusicSearchViewController.title(for: $0) }, selectedIndex: 0)
        segmentedTabs.onSelect = { [weak self] index in
            guard let self = self else { return }
            self.filter = MusicSearchViewController.filters.element(at: index) ?? .all
            if self.hasSearched {
                self.performSearch(self.query)
            }
        }
        segmentedTabs.isHidden = true
        view.addSubview(segmentedTabs)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.xs),
            backButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: FlowSpacing.md),
            backButton.widthAnchor.constraint(equalToConstant: 44.0),
            backButton.heightAnchor.constraint(equalToConstant: MusicMetrics.searchEntryHeight),

            searchField.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: FlowSpacing.xs),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.xl),
            searchField.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: MusicMetrics.searchEntryHeight),

            segmentedTabs.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            segmentedTabs.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            segmentedTabs.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: FlowSpacing.sm),
            segmentedTabs.heightAnchor.constraint(equalToConstant: 48.0),
        ])
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = MusicMetrics.trackRowHeight
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: FlowSpacing.xxl, right: 0)
        tableView.register(MusicTrackRowCell.self, forCellReuseIdentifier: MusicTrackRowCell.reuseIdentifier)
        tableView.register(MusicCollectionRowCell.self, forCellReuseIdentifier: MusicCollectionRowCell.reuseIdentifier)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: segmentedTabs.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
            self.performSearch(self.query)
        }
        view.addSubview(errorState)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: segmentedTabs.bottomAnchor, constant: FlowSpacing.xxl),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: segmentedTabs.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            errorState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorState.topAnchor.constraint(equalTo: segmentedTabs.bottomAnchor),
            errorState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Searching

    private func handleTextChange(_ text: String) {
        let trimmed = text.trimmed
        if trimmed.isEmpty {
            debouncer.cancel()
            showSuggestions()
            return
        }
        debouncer.schedule { [weak self] in
            self?.loadSuggestions(for: trimmed)
        }
    }

    private func loadSuggestions(for text: String) {
        api.suggestions(query: text) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.searchField.text.trimmed == text else { return }
                if case .success(let values) = result {
                    self.suggestions = values
                    self.tableView.reloadData()
                }
            }
        }
    }

    private func performSearch(_ text: String) {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else {
            showSuggestions()
            return
        }
        debouncer.cancel()
        query = trimmed
        hasSearched = true
        SearchHistoryStore.shared.record(trimmed)
        searchField.resign()
        segmentedTabs.isHidden = false
        emptyState.isHidden = true
        errorState.isHidden = true
        isLoading = true
        spinner.startAnimating()
        tableView.reloadData()

        api.musicSearch(query: trimmed, filter: filter) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.query == trimmed else { return }
                self.isLoading = false
                self.spinner.stopAnimating()
                switch result {
                case .success(let results):
                    self.sections = MusicSearchViewController.group(results.items, filter: self.filter)
                    self.updateEmptyState()
                    self.tableView.reloadData()
                case .failure(let error):
                    self.sections = []
                    self.tableView.reloadData()
                    self.errorState.isHidden = false
                    self.errorState.configure(
                        kind: .custom(icon: .wifi, title: "Search failed", message: error.displayMessage),
                        actionTitle: "Retry"
                    )
                }
            }
        }
    }

    private func showSuggestions() {
        hasSearched = false
        query = ""
        sections = []
        suggestions = []
        segmentedTabs.isHidden = true
        segmentedTabs.select(index: 0, notify: false)
        filter = .all
        spinner.stopAnimating()
        isLoading = false
        emptyState.isHidden = true
        errorState.isHidden = true
        reloadHistory()
        tableView.reloadData()
    }

    private func reloadHistory() {
        history = SearchHistoryStore.shared.recent(limit: 12)
    }

    private func updateEmptyState() {
        let empty = sections.allSatisfy { $0.items.isEmpty }
        emptyState.isHidden = !empty
        if empty {
            emptyState.configure(kind: .custom(
                icon: .search,
                title: "No results for \"" + query + "\"",
                message: "Try a different spelling or another kind of result."
            ))
        }
    }

    /// Splits a page of results into the blocks the table shows. A specific filter keeps YouTube's
    /// order untouched; "All" groups the mixed answer by kind, which is how the Android screen
    /// presents its summaries.
    private static func group(_ items: [MusicItem], filter: MusicSearchFilter) -> [ResultSection] {
        if filter != .all {
            return [ResultSection(title: title(for: filter), items: items)]
        }
        var songs: [MusicItem] = []
        var videos: [MusicItem] = []
        var albums: [MusicItem] = []
        var artists: [MusicItem] = []
        var playlists: [MusicItem] = []
        for item in items {
            switch item {
            case .song(let song):
                if song.isVideoSong {
                    videos.append(item)
                } else {
                    songs.append(item)
                }
            case .album:
                albums.append(item)
            case .artist:
                artists.append(item)
            case .playlist:
                playlists.append(item)
            }
        }
        var sections: [ResultSection] = []
        if !songs.isEmpty { sections.append(ResultSection(title: "Songs", items: songs)) }
        if !videos.isEmpty { sections.append(ResultSection(title: "Videos", items: videos)) }
        if !albums.isEmpty { sections.append(ResultSection(title: "Albums", items: albums)) }
        if !artists.isEmpty { sections.append(ResultSection(title: "Artists", items: artists)) }
        if !playlists.isEmpty { sections.append(ResultSection(title: "Playlists", items: playlists)) }
        return sections
    }

    private static func title(for filter: MusicSearchFilter) -> String {
        switch filter {
        case .all: return "All"
        case .songs: return "Songs"
        case .videos: return "Videos"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .playlists: return "Playlists"
        case .podcasts: return "Podcasts"
        }
    }

    // MARK: - Actions

    @objc private func handleBack() {
        if hasSearched {
            searchField.setText("")
            showSuggestions()
            searchField.focus()
            return
        }
        if let navigation = navigationController, navigation.viewControllers.first !== self {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true, completion: nil)
        }
    }

    private func open(_ item: MusicItem) {
        searchField.resign()
        switch item {
        case .song(let song):
            MusicItemRouter.play(songs: [song], startIndex: 0, title: "Search: " + query, from: self)
        default:
            MusicItemRouter.open(item, from: self, api: api)
        }
    }

    private func showMenu(for item: MusicItem) {
        var actions: [FlowActionSheetContent.Action] = []
        if case .song(let song) = item {
            actions.append(FlowActionSheetContent.Action(title: "Play next", icon: .next) {
                FlowApp.shared.playback.playNext(MusicItemRouter.queueItem(for: song))
                FlowSnackbar.show("Playing next")
            })
            actions.append(FlowActionSheetContent.Action(title: "Add to queue", icon: .queue) {
                FlowApp.shared.playback.enqueue(MusicItemRouter.queueItem(for: song))
                FlowSnackbar.show("Added to queue")
            })
        }
        if let artistId = MusicSearchViewController.artistId(of: item) {
            actions.append(FlowActionSheetContent.Action(title: "View Artist", icon: .music) { [weak self] in
                guard let self = self else { return }
                MusicItemRouter.openArtist(id: artistId, from: self, api: self.api)
            })
        }
        if let albumId = MusicSearchViewController.albumId(of: item) {
            actions.append(FlowActionSheetContent.Action(title: "View Album", icon: .playlist) { [weak self] in
                guard let self = self else { return }
                MusicItemRouter.openAlbum(id: albumId, from: self, api: self.api)
            })
        }
        actions.append(FlowActionSheetContent.Action(title: "Share", icon: .share) { [weak self] in
            guard let self = self, let url = URL(string: item.shareURL) else { return }
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
        let sheet = FlowSheet(content: content, title: item.title, detent: .medium, showsGrabber: true)
        content.onActionSelected = { [weak sheet] in sheet?.dismissSheet() }
        sheet.present(from: self)
    }

    private static func artistId(of item: MusicItem) -> String? {
        switch item {
        case .song(let song):
            return song.artists.first?.id
        case .album(let album):
            return album.artists.first?.id
        case .artist(let artist):
            return artist.id
        case .playlist:
            return nil
        }
    }

    private static func albumId(of item: MusicItem) -> String? {
        switch item {
        case .song(let song):
            return song.albumId
        case .album(let album):
            return album.browseId
        default:
            return nil
        }
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        backButton.setIconColor(scheme.onSurface)
        searchField.applyTheme()
        segmentedTabs.applyTheme()
        spinner.color = scheme.onSurfaceVariant
        emptyState.applyTheme()
        errorState.applyTheme()
        tableView.reloadData()
    }

    // MARK: - Rows

    /// The rows shown while the field is empty: recent searches, then suggestions.
    private var suggestionRows: [(title: String, detail: String?)] {
        var rows: [(title: String, detail: String?)] = []
        for value in history {
            rows.append((title: value, detail: "Recent search"))
        }
        for value in suggestions where !history.contains(value) {
            rows.append((title: value, detail: nil))
        }
        return rows
    }
}

// MARK: - Data source

extension MusicSearchViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        if !hasSearched {
            return 1
        }
        return sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if !hasSearched {
            return suggestionRows.count
        }
        return sections.element(at: section)?.items.count ?? 0
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard hasSearched, sections.count > 1 else { return nil }
        return sections.element(at: section)?.title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if !hasSearched {
            let cell = tableView.dequeueReusableCell(withIdentifier: MusicCollectionRowCell.reuseIdentifier, for: indexPath)
            guard let rowCell = cell as? MusicCollectionRowCell else { return cell }
            let row = suggestionRows.element(at: indexPath.row)
            rowCell.configure(
                title: row?.title ?? "",
                subtitle: row?.detail,
                artworkUrl: nil,
                circularArtwork: false,
                showsMenu: false
            )
            rowCell.applyTheme()
            return rowCell
        }

        guard let item = sections.element(at: indexPath.section)?.items.element(at: indexPath.row) else {
            return UITableViewCell()
        }
        switch item {
        case .song(let song):
            let cell = tableView.dequeueReusableCell(withIdentifier: MusicTrackRowCell.reuseIdentifier, for: indexPath)
            guard let trackCell = cell as? MusicTrackRowCell else { return cell }
            trackCell.onMenu = { [weak self] in self?.showMenu(for: item) }
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

        case .album(let album):
            let cell = tableView.dequeueReusableCell(withIdentifier: MusicCollectionRowCell.reuseIdentifier, for: indexPath)
            guard let rowCell = cell as? MusicCollectionRowCell else { return cell }
            rowCell.onMenu = { [weak self] in self?.showMenu(for: item) }
            rowCell.configure(
                title: album.title,
                subtitle: MusicFormat.metadata([album.artistLine, MusicFormat.year(album.year)]),
                artworkUrl: album.thumbnailUrl,
                circularArtwork: false
            )
            rowCell.applyTheme()
            return rowCell

        case .playlist(let playlist):
            let cell = tableView.dequeueReusableCell(withIdentifier: MusicCollectionRowCell.reuseIdentifier, for: indexPath)
            guard let rowCell = cell as? MusicCollectionRowCell else { return cell }
            rowCell.onMenu = { [weak self] in self?.showMenu(for: item) }
            rowCell.configure(
                title: playlist.title,
                subtitle: MusicFormat.metadata([playlist.authorName, playlist.songCountText]),
                artworkUrl: playlist.thumbnailUrl,
                circularArtwork: false
            )
            rowCell.applyTheme()
            return rowCell

        case .artist(let artist):
            let cell = tableView.dequeueReusableCell(withIdentifier: MusicCollectionRowCell.reuseIdentifier, for: indexPath)
            guard let rowCell = cell as? MusicCollectionRowCell else { return cell }
            rowCell.onMenu = { [weak self] in self?.showMenu(for: item) }
            rowCell.configure(
                title: artist.title,
                subtitle: artist.isProfile ? "Channel" : "Artist",
                artworkUrl: artist.thumbnailUrl,
                circularArtwork: true
            )
            rowCell.applyTheme()
            return rowCell
        }
    }
}

// MARK: - Delegate

extension MusicSearchViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if !hasSearched {
            guard let row = suggestionRows.element(at: indexPath.row) else { return }
            searchField.setText(row.title)
            performSearch(row.title)
            return
        }
        guard let item = sections.element(at: indexPath.section)?.items.element(at: indexPath.row) else { return }
        open(item)
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard hasSearched, sections.count > 1, let title = sections.element(at: section)?.title else { return nil }
        let container = UIView()
        container.backgroundColor = .clear
        let label = UILabel()
        label.text = title
        label.font = FlowTypography.titleMedium
        label.textColor = FlowTheme.shared.scheme.onSurface
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: FlowSpacing.screenMargin),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -FlowSpacing.screenMargin),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -FlowSpacing.xs),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: FlowSpacing.md),
        ])
        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard hasSearched, sections.count > 1 else { return 0.0 }
        return 44.0
    }
}

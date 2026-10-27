import UIKit

/// The search screen: a search field in the navigation bar, the suggestions panel while typing, and
/// the results with a filter sheet and a grid/list toggle.
///
/// The field is a custom bar rather than `UISearchController`, because styling the controller's text
/// field on iOS 12 needs private key paths. This bar is a plain `UITextField` in a rounded container,
/// which is also what the Android screen looks like.
final class SearchViewController: UIViewController {

    // MARK: - Navigation

    /// Called with the video the viewer picked.
    var onOpenVideo: ((Video) -> Void)?
    /// Called with the channel id the viewer picked.
    var onOpenChannel: ((String) -> Void)?
    /// Called with the playlist id the viewer picked.
    var onOpenPlaylist: ((String) -> Void)?

    // MARK: - State

    private let searchBar = SearchBarView()
    private let suggestionsController = SearchSuggestionsViewController()
    private let resultsController = SearchResultsController()
    private let filterButton = SearchViewController.makeChromeButton(.filter)
    private let viewModeButton = SearchViewController.makeChromeButton(.library)
    private let backButton = SearchViewController.makeChromeButton(.back)
    private let debouncer = FlowDebouncer(interval: 0.28)
    private var isShowingResults = false
    private var isGrid = true
    private var filters = SearchFilters()
    private var themeToken: ObservationToken?

    /// The query the screen was opened with, when it was opened from a link.
    var initialQuery: String?

    deinit {
        themeToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildBar()
        embedChildren()
        bind()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
        if let query = initialQuery, !query.isBlank {
            searchBar.setText(query)
            runSearch(query: query)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isShowingResults {
            searchBar.focus()
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
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.onChange = { [weak self] text in
            self?.handleTextChange(text)
        }
        searchBar.onSubmit = { [weak self] text in
            self?.runSearch(query: text)
        }
        searchBar.onClear = { [weak self] in
            self?.showSuggestions()
        }
        view.addSubview(searchBar)

        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.accessibilityLabel = "Back"
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        view.addSubview(backButton)

        filterButton.translatesAutoresizingMaskIntoConstraints = false
        filterButton.accessibilityLabel = "Filters"
        filterButton.addTarget(self, action: #selector(handleFilters), for: .touchUpInside)
        filterButton.isHidden = true
        view.addSubview(filterButton)

        viewModeButton.translatesAutoresizingMaskIntoConstraints = false
        viewModeButton.accessibilityLabel = "Toggle search result view"
        viewModeButton.addTarget(self, action: #selector(handleViewMode), for: .touchUpInside)
        viewModeButton.isHidden = true
        view.addSubview(viewModeButton)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.xs),
            backButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

            searchBar.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: FlowSpacing.xs),
            searchBar.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor, constant: -FlowSpacing.xs),
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: FlowSpacing.md),
            searchBar.heightAnchor.constraint(equalToConstant: 44.0),

            filterButton.trailingAnchor.constraint(equalTo: viewModeButton.leadingAnchor),
            filterButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            filterButton.widthAnchor.constraint(equalToConstant: 40.0),

            viewModeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.xs),
            viewModeButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            viewModeButton.widthAnchor.constraint(equalToConstant: 40.0),
        ])
    }

    private func embedChildren() {
        addChild(suggestionsController)
        suggestionsController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(suggestionsController.view)
        suggestionsController.didMove(toParent: self)

        addChild(resultsController)
        resultsController.view.translatesAutoresizingMaskIntoConstraints = false
        resultsController.view.isHidden = true
        view.addSubview(resultsController.view)
        resultsController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            suggestionsController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestionsController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            suggestionsController.view.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: FlowSpacing.md),
            suggestionsController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            resultsController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            resultsController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            resultsController.view.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: FlowSpacing.md),
            resultsController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func bind() {
        suggestionsController.onSelect = { [weak self] query in
            self?.searchBar.setText(query)
            self?.runSearch(query: query)
        }
        suggestionsController.onClearHistory = {
            SearchHistoryStore.shared.clear()
        }
        suggestionsController.onRemoveHistory = { query in
            SearchHistoryStore.shared.remove(query)
        }

        resultsController.onOpenVideo = { [weak self] video in self?.onOpenVideo?(video) }
        resultsController.onOpenChannel = { [weak self] channelId in self?.onOpenChannel?(channelId) }
        resultsController.onOpenPlaylist = { [weak self] playlistId in self?.onOpenPlaylist?(playlistId) }
        resultsController.onPagingFailure = { message in
            FlowSnackbar.showError(message)
        }
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

    private func loadSuggestions(for query: String) {
        YouTubeAPI().suggestions(query: query) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.searchBar.text.trimmed == query else { return }
                if case .success(let values) = result {
                    self.suggestionsController.setSuggestions(values)
                }
            }
        }
    }

    private func runSearch(query: String) {
        let trimmed = query.trimmed
        guard !trimmed.isEmpty else { return }
        debouncer.cancel()
        SearchHistoryStore.shared.record(trimmed)
        searchBar.resign()
        showResults()
        resultsController.search(query: trimmed, filters: filters)
    }

    private func showSuggestions() {
        isShowingResults = false
        suggestionsController.view.isHidden = false
        resultsController.view.isHidden = true
        filterButton.isHidden = true
        viewModeButton.isHidden = true
        suggestionsController.reloadHistory()
        suggestionsController.setSuggestions([])
    }

    private func showResults() {
        isShowingResults = true
        suggestionsController.view.isHidden = true
        resultsController.view.isHidden = false
        filterButton.isHidden = false
        viewModeButton.isHidden = false
    }

    // MARK: - Actions

    @objc private func handleBack() {
        if isShowingResults {
            searchBar.setText("")
            showSuggestions()
            searchBar.focus()
            return
        }
        if let navigation = navigationController, navigation.viewControllers.first !== self {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true, completion: nil)
        }
    }

    @objc private func handleViewMode() {
        isGrid = !isGrid
        resultsController.setGrid(isGrid)
        viewModeButton.setIcon(isGrid ? .library : .playlist)
        viewModeButton.accessibilityLabel = isGrid ? "Show as list" : "Show as grid"
    }

    @objc private func handleFilters() {
        let content = SearchFilterSheetContent(filters: filters)
        let sheet = FlowSheet(content: content, title: "Filters", detent: .large, showsGrabber: true)
        content.onApply = { [weak self, weak sheet] newFilters in
            guard let self = self else { return }
            self.filters = newFilters
            self.resultsController.updateFilters(newFilters)
            sheet?.dismissSheet()
        }
        content.onReset = { [weak self] in
            guard let self = self else { return }
            self.filters = SearchFilters()
            content.apply(SearchFilters())
            self.resultsController.updateFilters(self.filters)
        }
        sheet.present(from: self)
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        searchBar.applyTheme()
        backButton.setIconColor(scheme.onSurface)
        filterButton.setIconColor(scheme.onSurface)
        viewModeButton.setIconColor(scheme.onSurface)
    }
}

// MARK: - Search bar

/// The rounded search field at the top of the screen: a magnifier, a text field and a clear button.
final class SearchBarView: UIView, UITextFieldDelegate {

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
        container.layer.cornerRadius = FlowShapes.pill(for: 44.0)
        container.layer.masksToBounds = true
        addSubview(container)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.icon = .search
        iconView.iconSize = 20.0
        container.addSubview(iconView)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = FlowTypography.bodyLarge
        textField.placeholder = "Search videos, channels..."
        textField.returnKeyType = .search
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.clearButtonMode = .never
        textField.delegate = self
        textField.addTarget(self, action: #selector(handleEditingChanged), for: .editingChanged)
        container.addSubview(textField)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.setImage(FlowIcon.close.image(size: 16.0, color: FlowTheme.shared.onSurfaceVariant), for: .normal)
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
        textField.attributedPlaceholder = NSAttributedString(string: "Search videos, channels...", attributes: attributes)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onSubmit?(textField.text ?? "")
        return true
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

// MARK: - Filter sheet

/// The filter sheet's content: a chip group per filter, with Apply and Reset.
final class SearchFilterSheetContent: UIView {

    /// Called with the filters the viewer chose.
    var onApply: ((SearchFilters) -> Void)?
    /// Called when the viewer resets every group.
    var onReset: (() -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let applyButton = FlowButton.make("Apply", style: .filled)
    private let resetButton = FlowButton.make("Reset", style: .text)

    private var typeRow = FlowChipRow()
    private var dateRow = FlowChipRow()
    private var durationRow = FlowChipRow()
    private var sortRow = FlowChipRow()
    private var current: SearchFilters

    init(filters: SearchFilters) {
        current = filters
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        apply(filters)
    }

    required init?(coder: NSCoder) {
        current = SearchFilters()
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    private func build() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = FlowSpacing.xl
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        typeRow = makeRow(title: "Type", titles: SearchFilterSheetContent.typeTitles)
        dateRow = makeRow(title: "Upload date", titles: SearchFilters.UploadDate.allCases.map { $0.title })
        durationRow = makeRow(title: "Duration", titles: SearchFilters.Duration.allCases.map { $0.title })
        sortRow = makeRow(title: "Sort by", titles: SearchFilters.Sort.allCases.map { $0.title })

        typeRow.onSelect = { [weak self] index in
            guard let self = self else { return }
            let values = SearchFilterSheetContent.types
            self.current.type = values.element(at: index) ?? .all
        }
        dateRow.onSelect = { [weak self] index in
            guard let self = self else { return }
            self.current.uploadDate = SearchFilters.UploadDate(rawValue: index) ?? .any
        }
        durationRow.onSelect = { [weak self] index in
            guard let self = self else { return }
            self.current.duration = SearchFilters.Duration(rawValue: index) ?? .any
        }
        sortRow.onSelect = { [weak self] index in
            guard let self = self else { return }
            self.current.sort = SearchFilters.Sort(rawValue: index) ?? .relevance
        }

        let actions = UIStackView(arrangedSubviews: [resetButton, applyButton])
        actions.axis = .horizontal
        actions.spacing = FlowSpacing.lg
        actions.distribution = .fillEqually
        actions.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(actions)

        resetButton.onTap = { [weak self] in self?.onReset?() }
        applyButton.onTap = { [weak self] in
            guard let self = self else { return }
            self.onApply?(self.current)
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: FlowSpacing.xl),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -FlowSpacing.xl),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: FlowSpacing.md),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -FlowSpacing.xxl),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -FlowSpacing.xl * 2.0),
        ])
    }

    private func makeRow(title: String, titles: [String]) -> FlowChipRow {
        let label = UILabel()
        label.text = title
        label.font = FlowTypography.titleSmall
        label.textColor = FlowTheme.shared.scheme.onSurface
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = FlowChipRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setTitles(titles, selectedIndex: 0)
        row.heightAnchor.constraint(equalToConstant: 44.0).isActive = true

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(row)
        return row
    }

    /// Sets every group's selection from `filters`.
    func apply(_ filters: SearchFilters) {
        current = filters
        let typeIndex = SearchFilterSheetContent.types.firstIndex(of: filters.type) ?? 0
        typeRow.setTitles(SearchFilterSheetContent.typeTitles, selectedIndex: typeIndex)
        dateRow.setTitles(SearchFilters.UploadDate.allCases.map { $0.title }, selectedIndex: filters.uploadDate.rawValue)
        durationRow.setTitles(SearchFilters.Duration.allCases.map { $0.title }, selectedIndex: filters.duration.rawValue)
        sortRow.setTitles(SearchFilters.Sort.allCases.map { $0.title }, selectedIndex: filters.sort.rawValue)
        bindRows()
    }

    private func bindRows() {
        typeRow.onSelect = { [weak self] index in
            guard let self = self else { return }
            self.current.type = SearchFilterSheetContent.types.element(at: index) ?? .all
        }
        dateRow.onSelect = { [weak self] index in
            guard let self = self else { return }
            self.current.uploadDate = SearchFilters.UploadDate(rawValue: index) ?? .any
        }
        durationRow.onSelect = { [weak self] index in
            guard let self = self else { return }
            self.current.duration = SearchFilters.Duration(rawValue: index) ?? .any
        }
        sortRow.onSelect = { [weak self] index in
            guard let self = self else { return }
            self.current.sort = SearchFilters.Sort(rawValue: index) ?? .relevance
        }
    }

    /// The types the sheet offers, in the order the Android dialog lists them.
    static let types: [VideoSearchFilter] = [.all, .videos, .channels, .playlists, .live, .movies]

    /// The type group's titles.
    static let typeTitles: [String] = types.map { $0.title }
}

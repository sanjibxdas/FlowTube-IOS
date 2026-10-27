import UIKit

/// The panel under the search field: recent searches as removable chips, then the typeahead
/// suggestions InnerTube returns for what has been typed so far.
///
/// The panel owns no network state of its own — the search screen debounces the field and hands the
/// results down — so it stays a pure renderer of two lists.
final class SearchSuggestionsViewController: UIViewController {

    /// Called with the text the viewer picked.
    var onSelect: ((String) -> Void)?
    /// Called when the viewer removes one recent search.
    var onRemoveHistory: ((String) -> Void)?
    /// Called when the viewer clears the whole history.
    var onClearHistory: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let historyHeader = FlowSectionHeader.make(title: "Search & History", actionTitle: "Clear")
    private let historyRow = FlowChipRow()
    private let emptyLabel = UILabel()
    private var history: [String] = []
    private var suggestions: [String] = []
    private var themeToken: ObservationToken?

    deinit {
        themeToken?.cancelObservation()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildHeader()
        buildTable()
        buildEmptyLabel()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        reloadHistory()
        applyTheme()
    }

    // MARK: - Build

    private func buildHeader() {
        historyHeader.translatesAutoresizingMaskIntoConstraints = false
        historyHeader.onAction = { [weak self] in
            self?.onClearHistory?()
            self?.reloadHistory()
        }
        view.addSubview(historyHeader)

        historyRow.translatesAutoresizingMaskIntoConstraints = false
        historyRow.onSelect = { [weak self] index in
            guard let self = self, let query = self.history.element(at: index) else { return }
            self.onSelect?(query)
        }
        view.addSubview(historyRow)

        NSLayoutConstraint.activate([
            historyHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.screenMargin),
            historyHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.screenMargin),
            historyHeader.topAnchor.constraint(equalTo: view.topAnchor),

            historyRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.screenMargin),
            historyRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.screenMargin),
            historyRow.topAnchor.constraint(equalTo: historyHeader.bottomAnchor),
            historyRow.heightAnchor.constraint(equalToConstant: 44.0),
        ])
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = FlowSpacing.suggestionItemHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SuggestionCell")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: historyRow.bottomAnchor, constant: FlowSpacing.sm),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildEmptyLabel() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = FlowTypography.bodyMedium
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 3
        emptyLabel.text = "Search for videos, music and more"
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: FlowSpacing.xxxl),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -FlowSpacing.xxxl),
        ])
    }

    // MARK: - Content

    /// Re-reads the recent searches from storage.
    func reloadHistory() {
        history = SearchHistoryStore.shared.recent(limit: 10)
        historyHeader.isHidden = history.isEmpty
        historyRow.isHidden = history.isEmpty
        historyRow.setTitles(history, selectedIndex: -1)
        updateEmptyState()
    }

    /// Replaces the typeahead suggestions.
    func setSuggestions(_ values: [String]) {
        suggestions = values
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        let hasHistory = !history.isEmpty
        emptyLabel.isHidden = hasHistory || !suggestions.isEmpty
        tableView.isHidden = suggestions.isEmpty
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        emptyLabel.textColor = scheme.onSurfaceVariant
        historyHeader.applyTheme()
        historyRow.applyTheme()
        tableView.reloadData()
    }
}

extension SearchSuggestionsViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return suggestions.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SuggestionCell", for: indexPath)
        let scheme = FlowTheme.shared.scheme
        cell.backgroundColor = .clear
        cell.selectionStyle = .default
        cell.textLabel?.text = suggestions.element(at: indexPath.row)
        cell.textLabel?.font = FlowTypography.bodyLarge
        cell.textLabel?.textColor = scheme.onSurface
        cell.imageView?.image = FlowIcon.search.image(size: 18.0, color: scheme.onSurfaceVariant)
        cell.accessoryType = .none
        return cell
    }
}

extension SearchSuggestionsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let query = suggestions.element(at: indexPath.row) else { return }
        onSelect?(query)
    }
}

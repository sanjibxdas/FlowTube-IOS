import UIKit

/// The Home feed: the category chips, the vertical feed of shelves and videos, pull-to-refresh and
/// infinite scrolling.
///
/// Navigation is expressed as closures rather than through a router, so the screen can be embedded
/// anywhere — a tab, a preview, a test — without knowing the app's navigation graph.
final class HomeViewController: UIViewController {

    // MARK: - Navigation

    /// Called with the video the viewer picked.
    var onOpenVideo: ((Video) -> Void)?
    /// Called with the video id and title of a history entry the viewer picked.
    var onResumeVideo: ((HistoryEntry) -> Void)?
    /// Called with the channel id the viewer picked.
    var onOpenChannel: ((String) -> Void)?
    /// Called when the viewer asks to see all Shorts.
    var onOpenShorts: (() -> Void)?
    /// Called with a shelf's browse id when the viewer asks for more of it.
    var onOpenShelf: ((String) -> Void)?

    // MARK: - State

    private let viewModel: HomeViewModel
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let chipsRow = FlowChipRow()
    private let refreshControl = UIRefreshControl()
    private let shimmerView = FlowShimmerGrid()
    private let emptyState = FlowEmptyState.make(kind: .custom(
        icon: .home,
        title: "Nothing here right now",
        message: "Pull down to look again later."
    ))
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")

    private var rows: [HomeRow] = []
    private var themeToken: ObservationToken?
    private var didApplyInitialFilter = false

    // MARK: - Construction

    init(viewModel: HomeViewModel = HomeViewModel()) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Home"
    }

    required init?(coder: NSCoder) {
        viewModel = HomeViewModel()
        super.init(coder: coder)
        title = "Home"
    }

    deinit {
        themeToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildChips()
        buildTable()
        buildOverlays()
        bind()
        viewModel.loadIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyTheme()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Continue-watching is read from the history table, which may have changed while the
        // viewer was on another screen.
        viewModel.reloadHistoryRow()
    }

    // MARK: - Build

    private func buildChips() {
        chipsRow.translatesAutoresizingMaskIntoConstraints = false
        chipsRow.setTitles(HomeViewModel.Filter.allCases.map { $0.title }, selectedIndex: 0)
        chipsRow.onSelect = { [weak self] index in
            guard let self = self else { return }
            let filter = HomeViewModel.Filter(rawValue: index) ?? .all
            self.viewModel.selectFilter(filter)
        }
        view.addSubview(chipsRow)
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 260.0
        tableView.showsVerticalScrollIndicator = true
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: FlowSpacing.xxl, right: 0)

        tableView.register(HomeVideoCell.self, forCellReuseIdentifier: HomeVideoCell.reuseIdentifier)
        tableView.register(HomeShelfCell.self, forCellReuseIdentifier: HomeShelfCell.reuseIdentifier)
        tableView.register(HomeShortsCell.self, forCellReuseIdentifier: HomeShortsCell.reuseIdentifier)
        tableView.register(HomeStatusCell.self, forCellReuseIdentifier: HomeStatusCell.reuseIdentifier)

        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        tableView.refreshControl = refreshControl
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            chipsRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chipsRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chipsRow.topAnchor.constraint(equalTo: view.topAnchor),
            chipsRow.heightAnchor.constraint(equalToConstant: 52.0),

            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: chipsRow.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildOverlays() {
        shimmerView.translatesAutoresizingMaskIntoConstraints = false
        shimmerView.isHidden = true
        view.addSubview(shimmerView)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        emptyState.onAction = { [weak self] in self?.viewModel.refresh() }
        view.addSubview(emptyState)

        errorState.translatesAutoresizingMaskIntoConstraints = false
        errorState.isHidden = true
        errorState.onAction = { [weak self] in self?.viewModel.refresh() }
        view.addSubview(errorState)

        NSLayoutConstraint.activate([
            shimmerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shimmerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shimmerView.topAnchor.constraint(equalTo: chipsRow.bottomAnchor),
            shimmerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: chipsRow.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            errorState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorState.topAnchor.constraint(equalTo: chipsRow.bottomAnchor),
            errorState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func bind() {
        viewModel.onChange = { [weak self] in
            self?.render()
        }
        viewModel.onRefreshFailure = { message in
            FlowSnackbar.showError(message)
        }
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
    }

    // MARK: - Rendering

    private func render() {
        let newRows = viewModel.rows
        let oldRows = rows
        rows = newRows
        applyStateVisibility()

        if oldRows.isEmpty || newRows.isEmpty {
            tableView.reloadData()
            return
        }
        let diff = FlowListDiff<String>.between(old: oldRows.map { $0.id }, new: newRows.map { $0.id })
        if diff.isEmpty && !diff.reloads.isEmpty {
            tableView.reloadData()
            return
        }
        tableView.beginUpdates()
        if !diff.deletions.isEmpty {
            tableView.deleteRows(at: diff.deletionIndexPaths(), with: .fade)
        }
        if !diff.insertions.isEmpty {
            tableView.insertRows(at: diff.insertionIndexPaths(), with: .fade)
        }
        if !diff.reloads.isEmpty {
            tableView.reloadRows(at: diff.reloadIndexPaths(), with: .none)
        }
        tableView.endUpdates()
    }

    private func applyStateVisibility() {
        let hasRows = !rows.isEmpty
        tableView.isHidden = !hasRows && viewModel.state != .loaded
        switch viewModel.state {
        case .loading:
            shimmerView.isHidden = false
            shimmerView.startAnimating()
            emptyState.isHidden = true
            errorState.isHidden = true
        case .loaded:
            shimmerView.stopAnimating()
            shimmerView.isHidden = true
            emptyState.isHidden = true
            errorState.isHidden = true
        case .empty:
            shimmerView.stopAnimating()
            shimmerView.isHidden = true
            emptyState.isHidden = false
            errorState.isHidden = true
        case .error(let message):
            shimmerView.stopAnimating()
            shimmerView.isHidden = true
            emptyState.isHidden = true
            errorState.isHidden = false
            errorState.configure(kind: .custom(icon: .wifi, title: "Couldn't refresh your feed", message: message),
                                 actionTitle: "Retry")
        }
        if refreshControl.isRefreshing && !viewModel.isRefreshing {
            refreshControl.endRefreshing()
        }
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        tableView.backgroundColor = .clear
        refreshControl.tintColor = scheme.onSurfaceVariant
        chipsRow.applyTheme()
        shimmerView.applyTheme()
        emptyState.applyTheme()
        errorState.applyTheme()
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func handleRefresh() {
        viewModel.refresh { [weak self] in
            self?.refreshControl.endRefreshing()
        }
    }

    private func open(video: Video) {
        onOpenVideo?(video)
    }

    private func open(entry: HistoryEntry) {
        onResumeVideo?(entry)
    }

    private func openShorts(_ videos: [Video]) {
        onOpenShorts?()
    }

    private func openShelf(_ browseId: String?) {
        guard let browseId = browseId, !browseId.isEmpty else { return }
        onOpenShelf?(browseId)
    }
}

// MARK: - Table data source

extension HomeViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let row = rows.element(at: indexPath.row) else {
            return UITableViewCell()
        }
        switch row {
        case .video(let video):
            let cell = tableView.dequeueReusableCell(withIdentifier: HomeVideoCell.reuseIdentifier, for: indexPath)
            if let videoCell = cell as? HomeVideoCell {
                videoCell.configure(with: video)
            }
            return cell
        case .shelf(let shelf):
            let cell = tableView.dequeueReusableCell(withIdentifier: HomeShelfCell.reuseIdentifier, for: indexPath)
            if let shelfCell = cell as? HomeShelfCell {
                shelfCell.onSelect = { [weak self] video in self?.open(video: video) }
                shelfCell.onSelectEntry = { [weak self] entry in self?.open(entry: entry) }
                shelfCell.onMore = { [weak self] in self?.openShelf(shelf.moreBrowseId) }
                shelfCell.configure(
                    title: shelf.title,
                    subtitle: shelf.subtitle,
                    videos: shelf.items,
                    showsAvatar: false,
                    actionTitle: shelf.moreBrowseId == nil ? nil : "Show more"
                )
            }
            return cell
        case .continueWatching(let entries):
            let cell = tableView.dequeueReusableCell(withIdentifier: HomeShelfCell.reuseIdentifier, for: indexPath)
            if let shelfCell = cell as? HomeShelfCell {
                shelfCell.onSelectEntry = { [weak self] entry in self?.open(entry: entry) }
                shelfCell.onSelect = nil
                shelfCell.onMore = nil
                shelfCell.configure(title: "Continue Watching", entries: entries, actionTitle: nil)
            }
            return cell
        case .shortsShelf(let videos):
            let cell = tableView.dequeueReusableCell(withIdentifier: HomeShortsCell.reuseIdentifier, for: indexPath)
            if let shortsCell = cell as? HomeShortsCell {
                shortsCell.onSelect = { [weak self] video in self?.open(video: video) }
                shortsCell.onMore = { [weak self] in self?.openShorts(videos) }
                shortsCell.configure(videos: videos, actionTitle: "Show more")
            }
            return cell
        case .status(let status):
            let cell = tableView.dequeueReusableCell(withIdentifier: HomeStatusCell.reuseIdentifier, for: indexPath)
            if let statusCell = cell as? HomeStatusCell {
                statusCell.onRetry = { [weak self] in self?.viewModel.retryLoadMore() }
                statusCell.configure(status: status)
            }
            return cell
        }
    }
}

// MARK: - Table delegate

extension HomeViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let row = rows.element(at: indexPath.row) else { return UITableView.automaticDimension }
        return row.height
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = rows.element(at: indexPath.row) else { return }
        switch row {
        case .video(let video):
            open(video: video)
        case .shelf(let shelf):
            if let first = shelf.items.first {
                open(video: first)
            }
        case .continueWatching(let entries):
            if let first = entries.first {
                open(entry: first)
            }
        case .shortsShelf(let videos):
            openShorts(videos)
        case .status:
            break
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        let offset = scrollView.contentOffset.y
        let height = scrollView.contentSize.height
        let visible = scrollView.bounds.height
        guard height > visible else { return }
        if offset > height - visible * 2.0 {
            viewModel.loadMore()
        }
    }
}

// MARK: - Prefetching

extension HomeViewController: UITableViewDataSourcePrefetching {

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        var urls: [String] = []
        for indexPath in indexPaths {
            guard let row = rows.element(at: indexPath.row) else { continue }
            switch row {
            case .video(let video):
                urls.append(video.thumbnailUrl)
            case .shelf(let shelf):
                urls.append(contentsOf: shelf.items.map { $0.thumbnailUrl })
            case .shortsShelf(let videos):
                urls.append(contentsOf: videos.map { $0.thumbnailUrl })
            case .continueWatching(let entries):
                urls.append(contentsOf: entries.map { $0.thumbnailUrl })
            case .status:
                break
            }
        }
        ImageLoader.shared.prefetch(urls)
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        // The loader owns its own cache; cancelling a prefetch would only throw away work that is
        // already in flight and likely to be needed on the next scroll.
    }
}

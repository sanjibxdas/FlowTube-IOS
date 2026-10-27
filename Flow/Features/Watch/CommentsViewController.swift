import UIKit

/// A video's comments: the sort chips, the threads with their replies, and the paging.
///
/// The screen owns its own paging because comments arrive as a continuation chain rather than as a
/// page of results: the first request spends the token the watch page carried, and every page after
/// that spends the token the previous page returned. Replies are a second chain hanging off one
/// comment, loaded on demand so a thread with a thousand replies costs nothing until it is opened.
final class CommentsViewController: UIViewController {

    // MARK: - Navigation

    /// Called with the channel id the viewer tapped.
    var onOpenChannel: ((String) -> Void)?
    /// Called when the viewer taps a timestamp inside a comment.
    var onSeek: ((TimeInterval) -> Void)?
    /// Called when the viewer closes the screen.
    var onClose: (() -> Void)?

    // MARK: - Sorting

    /// The orders the chips offer.
    ///
    /// YouTube serves two orders and no third: Top and Newest are separate continuations, and Oldest
    /// is the chronological one read backwards. The facade this app talks to exposes a single
    /// comment continuation, so Top is the order the server returned and Newest and Oldest are
    /// applied locally over the pages loaded so far — the same result for the first page, and a
    /// stable one for the rest.
    enum Sort: Int, CaseIterable {
        case top
        case newest
        case oldest

        var title: String {
            switch self {
            case .top: return "Top"
            case .newest: return "Newest"
            case .oldest: return "Oldest"
            }
        }
    }

    // MARK: - Rows

    private enum Row {
        case comment(Comment, depth: Int)
        case moreReplies(String)
        case loadMorePage

        var id: String {
            switch self {
            case .comment(let comment, let depth): return "c:\(depth):\(comment.id)"
            case .moreReplies(let id): return "r:\(id)"
            case .loadMorePage: return "page"
            }
        }
    }

    private struct Replies {
        var items: [Comment] = []
        var continuation: String?
        var isLoading = false
        var isExpanded = false
    }

    // MARK: - State

    private let videoId: String
    private let initialContinuation: String?
    private let api: YouTubeAPI

    private let headerView = UIView()
    private let backButton = FlowIconButton.make(.back, color: .clear, size: 22.0, target: nil, action: nil)
    private let titleLabel = UILabel()
    private let totalLabel = UILabel()
    private let chipsRow = FlowChipRow()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let emptyState = FlowEmptyState.make(kind: .noComments)
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")

    private var comments: [Comment] = []
    private var rows: [Row] = []
    private var continuation: String?
    private var isLoading = false
    private var isLoadingMore = false
    private var sort: Sort = .top
    private var timedOnly = false
    private var expanded: Set<String> = []
    private var replies: [String: Replies] = [:]
    private var totalText: String?
    private var loadToken = 0
    private var themeToken: ObservationToken?

    // MARK: - Construction

    init(videoId: String, continuation: String? = nil, api: YouTubeAPI = YouTubeAPI()) {
        self.videoId = videoId
        self.initialContinuation = continuation
        self.api = api
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        videoId = ""
        initialContinuation = nil
        api = YouTubeAPI()
        super.init(coder: coder)
    }

    deinit {
        themeToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildHeader()
        buildChips()
        buildTable()
        buildOverlays()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Build

    private func buildHeader() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerView)

        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.accessibilityLabel = "Back"
        backButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        headerView.addSubview(backButton)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleMedium
        titleLabel.text = "Comments"
        headerView.addSubview(titleLabel)

        totalLabel.translatesAutoresizingMaskIntoConstraints = false
        totalLabel.font = FlowTypography.labelMedium
        totalLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerView.addSubview(totalLabel)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: FlowSpacing.toolbarHeight),

            backButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: FlowSpacing.xs),
            backButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44.0),
            backButton.heightAnchor.constraint(equalToConstant: 44.0),

            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: FlowSpacing.xs),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            totalLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: FlowSpacing.md),
            totalLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            totalLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
        ])
    }

    private func buildChips() {
        chipsRow.translatesAutoresizingMaskIntoConstraints = false
        chipsRow.setTitles(Sort.allCases.map { $0.title } + ["Timed"], selectedIndex: 0)
        chipsRow.onSelect = { [weak self] index in
            guard let self = self else { return }
            if index < Sort.allCases.count {
                self.sort = Sort(rawValue: index) ?? .top
            } else {
                self.timedOnly.toggle()
            }
            self.refreshChipSelection()
            self.rebuildRows()
            self.tableView.reloadData()
        }
        view.addSubview(chipsRow)

        NSLayoutConstraint.activate([
            chipsRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.screenMargin),
            chipsRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.screenMargin),
            chipsRow.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            chipsRow.heightAnchor.constraint(equalToConstant: 44.0),
        ])
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 120.0
        tableView.rowHeight = UITableView.automaticDimension
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.register(CommentCell.self, forCellReuseIdentifier: CommentCell.reuseIdentifier)
        tableView.register(CommentMoreCell.self, forCellReuseIdentifier: CommentMoreCell.reuseIdentifier)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: chipsRow.bottomAnchor, constant: FlowSpacing.xs),
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
        errorState.onAction = { [weak self] in self?.load() }
        view.addSubview(errorState)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

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

    // MARK: - Loading

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        loadToken += 1
        let token = loadToken
        errorState.isHidden = true
        emptyState.isHidden = true
        if comments.isEmpty {
            spinner.startAnimating()
        }
        api.comments(videoId: videoId, continuation: initialContinuation) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard token == self.loadToken else { return }
                self.isLoading = false
                self.spinner.stopAnimating()
                switch result {
                case .success(let page):
                    self.comments = page.comments
                    self.continuation = page.continuation
                    self.totalText = page.totalText
                    self.totalLabel.text = page.totalText
                    self.rebuildRows()
                    self.tableView.reloadData()
                    self.updateEmptyState()
                case .failure(let error):
                    self.showError(error)
                }
            }
        }
    }

    private func loadMore() {
        guard let token = continuation, !token.isEmpty, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        api.comments(videoId: videoId, continuation: token) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoadingMore = false
                guard case .success(let page) = result else { return }
                var known = Set(self.comments.map { $0.id })
                for comment in page.comments where !known.contains(comment.id) {
                    self.comments.append(comment)
                    known.insert(comment.id)
                }
                self.continuation = page.continuation
                if let total = page.totalText, self.totalText == nil {
                    self.totalText = total
                    self.totalLabel.text = total
                }
                self.rebuildRows()
                self.tableView.reloadData()
            }
        }
    }

    private func loadReplies(for comment: Comment) {
        guard var state = replies[comment.id], !state.isLoading else { return }
        guard let token = state.continuation ?? comment.continuation else {
            state.isExpanded = true
            replies[comment.id] = state
            rebuildRows()
            tableView.reloadData()
            return
        }
        state.isLoading = true
        replies[comment.id] = state
        rebuildRows()
        tableView.reloadData()

        api.commentReplies(continuation: token) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                var current = self.replies[comment.id] ?? Replies()
                current.isLoading = false
                switch result {
                case .success(let page):
                    var known = Set(current.items.map { $0.id })
                    for reply in page.comments where !known.contains(reply.id) {
                        current.items.append(reply)
                        known.insert(reply.id)
                    }
                    current.continuation = page.continuation
                    current.isExpanded = true
                case .failure(let error):
                    FlowSnackbar.showError(error.displayMessage)
                }
                self.replies[comment.id] = current
                self.rebuildRows()
                self.tableView.reloadData()
            }
        }
    }

    private func showError(_ error: FlowError) {
        if comments.isEmpty {
            errorState.isHidden = false
            errorState.configure(
                kind: .custom(icon: .wifi, title: "Couldn't load comments", message: error.displayMessage),
                actionTitle: "Retry"
            )
        } else {
            FlowSnackbar.showError(error.displayMessage)
        }
    }

    // MARK: - Rows

    private func refreshChipSelection() {
        let chips = chipsRow.chips
        for (index, chip) in chips.enumerated() {
            if index < Sort.allCases.count {
                chip.setSelected(index == sort.rawValue)
            } else {
                chip.setSelected(timedOnly)
            }
        }
    }

    /// The comments the chips select, out of the pages loaded so far.
    private func visibleComments() -> [Comment] {
        var filtered = comments
        if timedOnly {
            filtered = filtered.filter { !CommentTimestamps.links(in: $0.text).isEmpty }
        }
        let pinned = filtered.filter { $0.isPinned }
        let unpinned = filtered.filter { !$0.isPinned }
        let sorted: [Comment]
        switch sort {
        case .top:
            sorted = unpinned
        case .newest:
            sorted = unpinned.sorted { CommentTimestamps.age($0.publishedTime) < CommentTimestamps.age($1.publishedTime) }
        case .oldest:
            sorted = unpinned.sorted { CommentTimestamps.age($0.publishedTime) > CommentTimestamps.age($1.publishedTime) }
        }
        return pinned + sorted
    }

    private func rebuildRows() {
        var result: [Row] = []
        for comment in visibleComments() {
            result.append(.comment(comment, depth: 0))
            guard let state = replies[comment.id], state.isExpanded else { continue }
            for reply in state.items {
                result.append(.comment(reply, depth: 1))
            }
            if state.continuation != nil {
                result.append(.moreReplies(comment.id))
            }
        }
        if continuation != nil, !isLoading {
            result.append(.loadMorePage)
        }
        rows = result
        updateEmptyState()
    }

    private func updateEmptyState() {
        let empty = comments.isEmpty && !isLoading
        emptyState.isHidden = !empty
        tableView.isHidden = empty
        if empty {
            emptyState.configure(
                kind: timedOnly
                    ? .custom(icon: .clock, title: "No timed comments", message: "None of these comments point at a moment in the video.")
                    : .noComments
            )
        }
    }

    // MARK: - Actions

    @objc private func handleClose() {
        if let close = onClose {
            close()
            return
        }
        if let navigation = navigationController, navigation.viewControllers.first !== self {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true, completion: nil)
        }
    }

    private func toggleReplies(for comment: Comment) {
        var state = replies[comment.id] ?? Replies()
        if state.isExpanded {
            state.isExpanded = false
            replies[comment.id] = state
            rebuildRows()
            tableView.reloadData()
            return
        }
        if state.items.isEmpty {
            replies[comment.id] = state
            loadReplies(for: comment)
            return
        }
        state.isExpanded = true
        replies[comment.id] = state
        rebuildRows()
        tableView.reloadData()
    }

    private func toggleExpanded(_ comment: Comment) {
        if expanded.contains(comment.id) {
            expanded.remove(comment.id)
        } else {
            expanded.insert(comment.id)
        }
        if let index = rows.firstIndex(where: { row in
            if case .comment(let value, let depth) = row, depth == 0, value.id == comment.id { return true }
            return false
        }) {
            tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .automatic)
        }
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        headerView.backgroundColor = scheme.background
        titleLabel.textColor = scheme.onSurface
        totalLabel.textColor = scheme.onSurfaceVariant
        backButton.setIconColor(scheme.onSurface)
        chipsRow.applyTheme()
        emptyState.applyTheme()
        errorState.applyTheme()
        tableView.reloadData()
    }
}

// MARK: - Data source

extension CommentsViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let row = rows.element(at: indexPath.row) else {
            return UITableViewCell()
        }
        switch row {
        case .comment(let comment, let depth):
            let cell = tableView.dequeueReusableCell(withIdentifier: CommentCell.reuseIdentifier, for: indexPath)
            guard let commentCell = cell as? CommentCell else { return cell }
            let state = replies[comment.id]
            let model = CommentCell.Model(
                comment: comment,
                depth: depth,
                isExpanded: expanded.contains(comment.id),
                repliesExpanded: state?.isExpanded ?? false,
                repliesLoading: state?.isLoading ?? false,
                width: tableView.bounds.width
            )
            commentCell.configure(model: model)
            commentCell.onReadMore = { [weak self] in self?.toggleExpanded(comment) }
            commentCell.onToggleReplies = { [weak self] in self?.toggleReplies(for: comment) }
            commentCell.onAuthor = { [weak self] in
                guard !comment.authorChannelId.isEmpty else { return }
                self?.onOpenChannel?(comment.authorChannelId)
            }
            commentCell.onTimestamp = { [weak self] seconds in
                self?.onSeek?(seconds)
            }
            return commentCell

        case .moreReplies(let commentId):
            let cell = tableView.dequeueReusableCell(withIdentifier: CommentMoreCell.reuseIdentifier, for: indexPath)
            if let moreCell = cell as? CommentMoreCell {
                moreCell.configure(title: "Load more replies", isLoading: replies[commentId]?.isLoading ?? false)
            }
            return cell

        case .loadMorePage:
            let cell = tableView.dequeueReusableCell(withIdentifier: CommentMoreCell.reuseIdentifier, for: indexPath)
            if let moreCell = cell as? CommentMoreCell {
                moreCell.configure(title: "Load more comments", isLoading: isLoadingMore)
            }
            return cell
        }
    }
}

// MARK: - Delegate

extension CommentsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = rows.element(at: indexPath.row) else { return }
        switch row {
        case .moreReplies(let commentId):
            var state = replies[commentId] ?? Replies()
            guard let token = state.continuation else { return }
            state.isLoading = true
            replies[commentId] = state
            rebuildRows()
            tableView.reloadData()
            api.commentReplies(continuation: token) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    var current = self.replies[commentId] ?? Replies()
                    current.isLoading = false
                    if case .success(let page) = result {
                        var known = Set(current.items.map { $0.id })
                        for reply in page.comments where !known.contains(reply.id) {
                            current.items.append(reply)
                            known.insert(reply.id)
                        }
                        current.continuation = page.continuation
                    }
                    self.replies[commentId] = current
                    self.rebuildRows()
                    self.tableView.reloadData()
                }
            }
        case .loadMorePage:
            loadMore()
        case .comment:
            break
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        let height = scrollView.contentSize.height
        let visible = scrollView.bounds.height
        guard height > visible else { return }
        if scrollView.contentOffset.y > height - visible * 2.0 {
            loadMore()
        }
    }
}

// MARK: - Prefetching

extension CommentsViewController: UITableViewDataSourcePrefetching {

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        var urls: [String] = []
        for indexPath in indexPaths {
            guard let row = rows.element(at: indexPath.row) else { continue }
            if case .comment(let comment, _) = row {
                urls.append(comment.authorThumbnail)
            }
        }
        ImageLoader.shared.prefetch(urls)
    }
}

// MARK: - Timestamps

/// Finds the `1:23` / `1:02:03` timestamps inside a comment and turns them into a position.
enum CommentTimestamps {

    private static let regex = try? NSRegularExpression(pattern: "(?<![0-9:])([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)(?![0-9:])")

    /// Every timestamp in `text`, with the range it occupies.
    static func links(in text: String) -> [(range: NSRange, seconds: TimeInterval)] {
        guard let regex = regex else { return [] }
        let full = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: full.length))
        var result: [(range: NSRange, seconds: TimeInterval)] = []
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let range = match.range(at: 1)
            let stamp = full.substring(with: range)
            result.append((range, seconds(stamp)))
        }
        return result
    }

    /// "1:02:03" -> 3723.
    static func seconds(_ stamp: String) -> TimeInterval {
        let parts = stamp.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return 0.0 }
        var total: Double = 0.0
        for part in parts {
            total = total * 60.0 + part
        }
        return total
    }

    /// How long ago a comment was posted, from YouTube's own wording ("3 weeks ago").
    ///
    /// The wording is already localised, so this reads the number and the unit rather than parsing a
    /// date. A comment whose wording is not a relative one sorts to the end.
    static func age(_ text: String) -> TimeInterval {
        let lower = text.lowercased()
        let number = Double(lower.components(separatedBy: CharacterSet.decimalDigits.inverted).joined())
            ?? Double(lower.split(separator: " ").first(where: { Int($0) != nil }) ?? "")
            ?? 0.0
        if lower.contains("second") { return number }
        if lower.contains("minute") { return number * 60.0 }
        if lower.contains("hour") { return number * 3600.0 }
        if lower.contains("day") { return number * 86_400.0 }
        if lower.contains("week") { return number * 604_800.0 }
        if lower.contains("month") { return number * 2_592_000.0 }
        if lower.contains("year") { return number * 31_536_000.0 }
        return TimeInterval.greatestFiniteMagnitude
    }
}

// MARK: - Comment cell

/// One comment, or one reply indented under its parent.
final class CommentCell: UITableViewCell {

    static let reuseIdentifier = "CommentCell"

    struct Model {
        let comment: Comment
        let depth: Int
        let isExpanded: Bool
        let repliesExpanded: Bool
        let repliesLoading: Bool
        let width: CGFloat
    }

    /// Called when the viewer asks for the rest of a long comment.
    var onReadMore: (() -> Void)?
    /// Called when the viewer opens or closes the replies.
    var onToggleReplies: (() -> Void)?
    /// Called when the viewer taps the author.
    var onAuthor: (() -> Void)?
    /// Called when the viewer taps a timestamp in the comment.
    var onTimestamp: ((TimeInterval) -> Void)?

    private let threadLine = UIView()
    private let avatarView = AsyncImageView()
    private let authorLabel = UILabel()
    private let timeLabel = UILabel()
    private let pinnedLabel = UILabel()
    private let textLabel = TimestampLabel()
    private let readMoreButton = UIButton(type: .custom)
    private let likeIcon = FlowIconView()
    private let likeLabel = UILabel()
    private let repliesButton = UIButton(type: .custom)

    private var leadingConstraint: NSLayoutConstraint?
    private var isOverflowing = false

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

        threadLine.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(threadLine)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.applyCornerRadius(18.0)
        contentView.addSubview(avatarView)

        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        authorLabel.font = FlowTypography.labelMediumEmphasized
        authorLabel.isUserInteractionEnabled = true
        authorLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleAuthor)))
        contentView.addSubview(authorLabel)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = FlowTypography.bodySmall
        contentView.addSubview(timeLabel)

        pinnedLabel.translatesAutoresizingMaskIntoConstraints = false
        pinnedLabel.font = FlowTypography.labelSmall
        pinnedLabel.text = "Pinned by creator"
        contentView.addSubview(pinnedLabel)

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = FlowTypography.bodyMedium
        textLabel.numberOfLines = 4
        textLabel.onTimestamp = { [weak self] seconds in
            self?.onTimestamp?(seconds)
        }
        contentView.addSubview(textLabel)

        readMoreButton.translatesAutoresizingMaskIntoConstraints = false
        readMoreButton.titleLabel?.font = FlowTypography.labelSmallEmphasized
        readMoreButton.contentHorizontalAlignment = .left
        readMoreButton.addTarget(self, action: #selector(handleReadMore), for: .touchUpInside)
        contentView.addSubview(readMoreButton)

        likeIcon.translatesAutoresizingMaskIntoConstraints = false
        likeIcon.icon = .heart
        likeIcon.iconSize = 14.0
        contentView.addSubview(likeIcon)

        likeLabel.translatesAutoresizingMaskIntoConstraints = false
        likeLabel.font = FlowTypography.labelSmall
        contentView.addSubview(likeLabel)

        repliesButton.translatesAutoresizingMaskIntoConstraints = false
        repliesButton.titleLabel?.font = FlowTypography.labelMediumEmphasized
        repliesButton.contentHorizontalAlignment = .left
        repliesButton.addTarget(self, action: #selector(handleReplies), for: .touchUpInside)
        contentView.addSubview(repliesButton)

        let leading = avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin)
        leadingConstraint = leading

        NSLayoutConstraint.activate([
            leading,
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),
            avatarView.widthAnchor.constraint(equalToConstant: 36.0),
            avatarView.heightAnchor.constraint(equalToConstant: 36.0),

            threadLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin + 17.0),
            threadLine.widthAnchor.constraint(equalToConstant: 1.5),
            threadLine.topAnchor.constraint(equalTo: contentView.topAnchor),
            threadLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            authorLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: FlowSpacing.lg),
            authorLabel.topAnchor.constraint(equalTo: avatarView.topAnchor),

            timeLabel.leadingAnchor.constraint(equalTo: authorLabel.trailingAnchor, constant: FlowSpacing.sm),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            timeLabel.firstBaselineAnchor.constraint(equalTo: authorLabel.firstBaselineAnchor),

            pinnedLabel.leadingAnchor.constraint(equalTo: authorLabel.leadingAnchor),
            pinnedLabel.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: FlowSpacing.xxs),

            textLabel.leadingAnchor.constraint(equalTo: authorLabel.leadingAnchor),
            textLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            textLabel.topAnchor.constraint(equalTo: pinnedLabel.bottomAnchor, constant: FlowSpacing.xs),

            readMoreButton.leadingAnchor.constraint(equalTo: textLabel.leadingAnchor),
            readMoreButton.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: FlowSpacing.xxs),
            readMoreButton.heightAnchor.constraint(equalToConstant: 20.0),

            likeIcon.leadingAnchor.constraint(equalTo: textLabel.leadingAnchor),
            likeIcon.topAnchor.constraint(equalTo: readMoreButton.bottomAnchor, constant: FlowSpacing.xs),
            likeIcon.widthAnchor.constraint(equalToConstant: 14.0),
            likeIcon.heightAnchor.constraint(equalToConstant: 14.0),

            likeLabel.leadingAnchor.constraint(equalTo: likeIcon.trailingAnchor, constant: FlowSpacing.xs),
            likeLabel.centerYAnchor.constraint(equalTo: likeIcon.centerYAnchor),

            repliesButton.leadingAnchor.constraint(equalTo: likeLabel.trailingAnchor, constant: FlowSpacing.xl),
            repliesButton.centerYAnchor.constraint(equalTo: likeIcon.centerYAnchor),
            repliesButton.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            repliesButton.heightAnchor.constraint(equalToConstant: 24.0),

            likeIcon.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),
        ])
        applyTheme()
    }

    /// Fills the cell.
    func configure(model: Model) {
        let comment = model.comment
        let indent = CGFloat(model.depth) * 34.0
        leadingConstraint?.constant = FlowSpacing.screenMargin + indent
        threadLine.isHidden = model.depth == 0

        avatarView.setImage(url: comment.authorThumbnail)
        authorLabel.text = comment.author
        timeLabel.text = comment.publishedTime
        pinnedLabel.isHidden = !comment.isPinned

        let built = CommentTimestamps.build(
            text: comment.text,
            color: FlowTheme.shared.scheme.onSurface,
            accent: FlowTheme.shared.scheme.primary,
            font: FlowTypography.bodyMedium
        )
        textLabel.attributedText = built.text
        textLabel.links = built.links
        textLabel.numberOfLines = model.isExpanded ? 0 : 4

        let available = max(80.0, model.width - FlowSpacing.screenMargin * 2.0 - 36.0 - FlowSpacing.lg - indent)
        isOverflowing = model.isExpanded ? false : CommentCell.overflows(built.text, width: available, lines: 4)
        readMoreButton.isHidden = !isOverflowing && !model.isExpanded
        readMoreButton.setTitle(model.isExpanded ? "Show less" : "Read more", for: .normal)

        likeLabel.text = comment.likeCount > 0 ? Formatters.compactCount(comment.likeCount) : ""
        likeIcon.isHidden = comment.likeCount <= 0
        likeLabel.isHidden = comment.likeCount <= 0

        if comment.replyCount > 0 {
            repliesButton.isHidden = false
            if model.repliesLoading {
                repliesButton.setTitle("Loading replies…", for: .normal)
                repliesButton.isEnabled = false
            } else if model.repliesExpanded {
                repliesButton.setTitle("Hide replies", for: .normal)
                repliesButton.isEnabled = true
            } else {
                repliesButton.setTitle("View " + String(comment.replyCount) + (comment.replyCount == 1 ? " reply" : " replies"), for: .normal)
                repliesButton.isEnabled = true
            }
        } else {
            repliesButton.isHidden = true
        }

        accessibilityLabel = comment.author + ": " + comment.text
        applyTheme()
    }

    private static func overflows(_ text: NSAttributedString, width: CGFloat, lines: Int) -> Bool {
        let scratch = UILabel()
        scratch.attributedText = text
        scratch.numberOfLines = 0
        let full = scratch.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        scratch.numberOfLines = lines
        let clamped = scratch.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        return full > clamped + 0.5
    }

    /// Repaints the cell in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        authorLabel.textColor = scheme.onSurface
        timeLabel.textColor = scheme.onSurfaceVariant
        pinnedLabel.textColor = scheme.onSurfaceVariant
        likeLabel.textColor = scheme.onSurfaceVariant
        likeIcon.iconColor = scheme.onSurfaceVariant
        threadLine.backgroundColor = scheme.outlineVariant
        readMoreButton.setTitleColor(scheme.onSurfaceVariant, for: .normal)
        repliesButton.setTitleColor(scheme.primary, for: .normal)
        textLabel.applyTheme()
    }

    @objc private func handleReadMore() {
        onReadMore?()
    }

    @objc private func handleReplies() {
        onToggleReplies?()
    }

    @objc private func handleAuthor() {
        onAuthor?()
    }
}

// MARK: - More cell

/// The "load more" row, used for both the next page and a thread's next page of replies.
final class CommentMoreCell: UITableViewCell {

    static let reuseIdentifier = "CommentMoreCell"

    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .gray)

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

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.labelLargeEmphasized
        contentView.addSubview(titleLabel)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        contentView.addSubview(spinner)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.md),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.md),

            spinner.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: FlowSpacing.md),
            spinner.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        applyTheme()
    }

    /// Sets the row's wording and whether it is waiting on the network.
    func configure(title: String, isLoading: Bool) {
        titleLabel.text = title
        if isLoading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        applyTheme()
    }

    private func applyTheme() {
        titleLabel.textColor = FlowTheme.shared.scheme.primary
    }
}

// MARK: - Timestamp label

/// A comment's text, with its timestamps tinted and tappable.
///
/// The label is a plain `UILabel` rather than a text view so the cell can self-size, and the tap is
/// resolved through a throwaway `NSLayoutManager` laid out at the label's own width, which is what
/// turns a touch point into a character index without asking the label for private geometry.
final class TimestampLabel: UILabel {

    /// The timestamps inside the text, as ranges into the attributed string.
    var links: [(range: NSRange, seconds: TimeInterval)] = []

    /// Called when the viewer taps a timestamp.
    var onTimestamp: ((TimeInterval) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    /// Repaints the text in the current palette, keeping the timestamp tint.
    func applyTheme() {
        guard let attributed = attributedText else { return }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let scheme = FlowTheme.shared.scheme
        let full = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: scheme.onSurface, range: full)
        for link in links where link.range.location + link.range.length <= mutable.length {
            mutable.addAttribute(.foregroundColor, value: scheme.primary, range: link.range)
        }
        attributedText = mutable
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let attributed = attributedText, !links.isEmpty else { return }
        let point = gesture.location(in: self)

        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0.0
        container.maximumNumberOfLines = numberOfLines
        container.lineBreakMode = lineBreakMode
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        let used = layoutManager.usedRect(for: container)
        let offsetY = max(0.0, (bounds.height - used.height) / 2.0)
        let adjusted = CGPoint(x: point.x, y: point.y - offsetY)
        guard adjusted.y >= 0.0, adjusted.y <= used.height else { return }
        let index = layoutManager.characterIndex(
            for: adjusted,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        for link in links where NSLocationInRange(index, link.range) {
            onTimestamp?(link.seconds)
            return
        }
    }
}

// MARK: - Comment text

extension CommentTimestamps {

    /// Builds the comment's attributed text and the links inside it.
    static func build(
        text: String,
        color: UIColor,
        accent: UIColor,
        font: UIFont
    ) -> (text: NSAttributedString, links: [(range: NSRange, seconds: TimeInterval)]) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineHeightMultiple = 1.15
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
        let links = links(in: text)
        for link in links where link.range.location + link.range.length <= attributed.length {
            attributed.addAttribute(.foregroundColor, value: accent, range: link.range)
        }
        return (attributed, links)
    }
}

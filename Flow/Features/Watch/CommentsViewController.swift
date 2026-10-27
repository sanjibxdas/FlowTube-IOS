import UIKit

/// A video's comment section.
///
/// The list is the Android `FlowCommentsList` ported to a plain `UITableView`: a 40-point avatar,
/// the author with YouTube's `@` prefix, the relative time, the comment body, the like count and,
/// for a top-level comment, a control that loads and reveals its replies. Replies are fetched with
/// the comment's own continuation and are indented under their parent, exactly as the Compose list
/// draws them.
///
/// Ordering is client-side. YouTube serves one order per continuation and the app has no account,
/// so the initial continuation is the "Top" order; "Newest" and "Oldest" re-order the pages that
/// have been loaded. That is the same compromise the Android app makes for its "Oldest" chip, and
/// it is why switching the sort does not refetch.
final class CommentsViewController: UIViewController {

    /// The orders the chips offer, matching `CommentSortFilter` in the Android app.
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

    // MARK: - Navigation

    /// Called with a comment author's channel id when their avatar or name is tapped.
    var onOpenChannel: ((String) -> Void)?
    /// Called with a timestamp when a comment contains one. The watch screen seeks the player.
    var onSeek: ((TimeInterval) -> Void)?
    /// Called when the viewer closes a comments screen that was presented rather than pushed.
    var onClose: (() -> Void)?

    // MARK: - Dependencies

    private let videoId: String
    private let api: YouTubeAPI
    private let initialContinuation: String?

    // MARK: - Views

    private let sortRow = FlowChipRow()
    private let separator = UIView.hairline()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let footerSpinner = UIActivityIndicatorView(style: .gray)
    private let emptyState = FlowEmptyState.make(kind: .noComments)
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")

    // MARK: - State

    /// One row of the flattened list. A reply is a row of its own so the table can recycle it.
    private struct Row {
        enum Kind {
            case comment
            case reply
            case moreReplies
        }

        let kind: Kind
        let comment: Comment?
        let depth: Int
        let parentId: String
    }

    private var comments: [Comment] = []
    private var rows: [Row] = []
    private var continuation: String?
    private var totalText: String?
    private var sort: Sort = .top
    private var isLoading = false
    private var isLoadingMore = false
    private var hasLoaded = false

    /// Comments whose body is shown in full.
    private var expandedText: Set<String> = []
    /// Comments whose replies are on screen.
    private var expandedReplies: Set<String> = []
    /// Comments whose reply request is in flight.
    private var loadingReplies: Set<String> = []
    /// The continuation that loads the next page of each comment's replies.
    private var replyContinuations: [String: String] = [:]

    private var themeToken: ObservationToken?

    // MARK: - Construction

    init(videoId: String, continuation: String? = nil, api: YouTubeAPI = YouTubeAPI()) {
        self.videoId = videoId
        self.initialContinuation = continuation
        self.api = api
        super.init(nibName: nil, bundle: nil)
        title = "Comments"
    }

    required init?(coder: NSCoder) {
        videoId = ""
        initialContinuation = nil
        api = YouTubeAPI()
        super.init(coder: coder)
        title = "Comments"
    }

    deinit {
        themeToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildSortRow()
        buildTable()
        buildStates()
        installCloseButtonIfNeeded()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
        loadFirstPage()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    // MARK: - Build

    private func buildSortRow() {
        sortRow.translatesAutoresizingMaskIntoConstraints = false
        sortRow.setTitles(Sort.allCases.map { $0.title }, selectedIndex: sort.rawValue)
        sortRow.onSelect = { [weak self] index in
            guard let self = self else { return }
            let chosen = Sort(rawValue: index) ?? .top
            guard chosen != self.sort else { return }
            self.sort = chosen
            self.rebuildRows()
            self.tableView.setContentOffset(.zero, animated: false)
        }
        view.addSubview(sortRow)

        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        NSLayoutConstraint.activate([
            sortRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sortRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sortRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            sortRow.heightAnchor.constraint(equalToConstant: 40.0),

            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.topAnchor.constraint(equalTo: sortRow.bottomAnchor),
        ])
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 132.0
        tableView.keyboardDismissMode = .onDrag
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: FlowSpacing.xxl, right: 0)
        tableView.register(CommentCell.self, forCellReuseIdentifier: CommentCell.reuseIdentifier)
        tableView.register(CommentsMoreCell.self, forCellReuseIdentifier: CommentsMoreCell.reuseIdentifier)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildStates() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        for state in [emptyState, errorState] {
            state.isHidden = true
            view.addSubviewForAutoLayout(state)
            NSLayoutConstraint.activate([
                state.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                state.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                state.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
        errorState.onAction = { [weak self] in
            self?.loadFirstPage()
        }

        footerSpinner.hidesWhenStopped = true
        footerSpinner.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 56.0)
    }

    private func installCloseButtonIfNeeded() {
        guard navigationController?.viewControllers.first === self else { return }
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Close",
            style: .plain,
            target: self,
            action: #selector(handleClose)
        )
    }

    // MARK: - Loading

    private func loadFirstPage() {
        guard !isLoading else { return }
        isLoading = true
        hasLoaded = false
        errorState.isHidden = true
        emptyState.isHidden = true
        tableView.isHidden = false
        spinner.startAnimating()

        api.comments(videoId: videoId, continuation: initialContinuation) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                self.spinner.stopAnimating()
                self.hasLoaded = true
                switch result {
                case .success(let page):
                    self.comments = page.comments
                    self.continuation = page.continuation
                    if let total = page.totalText, !total.trimmed.isEmpty {
                        self.totalText = total
                        self.title = "Comments · " + total
                    }
                    self.rebuildRows()
                    self.updateEmptyState()
                case .failure(let error):
                    self.showError(error)
                }
            }
        }
    }

    private func loadMore() {
        guard !isLoadingMore, !isLoading, let token = continuation, !token.isEmpty else { return }
        isLoadingMore = true
        tableView.tableFooterView = footerSpinner
        footerSpinner.startAnimating()

        api.comments(videoId: videoId, continuation: token) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoadingMore = false
                self.footerSpinner.stopAnimating()
                self.tableView.tableFooterView = nil
                switch result {
                case .success(let page):
                    let known = Set(self.comments.map { $0.id })
                    let fresh = page.comments.filter { !known.contains($0.id) }
                    self.comments.append(contentsOf: fresh)
                    self.continuation = page.continuation
                    self.rebuildRows()
                case .failure(let error):
                    FlowSnackbar.showError(error.displayMessage)
                }
            }
        }
    }

    private func loadReplies(for commentId: String) {
        guard !loadingReplies.contains(commentId) else { return }
        guard let index = comments.firstIndex(where: { $0.id == commentId }) else { return }
        let token = replyContinuations[commentId] ?? comments[index].continuation
        guard let continuationToken = token, !continuationToken.isEmpty else { return }

        loadingReplies.insert(commentId)
        rebuildRows()

        api.commentReplies(continuation: continuationToken) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loadingReplies.remove(commentId)
                switch result {
                case .success(let page):
                    self.mergeReplies(page, into: commentId)
                case .failure(let error):
                    FlowSnackbar.showError(error.displayMessage)
                    self.rebuildRows()
                }
            }
        }
    }

    private func mergeReplies(_ page: CommentsPage, into commentId: String) {
        guard let index = comments.firstIndex(where: { $0.id == commentId }) else { return }
        var parent = comments[index]
        let known = Set(parent.replies.map { $0.id })
        let fresh = page.comments.filter { !known.contains($0.id) }
        parent.replies.append(contentsOf: fresh)
        if parent.replyCount < parent.replies.count {
            parent.replyCount = parent.replies.count
        }
        comments[index] = parent
        replyContinuations[commentId] = page.continuation
        expandedReplies.insert(commentId)
        rebuildRows()
    }

    private func showError(_ error: FlowError) {
        tableView.isHidden = true
        emptyState.isHidden = true
        errorState.isHidden = false
        errorState.configure(kind: .error, actionTitle: "Retry")
        errorState.applyTheme()
        FlowSnackbar.showError(error.displayMessage)
    }

    private func updateEmptyState() {
        let empty = comments.isEmpty
        emptyState.isHidden = !empty
        tableView.isHidden = empty
        if empty {
            emptyState.configure(
                kind: .custom(
                    icon: .comment,
                    title: "No comments yet",
                    message: "Comments are turned off for this video, or none have been posted yet."
                )
            )
            emptyState.applyTheme()
        }
    }

    // MARK: - Rows

    private func rebuildRows() {
        var built: [Row] = []
        for comment in sortedComments() {
            built.append(Row(kind: .comment, comment: comment, depth: 0, parentId: comment.id))
            guard expandedReplies.contains(comment.id) else { continue }
            for reply in comment.replies {
                built.append(Row(kind: .reply, comment: reply, depth: 1, parentId: comment.id))
            }
            if replyContinuations[comment.id] != nil {
                built.append(Row(kind: .moreReplies, comment: nil, depth: 1, parentId: comment.id))
            }
        }
        rows = built
        tableView.reloadData()
    }

    /// Pinned comments stay on top in every order, which is what YouTube itself does.
    private func sortedComments() -> [Comment] {
        let pinned = comments.filter { $0.isPinned }
        let rest = comments.filter { !$0.isPinned }
        let ordered: [Comment]
        switch sort {
        case .top:
            ordered = rest.sorted { $0.likeCount > $1.likeCount }
        case .newest:
            ordered = rest.sorted { CommentsViewController.relativeSeconds($0.publishedTime) < CommentsViewController.relativeSeconds($1.publishedTime) }
        case .oldest:
            ordered = rest.sorted { CommentsViewController.relativeSeconds($0.publishedTime) > CommentsViewController.relativeSeconds($1.publishedTime) }
        }
        return pinned + ordered
    }

    /// Turns YouTube's "3 weeks ago" into seconds, so the three orders share one comparator.
    private static func relativeSeconds(_ text: String) -> TimeInterval {
        let lower = text.lowercased().trimmed
        let digits = lower.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        let number = TimeInterval(digits) ?? 0.0
        if lower.contains("second") { return number }
        if lower.contains("minute") { return number * 60.0 }
        if lower.contains("hour") { return number * 3_600.0 }
        if lower.contains("day") { return number * 86_400.0 }
        if lower.contains("week") { return number * 604_800.0 }
        if lower.contains("month") { return number * 2_592_000.0 }
        if lower.contains("year") { return number * 31_536_000.0 }
        return TimeInterval.greatestFiniteMagnitude
    }

    // MARK: - Actions

    @objc private func handleClose() {
        if let close = onClose {
            close()
            return
        }
        dismiss(animated: true, completion: nil)
    }

    private func toggleText(for commentId: String) {
        if expandedText.contains(commentId) {
            expandedText.remove(commentId)
        } else {
            expandedText.insert(commentId)
        }
        if let index = rows.firstIndex(where: { $0.comment?.id == commentId }) {
            tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .fade)
        }
    }

    private func toggleReplies(for comment: Comment) {
        if expandedReplies.contains(comment.id) {
            expandedReplies.remove(comment.id)
            rebuildRows()
            return
        }
        if !comment.replies.isEmpty {
            expandedReplies.insert(comment.id)
            rebuildRows()
            return
        }
        loadReplies(for: comment.id)
    }

    // MARK: - Theme

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        tableView.backgroundColor = .clear
        separator.backgroundColor = scheme.outlineVariant
        sortRow.applyTheme()
        emptyState.applyTheme()
        errorState.applyTheme()
        tableView.reloadData()
    }
}

// MARK: - Table data

extension CommentsViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let row = rows.element(at: indexPath.row) else {
            return UITableViewCell()
        }
        switch row.kind {
        case .moreReplies:
            let cell = tableView.dequeueReusableCell(withIdentifier: CommentsMoreCell.reuseIdentifier, for: indexPath) as! CommentsMoreCell
            cell.configure(isLoading: loadingReplies.contains(row.parentId))
            cell.onTap = { [weak self] in
                self?.loadReplies(for: row.parentId)
            }
            cell.applyTheme()
            return cell

        case .comment, .reply:
            let cell = tableView.dequeueReusableCell(withIdentifier: CommentCell.reuseIdentifier, for: indexPath) as! CommentCell
            guard let comment = row.comment else { return cell }
            let isTopLevel = row.kind == .comment
            let repliesVisible = expandedReplies.contains(comment.id)
            cell.configure(
                comment: comment,
                depth: row.depth,
                isReply: !isTopLevel,
                textExpanded: expandedText.contains(comment.id),
                repliesVisible: repliesVisible,
                hasMoreReplies: replyContinuations[comment.id] != nil,
                isLoadingReplies: loadingReplies.contains(comment.id)
            )
            cell.onToggleText = { [weak self] in
                self?.toggleText(for: comment.id)
            }
            cell.onToggleReplies = { [weak self] in
                self?.toggleReplies(for: comment)
            }
            cell.onOpenChannel = { [weak self] in
                guard !comment.authorChannelId.isEmpty else { return }
                self?.onOpenChannel?(comment.authorChannelId)
            }
            cell.applyTheme()
            return cell
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        let remaining = scrollView.contentSize.height - scrollView.contentOffset.y - scrollView.bounds.height
        if remaining < 320.0 {
            loadMore()
        }
    }
}

// MARK: - Comment cell

/// One comment or reply.
///
/// The layout follows the Android item: the avatar on the left, a pinned banner above the author,
/// the author and the relative time, the body (four lines until tapped), the like count and the
/// reply control. Replies are indented by `depth`.
final class CommentCell: UITableViewCell {

    static let reuseIdentifier = "CommentCell"

    /// Called when the body is tapped, so the owner can expand or collapse it.
    var onToggleText: (() -> Void)?
    /// Called when the reply control is tapped.
    var onToggleReplies: (() -> Void)?
    /// Called when the avatar or author is tapped.
    var onOpenChannel: (() -> Void)?

    private let avatarView = AsyncImageView()
    private let pinnedRow = UIStackView()
    private let pinnedIcon = FlowIconView()
    private let pinnedLabel = UILabel()
    private let authorLabel = UILabel()
    private let verifiedIcon = FlowIconView()
    private let timeLabel = UILabel()
    private let textLabel = UILabel()
    private let likeIcon = FlowIconView()
    private let likeLabel = UILabel()
    private let heartedIcon = FlowIconView()
    private let repliesButton = UIButton(type: .system)
    private let stack = UIStackView()
    private let authorRow = UIStackView()
    private let actionRow = UIStackView()

    private var avatarLeading: NSLayoutConstraint!

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

        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.applyCornerRadius(18.0)
        avatarView.isUserInteractionEnabled = true
        avatarView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleAuthorTap)))
        contentView.addSubviewForAutoLayout(avatarView)

        pinnedIcon.icon = .chapter
        pinnedIcon.iconSize = 12.0
        pinnedIcon.translatesAutoresizingMaskIntoConstraints = false
        pinnedIcon.widthAnchor.constraint(equalToConstant: 12.0).isActive = true
        pinnedIcon.heightAnchor.constraint(equalToConstant: 12.0).isActive = true

        pinnedLabel.font = FlowTypography.labelSmall
        pinnedLabel.numberOfLines = 1

        pinnedRow.axis = .horizontal
        pinnedRow.spacing = FlowSpacing.sm
        pinnedRow.alignment = .center
        pinnedRow.addArrangedSubview(pinnedIcon)
        pinnedRow.addArrangedSubview(pinnedLabel)

        authorLabel.font = FlowTypography.titleSmallEmphasized
        authorLabel.numberOfLines = 1
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.isUserInteractionEnabled = true
        authorLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleAuthorTap)))

        verifiedIcon.icon = .verified
        verifiedIcon.iconSize = 14.0
        verifiedIcon.translatesAutoresizingMaskIntoConstraints = false
        verifiedIcon.widthAnchor.constraint(equalToConstant: 14.0).isActive = true
        verifiedIcon.heightAnchor.constraint(equalToConstant: 14.0).isActive = true

        timeLabel.font = FlowTypography.bodySmall
        timeLabel.numberOfLines = 1
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let authorSpacer = UIView()
        authorSpacer.translatesAutoresizingMaskIntoConstraints = false
        authorSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        authorRow.axis = .horizontal
        authorRow.spacing = FlowSpacing.sm
        authorRow.alignment = .center
        authorRow.addArrangedSubview(authorLabel)
        authorRow.addArrangedSubview(verifiedIcon)
        authorRow.addArrangedSubview(timeLabel)
        authorRow.addArrangedSubview(authorSpacer)

        textLabel.font = FlowTypography.bodyMedium
        textLabel.numberOfLines = 4
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.isUserInteractionEnabled = true
        textLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTextTap)))

        likeIcon.icon = .liked
        likeIcon.iconSize = 14.0
        likeIcon.translatesAutoresizingMaskIntoConstraints = false
        likeIcon.widthAnchor.constraint(equalToConstant: 14.0).isActive = true
        likeIcon.heightAnchor.constraint(equalToConstant: 14.0).isActive = true

        likeLabel.font = FlowTypography.labelMedium
        likeLabel.numberOfLines = 1

        heartedIcon.icon = .heart
        heartedIcon.iconSize = 14.0
        heartedIcon.translatesAutoresizingMaskIntoConstraints = false
        heartedIcon.widthAnchor.constraint(equalToConstant: 14.0).isActive = true
        heartedIcon.heightAnchor.constraint(equalToConstant: 14.0).isActive = true

        let actionSpacer = UIView()
        actionSpacer.translatesAutoresizingMaskIntoConstraints = false
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        repliesButton.titleLabel?.font = FlowTypography.labelLargeEmphasized
        repliesButton.contentHorizontalAlignment = .left
        repliesButton.addTarget(self, action: #selector(handleRepliesTap), for: .touchUpInside)

        actionRow.axis = .horizontal
        actionRow.spacing = FlowSpacing.sm
        actionRow.alignment = .center
        actionRow.addArrangedSubview(likeIcon)
        actionRow.addArrangedSubview(likeLabel)
        actionRow.addArrangedSubview(heartedIcon)
        actionRow.addArrangedSubview(actionSpacer)
        actionRow.addArrangedSubview(repliesButton)

        stack.axis = .vertical
        stack.spacing = FlowSpacing.xs
        stack.alignment = .fill
        stack.addArrangedSubview(pinnedRow)
        stack.addArrangedSubview(authorRow)
        stack.addArrangedSubview(textLabel)
        stack.addArrangedSubview(actionRow)
        contentView.addSubviewForAutoLayout(stack)

        avatarLeading = avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xl)
        NSLayoutConstraint.activate([
            avatarLeading,
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),
            avatarView.widthAnchor.constraint(equalToConstant: 36.0),
            avatarView.heightAnchor.constraint(equalToConstant: 36.0),

            stack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: FlowSpacing.lg),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.xl),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),
        ])
        applyTheme()
    }

    /// Fills the cell from a comment.
    func configure(
        comment: Comment,
        depth: Int,
        isReply: Bool,
        textExpanded: Bool,
        repliesVisible: Bool,
        hasMoreReplies: Bool,
        isLoadingReplies: Bool
    ) {
        avatarLeading.constant = FlowSpacing.xl + CGFloat(depth) * 28.0
        avatarView.setImage(url: comment.authorThumbnail)
        avatarView.isHidden = isReply && comment.authorThumbnail.isEmpty

        pinnedRow.isHidden = !comment.isPinned
        pinnedLabel.text = "Pinned by creator"

        authorLabel.text = CommentsViewController.displayAuthor(comment.author)
        verifiedIcon.isHidden = !comment.isVerified
        timeLabel.text = comment.publishedTime

        textLabel.text = comment.text
        textLabel.numberOfLines = textExpanded ? 0 : 4
        textLabel.lineBreakMode = textExpanded ? .byWordWrapping : .byTruncatingTail

        likeIcon.isHidden = comment.likeCount <= 0
        likeLabel.isHidden = comment.likeCount <= 0
        likeLabel.text = comment.likeCountText.isEmpty
            ? Formatters.compactCount(comment.likeCount)
            : comment.likeCountText
        heartedIcon.isHidden = !comment.isHearted

        let replyCount = max(comment.replyCount, comment.replies.count)
        let showReplies = !isReply && (replyCount > 0 || comment.continuation != nil)
        repliesButton.isHidden = !showReplies
        if isLoadingReplies {
            repliesButton.setTitle("Loading replies…", for: .normal)
            repliesButton.isEnabled = false
        } else {
            repliesButton.isEnabled = true
            if repliesVisible {
                repliesButton.setTitle(hasMoreReplies ? "Load more replies" : "Hide replies", for: .normal)
            } else if replyCount == 1 {
                repliesButton.setTitle("View 1 reply", for: .normal)
            } else if replyCount > 1 {
                repliesButton.setTitle("View \(replyCount) replies", for: .normal)
            } else {
                repliesButton.setTitle("View replies", for: .normal)
            }
        }

        accessibilityLabel = [comment.author, comment.text].filter { !$0.isEmpty }.joined(separator: ", ")
        applyTheme()
    }

    /// Repaints the cell in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        authorLabel.textColor = scheme.onSurface
        timeLabel.textColor = scheme.onSurfaceVariant
        textLabel.textColor = scheme.onSurface
        pinnedLabel.textColor = scheme.onSurfaceVariant
        pinnedIcon.iconColor = scheme.onSurfaceVariant
        verifiedIcon.iconColor = scheme.onSurfaceVariant
        likeIcon.iconColor = scheme.onSurfaceVariant
        likeLabel.textColor = scheme.onSurfaceVariant
        heartedIcon.iconColor = FlowTheme.youtubeRed
        repliesButton.setTitleColor(scheme.primary, for: .normal)
        avatarView.placeholderColor = scheme.surfaceVariant
    }

    @objc private func handleTextTap() {
        onToggleText?()
    }

    @objc private func handleRepliesTap() {
        onToggleReplies?()
    }

    @objc private func handleAuthorTap() {
        onOpenChannel?()
    }
}

// MARK: - More replies cell

/// The row under a loaded reply thread that asks for the next page of replies.
final class CommentsMoreCell: UITableViewCell {

    static let reuseIdentifier = "CommentsMoreCell"

    var onTap: (() -> Void)?

    private let button = FlowButton.make("Load more replies", style: .text)
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

        button.onTap = { [weak self] in self?.onTap?() }
        contentView.addSubviewForAutoLayout(button)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        contentView.addSubview(spinner)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 60.0),
            button.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.xs),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.md),
            button.heightAnchor.constraint(equalToConstant: 36.0),

            spinner.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: FlowSpacing.md),
            spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
    }

    /// Shows the spinner in place of the label while a page is loading.
    func configure(isLoading: Bool) {
        button.isHidden = isLoading
        if isLoading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        button.applyTheme()
    }
}

// MARK: - Helpers

extension CommentsViewController {

    /// YouTube hands back bare names; the app shows them the way the site does.
    static func displayAuthor(_ author: String) -> String {
        let trimmed = author.trimmed
        return trimmed.hasPrefix("@") ? trimmed : "@" + trimmed
    }
}

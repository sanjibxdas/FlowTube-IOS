import UIKit

/// The base for the player's full-height sheets.
///
/// `FlowSheet` wraps a plain view, which is right for menus but wrong for a screen with its own
/// table, keyboard handling and scrolling: those need a view controller. This class is that
/// controller — it draws the dimming, the rounded container and the grabber, drags down to dismiss,
/// and leaves a `contentView` for the subclass to fill.
///
/// It is deliberately a sibling of `FlowSheet` rather than a use of it, so a subclass keeps its own
/// lifecycle and can be presented, dismissed and laid out like any other controller.
class PlaybackSheetController: UIViewController, UIGestureRecognizerDelegate {

    /// The area the subclass fills, inside the rounded container and below the grabber.
    let contentView = UIView()

    private let dimmingView = UIView()
    private let containerView = UIView()
    private let grabber = UIView()
    private var containerBottom: NSLayoutConstraint?
    private var dragStart: CGFloat = 0.0
    private var hasAppeared = false

    /// Called after the sheet has dismissed itself.
    var onDismiss: (() -> Void)?

    /// How much of the screen's height the sheet takes. 1.0 fills the safe area.
    var sheetHeightFraction: CGFloat {
        return 0.92
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        definesPresentationContext = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        modalPresentationStyle = .overFullScreen
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        dimmingView.alpha = 0.0
        view.addSubview(dimmingView)
        NSLayoutConstraint.activate([
            dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        dimmingView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleDimmingTap)))

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = FlowShapes.sheet
        containerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        containerView.layer.masksToBounds = true
        view.addSubview(containerView)

        grabber.translatesAutoresizingMaskIntoConstraints = false
        grabber.layer.cornerRadius = 2.0
        grabber.layer.masksToBounds = true
        containerView.addSubview(grabber)

        containerView.addSubviewForAutoLayout(contentView)

        containerBottom = containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        containerBottom?.isActive = true
        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            grabber.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            grabber.topAnchor.constraint(equalTo: containerView.topAnchor, constant: FlowSpacing.md),
            grabber.widthAnchor.constraint(equalToConstant: 42.0),
            grabber.heightAnchor.constraint(equalToConstant: 4.0),

            contentView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: FlowSpacing.md),
            contentView.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        containerView.addGestureRecognizer(pan)

        applyTheme()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard containerView.constraints.first(where: { $0.firstAttribute == .height }) == nil else { return }
        let available = view.bounds.height - view.safeAreaInsets.top
        let height = available * min(max(sheetHeightFraction, 0.3), 1.0)
        let constraint = containerView.heightAnchor.constraint(equalToConstant: height)
        constraint.priority = .defaultHigh
        constraint.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.layoutIfNeeded()
        containerBottom?.constant = containerView.bounds.height + 40.0
        view.layoutIfNeeded()
        containerBottom?.constant = 0.0
        FlowMotion.animateEmphasized({
            self.dimmingView.alpha = 1.0
            self.view.layoutIfNeeded()
        }, completion: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        UIAccessibility.post(notification: .screenChanged, argument: contentView)
    }

    /// Presents the sheet from `presenter`, or the top-most controller when nil.
    func present(from presenter: UIViewController? = nil) {
        let host = presenter ?? FlowSheet.topViewController()
        host?.present(self, animated: true, completion: nil)
    }

    /// Dismisses the sheet, running `onDismiss` afterwards.
    func dismissSheet(animated: Bool = true) {
        guard presentingViewController != nil else {
            onDismiss?()
            return
        }
        guard animated else {
            dismiss(animated: false) { [weak self] in
                self?.onDismiss?()
            }
            return
        }
        containerBottom?.constant = containerView.bounds.height + 40.0
        FlowMotion.animateEmphasized({
            self.dimmingView.alpha = 0.0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.dismiss(animated: false) { [weak self] in
                self?.onDismiss?()
            }
        })
    }

    /// Repaints the chrome in the current palette. Subclasses override and call super.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        containerView.backgroundColor = scheme.surfaceContainerLow
        grabber.backgroundColor = scheme.outlineVariant
    }

    @objc private func handleDimmingTap() {
        dismissSheet()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view).y
        switch recognizer.state {
        case .began:
            dragStart = containerBottom?.constant ?? 0.0
        case .changed:
            let proposed = max(0.0, dragStart + translation)
            containerBottom?.constant = proposed
            let progress = min(max(proposed / max(containerView.bounds.height, 1.0), 0.0), 1.0)
            dimmingView.alpha = 1.0 - progress * 0.8
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: view).y
            let current = containerBottom?.constant ?? 0.0
            if velocity > 900.0 || current > containerView.bounds.height * 0.3 {
                dismissSheet()
            } else {
                containerBottom?.constant = 0.0
                FlowMotion.animateEmphasized({
                    self.dimmingView.alpha = 1.0
                    self.view.layoutIfNeeded()
                }, completion: nil)
            }
        default:
            break
        }
    }

    /// Lets a scroll view that is already scrolled keep its drag instead of dismissing the sheet.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let point = pan.location(in: containerView)
        if let scroll = scrollView(at: point, in: containerView), scroll.contentOffset.y > 0.0 {
            return false
        }
        return true
    }

    private func scrollView(at point: CGPoint, in root: UIView) -> UIScrollView? {
        for subview in root.subviews {
            if let scroll = subview as? UIScrollView {
                let converted = scroll.convert(point, from: root)
                if scroll.bounds.contains(converted) { return scroll }
            }
            if let nested = scrollView(at: point, in: subview) {
                return nested
            }
        }
        return nil
    }
}

/// The lyrics sheet.
///
/// It shows the synchronised lyrics for the current track, highlights the line being sung, and
/// scrolls itself to keep that line in the middle of the sheet. A tap on a line seeks there, which
/// is the only way to use lyrics as a chapter list.
///
/// Auto-scroll yields to the viewer: once the list is dragged the sheet stops following the song
/// and offers a button back to the current line, so reading ahead does not fight the player. The
/// offset buttons exist because lyric timings are often a fraction of a second out.
final class LyricsViewController: PlaybackSheetController {

    // MARK: - Dependencies

    private let videoId: String
    private let title: String
    private let artist: String
    private let duration: TimeInterval
    private let service: PlaybackService
    private let bag = ObservationBag()

    // MARK: - Views

    private let headerView = UIView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let sourceLabel = UILabel()
    private let offsetDownButton = FlowIconButton()
    private let offsetUpButton = FlowIconButton()
    private let offsetLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyState = FlowEmptyState.make(kind: .custom(
        icon: .notes,
        title: "No lyrics",
        message: "This track has no lyrics available."
    ))
    private let spinner = UIActivityIndicatorView(style: .white)
    private let followButton = FlowButton.make("Back to current line", style: .tonal, icon: .notes)

    // MARK: - State

    private var lines: [LyricLine] = []
    private var isSynchronised = false
    private var activeIndex: Int = -1
    /// Seconds added to the player position when matching a line, so a late or early source can be
    /// nudged into place.
    private var syncOffset: TimeInterval = 0.0
    /// Whether the sheet follows the song. False once the viewer scrolls by hand.
    private var isFollowing = true
    private var hasScrolledOnce = false

    /// How far one tap of the offset buttons moves the lyrics.
    private static let offsetStep: TimeInterval = 0.5

    // MARK: - Init

    init(
        videoId: String,
        title: String,
        artist: String,
        duration: TimeInterval,
        service: PlaybackService = .shared
    ) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.duration = duration
        self.service = service
        super.init()
    }

    required init?(coder: NSCoder) {
        videoId = ""
        title = ""
        artist = ""
        duration = 0
        service = .shared
        super.init(coder: coder)
    }

    deinit {
        bag.cancelAll()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildHeader()
        buildTable()
        buildEmptyState()
        buildFollowButton()
        observePlayback()
        observeTheme()
        applyTheme()
        loadLyrics()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The first render happens before the table has a size; scrolling then would be a no-op.
        if !hasScrolledOnce, !lines.isEmpty, tableView.bounds.height > 0.0 {
            hasScrolledOnce = true
            scrollToActive(animated: false)
        }
    }

    // MARK: - Construction

    private func buildHeader() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headerView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleMediumEmphasized
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        headerView.addSubview(titleLabel)

        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        artistLabel.font = FlowTypography.bodySmall
        artistLabel.numberOfLines = 1
        artistLabel.lineBreakMode = .byTruncatingTail
        headerView.addSubview(artistLabel)

        sourceLabel.translatesAutoresizingMaskIntoConstraints = false
        sourceLabel.font = FlowTypography.labelSmall
        headerView.addSubview(sourceLabel)

        offsetDownButton.configure(icon: .previous, color: FlowTheme.shared.onSurfaceVariant, size: 16.0)
        offsetDownButton.accessibilityLabel = "Lyrics earlier"
        offsetDownButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.adjustOffset(by: -LyricsViewController.offsetStep)
        }
        headerView.addSubviewForAutoLayout(offsetDownButton)

        offsetLabel.translatesAutoresizingMaskIntoConstraints = false
        offsetLabel.font = FlowTypography.labelMedium
        offsetLabel.textAlignment = .center
        offsetLabel.text = "0.0 s"
        headerView.addSubview(offsetLabel)

        offsetUpButton.configure(icon: .next, color: FlowTheme.shared.onSurfaceVariant, size: 16.0)
        offsetUpButton.accessibilityLabel = "Lyrics later"
        offsetUpButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.adjustOffset(by: LyricsViewController.offsetStep)
        }
        headerView.addSubviewForAutoLayout(offsetUpButton)

        titleLabel.text = title
        artistLabel.text = artist

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 72.0),

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: FlowSpacing.xl),
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: FlowSpacing.xs),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: offsetDownButton.leadingAnchor, constant: -FlowSpacing.md),

            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1.0),
            artistLabel.trailingAnchor.constraint(lessThanOrEqualTo: offsetDownButton.leadingAnchor, constant: -FlowSpacing.md),

            sourceLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sourceLabel.topAnchor.constraint(equalTo: artistLabel.bottomAnchor, constant: 1.0),
            sourceLabel.trailingAnchor.constraint(lessThanOrEqualTo: offsetDownButton.leadingAnchor, constant: -FlowSpacing.md),

            offsetUpButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -FlowSpacing.md),
            offsetUpButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            offsetUpButton.widthAnchor.constraint(equalToConstant: 36.0),
            offsetUpButton.heightAnchor.constraint(equalToConstant: 36.0),

            offsetLabel.trailingAnchor.constraint(equalTo: offsetUpButton.leadingAnchor),
            offsetLabel.centerYAnchor.constraint(equalTo: offsetUpButton.centerYAnchor),
            offsetLabel.widthAnchor.constraint(equalToConstant: 52.0),

            offsetDownButton.trailingAnchor.constraint(equalTo: offsetLabel.leadingAnchor),
            offsetDownButton.centerYAnchor.constraint(equalTo: offsetUpButton.centerYAnchor),
            offsetDownButton.widthAnchor.constraint(equalToConstant: 36.0),
            offsetDownButton.heightAnchor.constraint(equalToConstant: 36.0),
        ])
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44.0
        tableView.contentInset = UIEdgeInsets(top: 12.0, left: 0.0, bottom: 96.0, right: 0.0)
        tableView.register(LyricLineCell.self, forCellReuseIdentifier: LyricLineCell.reuseIdentifier)
        contentView.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func buildEmptyState() {
        contentView.addSubview(emptyState)
        emptyState.isHidden = true
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            emptyState.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xxl),
            emptyState.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.xxl),
        ])

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        spinner.color = FlowTheme.shared.onSurfaceVariant
        contentView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        spinner.startAnimating()
    }

    private func buildFollowButton() {
        followButton.translatesAutoresizingMaskIntoConstraints = false
        followButton.isHidden = true
        followButton.onTap = { [weak self] in
            guard let self = self else { return }
            self.isFollowing = true
            self.followButton.isHidden = true
            self.scrollToActive(animated: true)
        }
        contentView.addSubview(followButton)
        NSLayoutConstraint.activate([
            followButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            followButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),
        ])
    }

    // MARK: - Loading

    private func loadLyrics() {
        if let cached = LyricsService.shared.cached(for: videoId) {
            apply(lyrics: cached)
            return
        }
        LyricsService.shared.lyrics(
            videoId: videoId,
            title: title,
            artist: artist,
            duration: Int(duration)
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let lyrics):
                if let lyrics = lyrics {
                    self.apply(lyrics: lyrics)
                } else {
                    self.showNoLyrics()
                }
            case .failure:
                // The service turns "every provider missed" into success-with-nil; a real failure
                // means the network is gone, which is worth saying.
                self.showNoLyrics(message: "Lyrics could not be loaded. Check your connection.")
            }
        }
    }

    private func apply(lyrics: Lyrics) {
        spinner.stopAnimating()
        lines = lyrics.lines.filter { !$0.text.trimmed.isEmpty }
        isSynchronised = lyrics.isSynchronised && lines.contains { $0.startTime != nil }
        sourceLabel.text = lyrics.source.uppercased()
        emptyState.isHidden = !lines.isEmpty
        tableView.isHidden = lines.isEmpty
        offsetDownButton.isHidden = !isSynchronised
        offsetUpButton.isHidden = !isSynchronised
        offsetLabel.isHidden = !isSynchronised
        tableView.reloadData()
        updateActiveLine(position: service.currentPosition, animated: false)
    }

    private func showNoLyrics(message: String = "This track has no lyrics available.") {
        spinner.stopAnimating()
        lines = []
        isSynchronised = false
        tableView.isHidden = true
        emptyState.isHidden = false
        emptyState.configure(kind: .custom(icon: .notes, title: "No lyrics", message: message))
        sourceLabel.text = nil
        offsetDownButton.isHidden = true
        offsetUpButton.isHidden = true
        offsetLabel.isHidden = true
    }

    // MARK: - Playback

    private func observePlayback() {
        bag.add(service.state.observe { [weak self] snapshot in
            guard let self = self else { return }
            guard snapshot.item?.videoId == self.videoId else { return }
            self.updateActiveLine(position: snapshot.position, animated: true)
        })
    }

    private func observeTheme() {
        bag.add(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
    }

    override func applyTheme() {
        super.applyTheme()
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        artistLabel.textColor = scheme.onSurfaceVariant
        sourceLabel.textColor = scheme.onSurfaceVariant
        offsetLabel.textColor = scheme.onSurfaceVariant
        offsetDownButton.setIconColor(scheme.onSurfaceVariant)
        offsetUpButton.setIconColor(scheme.onSurfaceVariant)
        spinner.color = scheme.onSurfaceVariant
        followButton.applyTheme()
        emptyState.applyTheme()
        tableView.reloadData()
    }

    /// Finds the line being sung at `position` and moves the highlight.
    private func updateActiveLine(position: TimeInterval, animated: Bool) {
        guard isSynchronised, !lines.isEmpty else { return }
        let adjusted = position + syncOffset
        var index = -1
        for (offset, line) in lines.enumerated() {
            guard let start = line.startTime else { continue }
            if start <= adjusted {
                index = offset
            } else {
                break
            }
        }
        guard index != activeIndex else { return }
        let previous = activeIndex
        activeIndex = index
        var paths: [IndexPath] = []
        if previous >= 0, previous < lines.count {
            paths.append(IndexPath(row: previous, section: 0))
        }
        if index >= 0, index < lines.count {
            paths.append(IndexPath(row: index, section: 0))
        }
        if !paths.isEmpty {
            tableView.reloadRows(at: paths, with: .none)
        }
        if isFollowing {
            scrollToActive(animated: animated)
        }
    }

    /// Centres the active line, or the first line when nothing is active yet.
    private func scrollToActive(animated: Bool) {
        guard !lines.isEmpty, tableView.bounds.height > 0.0 else { return }
        let row = activeIndex >= 0 ? activeIndex : 0
        let indexPath = IndexPath(row: min(row, lines.count - 1), section: 0)
        tableView.scrollToRow(at: indexPath, at: .middle, animated: animated)
    }

    private func adjustOffset(by delta: TimeInterval) {
        syncOffset = min(max(syncOffset + delta, -30.0), 30.0)
        offsetLabel.text = String(format: "%+.1f s", syncOffset)
        // Force a re-evaluation: the offset moved, so the same line index may now be a different line.
        activeIndex = -1
        tableView.reloadData()
        updateActiveLine(position: service.currentPosition, animated: true)
    }
}

// MARK: - Table

extension LyricsViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return lines.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LyricLineCell.reuseIdentifier, for: indexPath)
        guard let lyricCell = cell as? LyricLineCell, let line = lines.element(at: indexPath.row) else {
            return cell
        }
        lyricCell.configure(
            text: line.text,
            isActive: indexPath.row == activeIndex,
            isSynced: isSynchronised
        )
        return lyricCell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard isSynchronised, let line = lines.element(at: indexPath.row), let start = line.startTime else { return }
        service.seek(to: max(start - syncOffset, 0.0))
        activeIndex = indexPath.row
        isFollowing = true
        followButton.isHidden = true
        tableView.reloadData()
        scrollToActive(animated: true)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard isSynchronised else { return }
        isFollowing = false
        followButton.isHidden = false
    }
}

/// One lyric line. The active line is larger and in the accent colour; the rest recede.
final class LyricLineCell: UITableViewCell {

    static let reuseIdentifier = "LyricLineCell"

    private let label = UILabel()

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
        selectionStyle = .none
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.font = FlowTypography.titleMedium
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xxl),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.xxl),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.sm),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.sm),
        ])
    }

    func configure(text: String, isActive: Bool, isSynced: Bool) {
        let scheme = FlowTheme.shared.scheme
        label.text = text
        if isActive {
            label.font = FlowTypography.titleLargeEmphasized
            label.textColor = scheme.primary
        } else {
            label.font = FlowTypography.titleMedium
            label.textColor = scheme.onSurfaceVariant
        }
        if isSynced {
            accessibilityHint = "Double tap to play from this line"
            accessibilityTraits = isActive ? [.button, .selected] : .button
        } else {
            accessibilityHint = nil
            accessibilityTraits = isActive ? [.staticText, .selected] : .staticText
        }
    }
}

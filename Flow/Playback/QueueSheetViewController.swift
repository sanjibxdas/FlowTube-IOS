import UIKit

/// The queue sheet, shared by the video and music players.
///
/// It lists what is playing and what comes next, allows reordering by drag, removal by swipe and
/// jumping by tap, and carries the shuffle and repeat controls at the top. The sheet edits the
/// service's queue directly, so it stays correct when playback advances while it is open.
final class QueueSheetViewController: PlaybackSheetController {

    private let service: PlaybackService
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let header = UIView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let shuffleButton = FlowIconButton()
    private let repeatButton = FlowIconButton()
    private let emptyState = FlowEmptyState.make(kind: .custom(
        icon: .queue,
        title: "Nothing queued",
        message: "Start a video or a song and it will show up here."
    ))
    private let bag = ObservationBag()

    /// The queue sheet takes a little less than the full height so the player stays visible behind it.
    override var sheetHeightFraction: CGFloat {
        return 0.86
    }

    init(service: PlaybackService = .shared) {
        self.service = service
        super.init()
    }

    required init?(coder: NSCoder) {
        service = .shared
        super.init(coder: coder)
    }

    deinit {
        bag.cancelAll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildHeader()
        buildTable()
        buildEmptyState()
        bag.add(service.state.observeChanges { [weak self] _ in
            self?.reload()
        })
        bag.add(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
        reload()
    }

    private func buildHeader() {
        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleLarge
        titleLabel.text = "Up next"
        header.addSubview(titleLabel)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = FlowTypography.bodySmall
        header.addSubview(countLabel)

        shuffleButton.configure(icon: .shuffle, color: FlowTheme.shared.onSurfaceVariant, size: 22.0)
        shuffleButton.accessibilityLabel = "Shuffle"
        shuffleButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            guard let self = self else { return }
            self.service.setShuffle(!self.service.queue.shuffleEnabled)
        }
        header.addSubviewForAutoLayout(shuffleButton)

        repeatButton.configure(icon: .repeatAll, color: FlowTheme.shared.onSurfaceVariant, size: 22.0)
        repeatButton.accessibilityLabel = "Repeat"
        repeatButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.service.cycleRepeatMode()
        }
        header.addSubviewForAutoLayout(repeatButton)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 64.0),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: FlowSpacing.xl),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: FlowSpacing.md),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shuffleButton.leadingAnchor, constant: -FlowSpacing.md),

            countLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1.0),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: shuffleButton.leadingAnchor, constant: -FlowSpacing.md),

            repeatButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -FlowSpacing.md),
            repeatButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            repeatButton.widthAnchor.constraint(equalToConstant: 44.0),
            repeatButton.heightAnchor.constraint(equalToConstant: 44.0),

            shuffleButton.trailingAnchor.constraint(equalTo: repeatButton.leadingAnchor, constant: -FlowSpacing.xs),
            shuffleButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            shuffleButton.widthAnchor.constraint(equalToConstant: 44.0),
            shuffleButton.heightAnchor.constraint(equalToConstant: 44.0),
        ])
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 64.0
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.register(QueueRowCell.self, forCellReuseIdentifier: QueueRowCell.reuseIdentifier)
        tableView.setEditing(true, animated: false)
        tableView.allowsSelectionDuringEditing = true
        contentView.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: header.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func buildEmptyState() {
        contentView.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            emptyState.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xxl),
            emptyState.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.xxl),
        ])
    }

    private func reload() {
        let queue = service.queue
        titleLabel.text = queue.title ?? "Up next"
        let position = queue.currentIndex + 1
        countLabel.text = queue.isEmpty ? "Empty" : "\(position) / \(queue.count)"
        emptyState.isHidden = !queue.isEmpty
        tableView.isHidden = queue.isEmpty
        let scheme = FlowTheme.shared.scheme
        shuffleButton.setIconColor(queue.shuffleEnabled ? scheme.primary : scheme.onSurfaceVariant)
        switch queue.repeatMode {
        case .off:
            repeatButton.setIcon(.repeatAll)
            repeatButton.setIconColor(scheme.onSurfaceVariant)
            repeatButton.accessibilityLabel = "Repeat off"
        case .all:
            repeatButton.setIcon(.repeatAll)
            repeatButton.setIconColor(scheme.primary)
            repeatButton.accessibilityLabel = "Repeat all"
        case .one:
            repeatButton.setIcon(.repeatOne)
            repeatButton.setIconColor(scheme.primary)
            repeatButton.accessibilityLabel = "Repeat one"
        }
        tableView.reloadData()
    }

    override func applyTheme() {
        super.applyTheme()
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        countLabel.textColor = scheme.onSurfaceVariant
        emptyState.applyTheme()
        tableView.reloadData()
        reload()
    }
}

// MARK: - Table

extension QueueSheetViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return service.queue.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: QueueRowCell.reuseIdentifier, for: indexPath)
        guard let queueCell = cell as? QueueRowCell, let item = service.queue.item(at: indexPath.row) else {
            return cell
        }
        queueCell.configure(
            item: item,
            isCurrent: indexPath.row == service.queue.currentIndex,
            position: indexPath.row + 1
        )
        return queueCell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        service.playQueueItem(at: indexPath.row)
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return .delete
    }

    func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete else { return }
        service.removeQueueItem(at: indexPath.row)
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        service.moveQueueItem(from: sourceIndexPath.row, to: destinationIndexPath.row)
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        return false
    }
}

/// One queue row: the artwork, the title and artist, the duration, and a marker for the current
/// track.
final class QueueRowCell: UITableViewCell {

    static let reuseIdentifier = "QueueRowCell"

    private let artwork = AsyncImageView(frame: .zero)
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let durationLabel = UILabel()
    private let playingIndicator = FlowIconView()
    /// The duration's trailing edge, which moves in when the reorder control appears.
    private var durationTrailing: NSLayoutConstraint?

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
        selectionStyle = .default

        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.contentMode = .scaleAspectFill
        artwork.applyCornerRadius(FlowShapes.thumbnail)
        contentView.addSubview(artwork)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.bodyLarge
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)

        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        artistLabel.font = FlowTypography.bodySmall
        artistLabel.numberOfLines = 1
        contentView.addSubview(artistLabel)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = FlowTypography.labelMedium
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)
        contentView.addSubview(durationLabel)

        playingIndicator.translatesAutoresizingMaskIntoConstraints = false
        playingIndicator.icon = .equalizer
        playingIndicator.iconSize = 16.0
        contentView.addSubview(playingIndicator)

        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xl),
            artwork.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artwork.widthAnchor.constraint(equalToConstant: 44.0),
            artwork.heightAnchor.constraint(equalToConstant: 44.0),

            titleLabel.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.md),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: durationLabel.leadingAnchor, constant: -FlowSpacing.md),

            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1.0),
            artistLabel.trailingAnchor.constraint(lessThanOrEqualTo: playingIndicator.leadingAnchor, constant: -FlowSpacing.md),

            playingIndicator.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -FlowSpacing.md),
            playingIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            playingIndicator.widthAnchor.constraint(equalToConstant: 16.0),
            playingIndicator.heightAnchor.constraint(equalToConstant: 16.0),

            durationLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        let trailing = durationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.xl)
        trailing.priority = .defaultHigh
        trailing.isActive = true
        durationTrailing = trailing
    }

    func configure(item: PlaybackQueueItem, isCurrent: Bool, position: Int) {
        let scheme = FlowTheme.shared.scheme
        artwork.setImage(url: item.thumbnailUrl, placeholder: scheme.surfaceContainerHighest)
        titleLabel.text = item.title
        titleLabel.textColor = isCurrent ? scheme.primary : scheme.onSurface
        artistLabel.text = item.channelName
        artistLabel.textColor = scheme.onSurfaceVariant
        durationLabel.text = item.duration > 0 ? Formatters.playbackTime(item.duration) : ""
        durationLabel.textColor = scheme.onSurfaceVariant
        playingIndicator.isHidden = !isCurrent
        playingIndicator.iconColor = scheme.primary
        accessibilityLabel = "\(position). \(item.title), \(item.channelName)"
        if isCurrent {
            accessibilityTraits = [.button, .selected]
        } else {
            accessibilityTraits = .button
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The reorder control UIKit adds while editing occupies the trailing edge. The duration
        // keeps its distance from it rather than sliding underneath.
        let reorderWidth = contentView.superview?.subviews
            .filter { $0 !== contentView && $0.bounds.width > 0.0 && $0.bounds.width < 60.0 }
            .reduce(CGFloat(0.0)) { $0 + $1.bounds.width } ?? 0.0
        durationTrailing?.constant = -(FlowSpacing.xl + reorderWidth)
    }
}

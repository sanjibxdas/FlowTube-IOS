import UIKit

/// How the end of the Home feed is drawn. The last row of the feed is always one of these, so a
/// finished feed reads as finished rather than as a list that stopped halfway.
enum HomeStatus {
    /// The next page is in flight.
    case loadingMore
    /// The next page failed; the row carries the reason and offers a retry.
    case loadMoreFailed(String)
    /// There is nothing more to load.
    case end
}

/// One row of the Home feed. The feed is a flat list of these so a single table can draw the whole
/// screen: the continue-watching shelf, the Shorts shelf, horizontal shelves, individual videos and
/// the trailing status row.
enum HomeRow {
    case continueWatching([HistoryEntry])
    case shortsShelf([Video])
    case shelf(VideoShelf)
    case video(Video)
    case status(HomeStatus)

    /// A stable identity, used to diff one feed against the next.
    var id: String {
        switch self {
        case .continueWatching(let entries):
            return "continue:" + entries.map { $0.videoId }.joined(separator: ",")
        case .shortsShelf(let videos):
            return "shorts:" + videos.map { $0.id }.joined(separator: ",")
        case .shelf(let shelf):
            return "shelf:" + shelf.title + ":" + shelf.items.map { $0.id }.joined(separator: ",")
        case .video(let video):
            return "video:" + video.id
        case .status(let status):
            switch status {
            case .loadingMore: return "status:loading"
            case .loadMoreFailed: return "status:failed"
            case .end: return "status:end"
            }
        }
    }

    /// The row's fixed height, or `UITableView.automaticDimension` when it sizes itself.
    var height: CGFloat {
        switch self {
        case .continueWatching: return HomeMetrics.shelfHeight
        case .shortsShelf: return HomeMetrics.shortsShelfHeight
        case .shelf: return HomeMetrics.shelfHeight
        case .video: return UITableView.automaticDimension
        case .status: return HomeMetrics.statusHeight
        }
    }
}

/// The heights the Home list is built from. They are derived from the card sizes so the shelves and
/// the rows line up on every screen width.
enum HomeMetrics {
    static let cardWidth: CGFloat = 240.0
    static let cardThumbnailHeight: CGFloat = cardWidth * 9.0 / 16.0
    static let cardTextHeight: CGFloat = 66.0
    static let shelfHeaderHeight: CGFloat = 44.0
    static let shelfHeight: CGFloat = shelfHeaderHeight + cardThumbnailHeight + cardTextHeight + 8.0
    static let shortsCardWidth: CGFloat = 120.0
    static let shortsCardHeight: CGFloat = shortsCardWidth * 16.0 / 9.0
    static let shortsShelfHeight: CGFloat = shelfHeaderHeight + shortsCardHeight + 48.0
    static let statusHeight: CGFloat = 72.0
    static let horizontalMargin: CGFloat = FlowSpacing.screenMargin
}

// MARK: - Video row

/// A full-width video row: a 16:9 thumbnail, a two-line title and one metadata line. This is the
/// vertical row the feed falls back to for shelves that hold only one or two videos.
final class HomeVideoCell: UITableViewCell {

    static let reuseIdentifier = "HomeVideoCell"

    private let thumbnailView = AsyncImageView(frame: .zero)
    private let durationLabel = PaddedLabel()
    private let liveBadge = PaddedLabel()
    private let titleLabel = UILabel()
    private let metadataLabel = UILabel()

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

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.applyCornerRadius(FlowShapes.thumbnail)
        contentView.addSubview(thumbnailView)

        durationLabel.font = FlowTypography.labelMedium
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        durationLabel.layer.cornerRadius = 4.0
        durationLabel.layer.masksToBounds = true
        durationLabel.textInsets = UIEdgeInsets(top: 1, left: 4, bottom: 1, right: 4)
        durationLabel.isHidden = true
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(durationLabel)

        liveBadge.font = FlowTypography.labelMedium
        liveBadge.textColor = .white
        liveBadge.backgroundColor = FlowTheme.youtubeRed
        liveBadge.layer.cornerRadius = 4.0
        liveBadge.layer.masksToBounds = true
        liveBadge.textInsets = UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        liveBadge.text = "LIVE"
        liveBadge.isHidden = true
        liveBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(liveBadge)

        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        metadataLabel.font = FlowTypography.bodySmall
        metadataLabel.numberOfLines = 1
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(metadataLabel)

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: HomeMetrics.horizontalMargin),
            thumbnailView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -HomeMetrics.horizontalMargin),
            thumbnailView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.md),
            thumbnailView.heightAnchor.constraint(equalTo: thumbnailView.widthAnchor, multiplier: 9.0 / 16.0),

            durationLabel.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: -FlowSpacing.sm),
            durationLabel.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: -FlowSpacing.sm),

            liveBadge.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor, constant: FlowSpacing.sm),
            liveBadge.topAnchor.constraint(equalTo: thumbnailView.topAnchor, constant: FlowSpacing.sm),

            titleLabel.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: FlowSpacing.md),

            metadataLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metadataLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),
            metadataLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),
        ])

        applyTheme()
    }

    /// Fills the row from a video.
    func configure(with video: Video) {
        titleLabel.text = video.title
        thumbnailView.setImage(url: video.thumbnailUrl)
        durationLabel.text = video.isLive ? nil : Formatters.durationBadge(TimeInterval(video.duration))
        durationLabel.isHidden = durationLabel.text == nil
        liveBadge.isHidden = !video.isLive

        var parts: [String] = []
        if !video.channelName.isEmpty { parts.append(video.channelName) }
        if video.viewCount > 0 { parts.append(Formatters.viewCount(Int(video.viewCount))) }
        if !video.uploadDate.isEmpty { parts.append(video.uploadDate) }
        metadataLabel.text = parts.joined(separator: " · ")

        accessibilityLabel = [video.title, video.channelName].filter { !$0.isEmpty }.joined(separator: ", ")
        applyTheme()
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        metadataLabel.textColor = scheme.onSurfaceVariant
    }
}

// MARK: - Shelf row

/// A horizontal shelf of video cards, used for the feed's recommendation shelves and for the
/// continue-watching row. The cards are built here so the cell owns their tap handling.
final class HomeShelfCell: UITableViewCell {

    static let reuseIdentifier = "HomeShelfCell"

    private let shelf = FlowShelf()

    /// Called with the video of the card the viewer tapped.
    var onSelect: ((Video) -> Void)?
    /// Called with the history entry of the card the viewer tapped.
    var onSelectEntry: ((HistoryEntry) -> Void)?
    /// Called when the shelf's trailing action is tapped.
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
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        shelf.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(shelf)
        NSLayoutConstraint.activate([
            shelf.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            shelf.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            shelf.topAnchor.constraint(equalTo: contentView.topAnchor),
            shelf.heightAnchor.constraint(equalToConstant: HomeMetrics.shelfHeight),
        ])
        shelf.onAction = { [weak self] in self?.onMore?() }
    }

    /// Fills the shelf with videos.
    func configure(title: String, subtitle: String?, videos: [Video], showsAvatar: Bool, actionTitle: String?) {
        shelf.configure(title: title, subtitle: subtitle, actionTitle: actionTitle)
        var cards: [UIView] = []
        for video in videos {
            let card = FlowVideoCard()
            card.cardWidth = HomeMetrics.cardWidth
            card.configure(with: video, showsAvatar: showsAvatar)
            card.onTap = { [weak self] in self?.onSelect?(video) }
            cards.append(card)
        }
        shelf.setItems(cards)
        shelf.applyTheme()
    }

    /// Fills the shelf with continue-watching entries, each showing how far the viewer got.
    func configure(title: String, entries: [HistoryEntry], actionTitle: String?) {
        shelf.configure(title: title, subtitle: nil, actionTitle: actionTitle)
        var cards: [UIView] = []
        for entry in entries {
            let card = FlowVideoCard()
            card.cardWidth = HomeMetrics.cardWidth
            card.configure(with: entry)
            card.onTap = { [weak self] in self?.onSelectEntry?(entry) }
            cards.append(card)
        }
        shelf.setItems(cards)
        shelf.applyTheme()
    }

    /// Repaints the shelf in the current palette.
    func applyTheme() {
        shelf.applyTheme()
    }
}

// MARK: - Shorts shelf

/// One 9:16 Shorts tile: the vertical thumbnail, a two-line title and the channel name.
final class ShortsTileView: UIControl {

    private let thumbnailView = AsyncImageView(frame: .zero)
    private let titleLabel = UILabel()
    private let channelLabel = UILabel()

    /// Called when the tile is tapped.
    var onTap: (() -> Void)?

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
        widthAnchor.constraint(equalToConstant: HomeMetrics.shortsCardWidth).isActive = true

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.applyCornerRadius(FlowShapes.medium)
        addSubview(thumbnailView)

        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        channelLabel.font = FlowTypography.bodySmall
        channelLabel.numberOfLines = 1
        channelLabel.lineBreakMode = .byTruncatingTail
        channelLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(channelLabel)

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbnailView.topAnchor.constraint(equalTo: topAnchor),
            thumbnailView.heightAnchor.constraint(equalToConstant: HomeMetrics.shortsCardHeight),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: FlowSpacing.sm),

            channelLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            channelLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            channelLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),
            channelLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        accessibilityTraits = .button
        applyTheme()
    }

    /// Fills the tile from a Short.
    func configure(with video: Video) {
        titleLabel.text = video.title
        channelLabel.text = video.channelName
        thumbnailView.setImage(url: video.thumbnailUrl)
        accessibilityLabel = [video.title, video.channelName].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Repaints the tile in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        channelLabel.textColor = scheme.onSurfaceVariant
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1.0 }
    }

    @objc private func handleTap() {
        onTap?()
    }
}

/// The horizontal Shorts shelf on Home: a header and a scrolling row of 9:16 tiles.
final class HomeShortsCell: UITableViewCell {

    static let reuseIdentifier = "HomeShortsCell"

    private let header = FlowSectionHeader()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    /// Called with the Short the viewer tapped.
    var onSelect: ((Video) -> Void)?
    /// Called when the shelf's trailing action is tapped.
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
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        header.translatesAutoresizingMaskIntoConstraints = false
        header.onAction = { [weak self] in self?.onMore?() }
        contentView.addSubview(header)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        contentView.addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = FlowSpacing.lg
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: HomeMetrics.horizontalMargin),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -HomeMetrics.horizontalMargin),
            header.topAnchor.constraint(equalTo: contentView.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: HomeMetrics.shortsCardHeight + 48.0),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: HomeMetrics.horizontalMargin),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -HomeMetrics.horizontalMargin),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    /// Fills the shelf with Shorts.
    func configure(videos: [Video], actionTitle: String?) {
        header.configure(title: "Shorts", subtitle: nil, actionTitle: actionTitle)
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for video in videos {
            let tile = ShortsTileView()
            tile.configure(with: video)
            tile.onTap = { [weak self] in self?.onSelect?(video) }
            stack.addArrangedSubview(tile)
        }
        header.applyTheme()
    }

    /// Repaints the shelf in the current palette.
    func applyTheme() {
        header.applyTheme()
        for view in stack.arrangedSubviews {
            (view as? ShortsTileView)?.applyTheme()
        }
    }
}

// MARK: - Status row

/// The feed's last row: a spinner while the next page loads, a retry when it failed, or a quiet
/// end marker when there is nothing left.
final class HomeStatusCell: UITableViewCell {

    static let reuseIdentifier = "HomeStatusCell"

    private let spinner = UIActivityIndicatorView(style: .gray)
    private let messageLabel = UILabel()
    private let retryButton = FlowButton.make("Retry", style: .text)
    private let stack = UIStackView()

    /// Called when the retry button is tapped.
    var onRetry: (() -> Void)?

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

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = FlowSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        messageLabel.font = FlowTypography.bodyMedium
        messageLabel.numberOfLines = 2

        retryButton.onTap = { [weak self] in self?.onRetry?() }
        retryButton.isHidden = true

        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(retryButton)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: FlowSpacing.xl),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -FlowSpacing.xl),
        ])
        applyTheme()
    }

    /// Draws one of the three end states.
    func configure(status: HomeStatus) {
        switch status {
        case .loadingMore:
            spinner.isHidden = false
            spinner.startAnimating()
            messageLabel.text = nil
            retryButton.isHidden = true
        case .loadMoreFailed(let message):
            spinner.isHidden = true
            spinner.stopAnimating()
            messageLabel.text = message
            retryButton.isHidden = false
        case .end:
            spinner.isHidden = true
            spinner.stopAnimating()
            messageLabel.text = "End of results"
            retryButton.isHidden = true
        }
        applyTheme()
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        messageLabel.textColor = scheme.onSurfaceVariant
        retryButton.applyTheme()
    }
}

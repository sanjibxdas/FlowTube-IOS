import UIKit

/// A Material 3 surface: a rounded rectangle filled with one of the surface-container roles, with
/// an optional hairline outline. Cards never use shadows or gradients — the palette's container
/// ladder is what separates them from the page.
final class FlowCard: UIView {

    /// Which rung of the surface ladder the card sits on.
    enum Elevation {
        case low
        case standard
        case high
        case highest

        func color(in scheme: FlowColorScheme) -> UIColor {
            switch self {
            case .low: return scheme.surfaceContainerLow
            case .standard: return scheme.surfaceContainer
            case .high: return scheme.surfaceContainerHigh
            case .highest: return scheme.surfaceContainerHighest
            }
        }
    }

    private(set) var elevation: Elevation = .standard
    private(set) var cornerRadius: CGFloat = FlowShapes.card
    private var showsOutline = false

    /// The view content is added to. Pinned to the card's content margins.
    let contentView = UIView()

    private var contentInsets: UIEdgeInsets = .all(FlowSpacing.lg)

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
        addSubviewForAutoLayout(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInsets.left),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInsets.right),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: contentInsets.top),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -contentInsets.bottom),
        ])
        applyTheme()
    }

    /// Creates a card with the given elevation and corner radius.
    static func make(elevation: Elevation = .standard, cornerRadius: CGFloat = FlowShapes.card) -> FlowCard {
        let card = FlowCard()
        card.elevation = elevation
        card.cornerRadius = cornerRadius
        card.applyTheme()
        return card
    }

    /// Sets the content insets. Must be called before content is constrained to the edges.
    func setContentInsets(_ insets: UIEdgeInsets) {
        contentInsets = insets
        for constraint in constraints where constraint.firstItem === contentView || constraint.secondItem === contentView {
            constraint.isActive = false
        }
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }

    /// Draws a hairline border in the outline-variant colour.
    func setShowsOutline(_ shows: Bool) {
        showsOutline = shows
        applyTheme()
    }

    /// Repaints the card in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = elevation.color(in: scheme)
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = false
        if showsOutline {
            layer.borderWidth = 1.0 / UIScreen.main.scale
            layer.borderColor = scheme.outlineVariant.cgColor
        } else {
            layer.borderWidth = 0.0
        }
    }

    /// Makes the whole card respond to a tap, with a pressed tint.
    func makeTappable(target: Any?, action: Selector) {
        isUserInteractionEnabled = true
        let recognizer = UITapGestureRecognizer(target: target, action: action)
        addGestureRecognizer(recognizer)
        accessibilityTraits = .button
    }
}

/// A section header: a title, an optional trailing action and the spacing Material puts above and
/// below it. Every screen's rows are introduced by one of these.
final class FlowSectionHeader: UIView {

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let labels = UIStackView()

    /// Called when the trailing action is tapped.
    var onAction: (() -> Void)?

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
        labels.axis = .vertical
        labels.spacing = FlowSpacing.xxs
        labels.addArrangedSubview(titleLabel)
        labels.addArrangedSubview(subtitleLabel)
        subtitleLabel.isHidden = true
        addSubviewForAutoLayout(labels)

        actionButton.titleLabel?.font = FlowTypography.labelLarge
        actionButton.contentHorizontalAlignment = .trailing
        actionButton.addTarget(self, action: #selector(handleAction), for: .touchUpInside)
        actionButton.isHidden = true
        addSubviewForAutoLayout(actionButton)

        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.lg),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.md),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionButton.centerYAnchor.constraint(equalTo: labels.centerYAnchor),
            actionButton.leadingAnchor.constraint(greaterThanOrEqualTo: labels.trailingAnchor, constant: FlowSpacing.md),
            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32.0),
        ])
        applyTheme()
    }

    /// Creates a header with a title and an optional action title.
    static func make(title: String, subtitle: String? = nil, actionTitle: String? = nil) -> FlowSectionHeader {
        let header = FlowSectionHeader()
        header.configure(title: title, subtitle: subtitle, actionTitle: actionTitle)
        return header
    }

    /// Sets the header's text. An empty action title hides the button.
    func configure(title: String, subtitle: String? = nil, actionTitle: String? = nil) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        if let action = actionTitle, !action.isEmpty {
            actionButton.setTitle(action, for: .normal)
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
        accessibilityLabel = title
    }

    /// Changes the trailing action's title, e.g. from "See all" to "Show less".
    func setActionTitle(_ title: String?) {
        if let text = title, !text.isEmpty {
            actionButton.setTitle(text, for: .normal)
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }

    /// Repaints the header in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.font = FlowTypography.titleLarge
        titleLabel.textColor = scheme.onSurface
        subtitleLabel.font = FlowTypography.bodyMedium
        subtitleLabel.textColor = scheme.onSurfaceVariant
        actionButton.setTitleColor(scheme.primary, for: .normal)
    }

    @objc private func handleAction() {
        onAction?()
    }
}

/// A horizontal shelf: a title and a row of cards that scrolls sideways. Home is built from these.
final class FlowShelf: UIView {

    private let header = FlowSectionHeader()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    /// Called when the header's action is tapped.
    var onAction: (() -> Void)? {
        didSet { header.onAction = onAction }
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
        header.onAction = { [weak self] in self?.onAction?() }
        addSubviewForAutoLayout(header)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.decelerationRate = .fast
        addSubviewForAutoLayout(scrollView)

        stack.axis = .horizontal
        stack.spacing = FlowSpacing.lg
        stack.alignment = .top
        scrollView.addSubviewForAutoLayout(stack)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.screenMargin),
            header.topAnchor.constraint(equalTo: topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: FlowSpacing.screenMargin),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    /// Sets the shelf's title and action.
    func configure(title: String, subtitle: String? = nil, actionTitle: String? = nil) {
        header.configure(title: title, subtitle: subtitle, actionTitle: actionTitle)
    }

    /// Replaces the shelf's content with `views`.
    func setItems(_ views: [UIView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views {
            stack.addArrangedSubview(view)
        }
    }

    /// Adds one item to the end of the shelf.
    func addItem(_ view: UIView) {
        stack.addArrangedSubview(view)
    }

    /// Repaints the shelf's chrome in the current palette.
    func applyTheme() {
        header.applyTheme()
    }
}

/// A card that shows a video: a 16:9 thumbnail with a duration badge and a progress bar, then a
/// two-line title and a metadata line. Used by Home, Search, Channel and Related.
final class FlowVideoCard: UIControl {

    private let thumbnailView = AsyncImageView()
    private let durationLabel = PaddedLabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private var progressWidth: NSLayoutConstraint?
    private let titleLabel = UILabel()
    private let metadataLabel = UILabel()
    private let avatarView = AsyncImageView()
    private let liveBadge = PaddedLabel()

    private var progress: Double = 0.0

    /// Called when the card is tapped.
    var onTap: (() -> Void)?

    /// The width of the card. Home shelves use a fixed width so rows line up.
    var cardWidth: CGFloat = 240.0 {
        didSet { widthConstraint?.constant = cardWidth }
    }
    private var widthConstraint: NSLayoutConstraint?

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
        widthConstraint = widthAnchor.constraint(equalToConstant: cardWidth)
        widthConstraint?.isActive = true

        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.applyCornerRadius(FlowShapes.thumbnail)
        addSubviewForAutoLayout(thumbnailView)

        durationLabel.font = FlowTypography.labelMedium
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        durationLabel.layer.cornerRadius = 4.0
        durationLabel.layer.masksToBounds = true
        durationLabel.textInsets = UIEdgeInsets(top: 1, left: 4, bottom: 1, right: 4)
        durationLabel.isHidden = true
        addSubviewForAutoLayout(durationLabel)

        liveBadge.font = FlowTypography.labelMedium
        liveBadge.textColor = .white
        liveBadge.backgroundColor = FlowTheme.youtubeRed
        liveBadge.layer.cornerRadius = 4.0
        liveBadge.layer.masksToBounds = true
        liveBadge.textInsets = UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        liveBadge.text = "LIVE"
        liveBadge.isHidden = true
        addSubviewForAutoLayout(liveBadge)

        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        progressTrack.isHidden = true
        thumbnailView.addSubviewForAutoLayout(progressTrack)
        progressFill.backgroundColor = FlowTheme.youtubeRed
        progressTrack.addSubviewForAutoLayout(progressFill)

        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.applyCornerRadius(16.0)
        avatarView.isHidden = true
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.widthAnchor.constraint(equalToConstant: 32.0).isActive = true
        avatarView.heightAnchor.constraint(equalToConstant: 32.0).isActive = true

        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        metadataLabel.font = FlowTypography.bodySmall
        metadataLabel.numberOfLines = 2

        let textStack = UIStackView(arrangedSubviews: [titleLabel, metadataLabel])
        textStack.axis = .vertical
        textStack.spacing = FlowSpacing.xxs
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [avatarView, textStack])
        row.axis = .horizontal
        row.spacing = FlowSpacing.md
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubviewForAutoLayout(row)

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbnailView.topAnchor.constraint(equalTo: topAnchor),
            thumbnailView.heightAnchor.constraint(equalTo: thumbnailView.widthAnchor, multiplier: 9.0 / 16.0),

            durationLabel.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: -FlowSpacing.sm),
            durationLabel.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: -FlowSpacing.sm),

            liveBadge.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor, constant: FlowSpacing.sm),
            liveBadge.topAnchor.constraint(equalTo: thumbnailView.topAnchor, constant: FlowSpacing.sm),

            progressTrack.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor),
            progressTrack.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 3.0),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),

            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: FlowSpacing.md),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        progressWidth = progressFill.widthAnchor.constraint(equalToConstant: 0.0)
        progressWidth?.isActive = true

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        accessibilityTraits = .button
        applyTheme()
    }

    /// Fills the card from a video model.
    func configure(with video: Video, showsAvatar: Bool = false) {
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

        if showsAvatar, !video.channelThumbnailUrl.isEmpty {
            avatarView.isHidden = false
            avatarView.setImage(url: video.channelThumbnailUrl)
        } else {
            avatarView.isHidden = true
        }
        accessibilityLabel = [video.title, video.channelName].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Fills the card from a history entry, showing how far the viewer got.
    func configure(with entry: HistoryEntry) {
        titleLabel.text = entry.title
        thumbnailView.setImage(url: entry.thumbnailUrl)
        durationLabel.text = Formatters.durationBadge(entry.duration)
        durationLabel.isHidden = durationLabel.text == nil
        liveBadge.isHidden = true
        metadataLabel.text = entry.channelName
        setProgress(entry.progress)
        accessibilityLabel = entry.title
    }

    /// Sets the watch-progress bar under the thumbnail. Zero hides it.
    func setProgress(_ value: Double) {
        progress = min(max(value, 0.0), 1.0)
        progressTrack.isHidden = progress <= 0.0
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = thumbnailView.bounds.width * CGFloat(progress)
        progressWidth?.constant = width
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.7 : 1.0
        }
    }

    /// Repaints the card's text in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        metadataLabel.textColor = scheme.onSurfaceVariant
    }

    @objc private func handleTap() {
        onTap?()
    }
}

/// A label with padding, for badges.
final class PaddedLabel: UILabel {
    var textInsets: UIEdgeInsets = .zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(
            width: base.width + textInsets.left + textInsets.right,
            height: base.height + textInsets.top + textInsets.bottom
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let base = super.sizeThatFits(size)
        return CGSize(
            width: base.width + textInsets.left + textInsets.right,
            height: base.height + textInsets.top + textInsets.bottom
        )
    }
}

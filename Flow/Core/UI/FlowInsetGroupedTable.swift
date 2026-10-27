import UIKit

/// A plain `UITableView` styled the way iOS 13's `.insetGrouped` looks: each section is a rounded
/// card inset from the screen edges, with the header above it and the footer below.
///
/// iOS 12 has no `.insetGrouped` style, so the card is drawn here as a section background view and
/// the separators are inset to match. Everything else — cell reuse, editing, scrolling — is the
/// stock table's, so a screen written against this behaves like any other table screen.
final class FlowInsetGroupedTable: UITableView {

    /// The horizontal inset of each section card. Material's screen margin.
    var cardInset: CGFloat = FlowSpacing.screenMargin {
        didSet { setNeedsLayout() }
    }

    /// The corner radius of each section card.
    var cardCornerRadius: CGFloat = FlowShapes.medium {
        didSet { setNeedsLayout() }
    }

    /// Extra space above the first card, below the navigation bar.
    var topPadding: CGFloat = FlowSpacing.lg {
        didSet { setNeedsLayout() }
    }

    /// The background views, keyed by section, so a reload can repaint them in the current palette.
    private var cardViews: [Int: UIView] = [:]

    override init(frame: CGRect, style: UITableView.Style) {
        super.init(frame: frame, style: .grouped)
        commonInit()
    }

    /// The style argument is accepted for call-site symmetry but always resolves to `.grouped`,
    /// which is the only style that draws section headers the way this table does.
    convenience init(insetGroupedStyle: Bool) {
        _ = insetGroupedStyle
        self.init(frame: .zero, style: .grouped)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        separatorStyle = .singleLine
        separatorInset = UIEdgeInsets(top: 0, left: cardInset + FlowSpacing.xl, bottom: 0, right: cardInset)
        tableFooterView = UIView(frame: .zero)
        estimatedRowHeight = FlowSpacing.listItemHeight
        rowHeight = UITableView.automaticDimension
        estimatedSectionHeaderHeight = 36.0
        sectionHeaderHeight = UITableView.automaticDimension
        estimatedSectionFooterHeight = 18.0
        sectionFooterHeight = UITableView.automaticDimension
    }

    /// Repaints the cards, separators and background in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = scheme.background
        separatorColor = scheme.outlineVariant
        for card in cardViews.values {
            card.backgroundColor = scheme.surfaceContainerLow
        }
        for cell in visibleCells {
            if let themed = cell as? FlowInsetGroupedCell {
                themed.applyTheme()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateCardFrames()
    }

    override func reloadData() {
        super.reloadData()
        cardViews.removeAll()
        setNeedsLayout()
    }

    // MARK: - Section cards

    /// Positions each section's card behind its rows. A section with no rows gets no card.
    private func updateCardFrames() {
        let scheme = FlowTheme.shared.scheme
        var live: Set<Int> = []
        for section in 0..<numberOfSections {
            let rows = numberOfRows(inSection: section)
            guard rows > 0 else { continue }
            live.insert(section)
            let card: UIView
            if let existing = cardViews[section] {
                card = existing
            } else {
                card = UIView()
                card.layer.cornerRadius = cardCornerRadius
                card.layer.masksToBounds = true
                card.backgroundColor = scheme.surfaceContainerLow
                card.isUserInteractionEnabled = false
                insertSubview(card, at: 0)
                cardViews[section] = card
            }
            card.layer.cornerRadius = cardCornerRadius
            card.backgroundColor = scheme.surfaceContainerLow

            let first = rectForRow(at: IndexPath(row: 0, section: section))
            let last = rectForRow(at: IndexPath(row: rows - 1, section: section))
            let top = first.minY
            let bottom = last.maxY
            card.frame = CGRect(
                x: cardInset,
                y: top,
                width: max(bounds.width - cardInset * 2.0, 0.0),
                height: max(bottom - top, 0.0)
            )
            sendSubviewToBack(card)
        }
        for (section, card) in cardViews where !live.contains(section) {
            card.removeFromSuperview()
            cardViews.removeValue(forKey: section)
        }
    }
}

/// A cell that draws its own rounded, inset background and repaints on a theme change. Settings,
/// Library and the About screen use it for their rows.
final class FlowInsetGroupedCell: UITableViewCell {

    /// An optional glyph shown before the title.
    private let iconView = FlowIconView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let valueLabel = UILabel()
    private var iconWidth: NSLayoutConstraint?
    private var iconLeading: NSLayoutConstraint?

    /// The icon drawn at the leading edge, when the row has one.
    var icon: FlowIcon? {
        didSet { updateIcon() }
    }

    /// The row's primary text.
    var title: String? {
        get { titleLabel.text }
        set {
            titleLabel.text = newValue
            accessibilityLabel = newValue
        }
    }

    /// A second line under the title.
    var subtitle: String? {
        get { detailLabel.text }
        set {
            detailLabel.text = newValue
            detailLabel.isHidden = (newValue ?? "").isEmpty
        }
    }

    /// A trailing value, such as the current setting.
    var value: String? {
        get { valueLabel.text }
        set {
            valueLabel.text = newValue
            valueLabel.isHidden = (newValue ?? "").isEmpty
        }
    }

    /// The tint of the title. Destructive rows use the error role.
    var titleColor: UIColor? {
        didSet { titleLabel.textColor = titleColor ?? FlowTheme.shared.scheme.onSurface }
    }

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
        contentView.backgroundColor = .clear
        selectionStyle = .default
        let selected = UIView()
        selected.backgroundColor = FlowTheme.shared.scheme.surfaceContainerHigh
        selectedBackgroundView = selected

        iconView.iconSize = 22.0
        iconView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconView)
        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 0.0)
        iconWidth?.isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 22.0).isActive = true
        iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor).isActive = true
        iconLeading = iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xl)
        iconLeading?.isActive = true

        titleLabel.font = FlowTypography.bodyLarge
        titleLabel.numberOfLines = 2
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 2
        detailLabel.isHidden = true
        valueLabel.font = FlowTypography.bodyMedium
        valueLabel.textAlignment = .right
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = FlowSpacing.xxs
        textStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textStack)
        contentView.addSubviewForAutoLayout(valueLabel)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: FlowSpacing.lg),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: FlowSpacing.md),
            valueLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.xl),
            valueLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52.0),
        ])
        applyTheme()
    }

    /// Sets the row's icon, title, subtitle and trailing value in one call.
    func configure(icon: FlowIcon?, title: String, subtitle: String? = nil, value: String? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.value = value
    }

    private func updateIcon() {
        if let glyph = icon {
            iconView.icon = glyph
            iconView.isHidden = false
            iconWidth?.constant = 22.0
            iconLeading?.constant = FlowSpacing.xl
        } else {
            iconView.icon = nil
            iconView.isHidden = true
            iconWidth?.constant = 0.0
            iconLeading?.constant = FlowSpacing.xl
        }
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = titleColor ?? scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        valueLabel.textColor = scheme.onSurfaceVariant
        iconView.iconColor = scheme.onSurfaceVariant
        (selectedBackgroundView ?? UIView()).backgroundColor = scheme.surfaceContainerHigh
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        icon = nil
        title = nil
        subtitle = nil
        value = nil
        titleColor = nil
        accessoryType = .none
    }
}

/// A section header for `FlowInsetGroupedTable`: an uppercase caption inset to the card's edge.
final class FlowInsetGroupedHeader: UITableViewHeaderFooterView {

    static let reuseIdentifier = "FlowInsetGroupedHeader"

    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        let background = UIView()
        background.backgroundColor = .clear
        backgroundView = background
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FlowTypography.labelMedium
        label.numberOfLines = 2
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin + FlowSpacing.xl),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin - FlowSpacing.xl),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.sm),
        ])
        applyTheme()
    }

    /// Sets the header text.
    func configure(title: String) {
        label.text = title.uppercased()
        accessibilityLabel = title
    }

    /// Repaints the header in the current palette.
    func applyTheme() {
        label.textColor = FlowTheme.shared.scheme.onSurfaceVariant
    }
}

import UIKit

/// A Material 3 filter chip: a pill with a label and optional leading icon, which can be selected.
/// Home's category row and Search's filter row are built from these.
final class FlowChip: UIControl {

    private let titleLabel = UILabel()
    private let iconView = FlowIconView()
    private let stack = UIStackView()

    private(set) var isSelectedState = false
    private var icon: FlowIcon?

    /// Called when the chip is tapped.
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
        layer.masksToBounds = true

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = FlowSpacing.sm
        stack.isUserInteractionEnabled = false
        addSubviewForAutoLayout(stack)

        iconView.isHidden = true
        iconView.iconSize = 16.0
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 16.0).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 16.0).isActive = true

        titleLabel.font = FlowTypography.labelLarge
        titleLabel.numberOfLines = 1

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.lg),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.lg),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32.0),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        accessibilityTraits = .button
        applyTheme()
    }

    /// Creates a chip with a title.
    static func make(_ title: String, selected: Bool = false, icon: FlowIcon? = nil) -> FlowChip {
        let chip = FlowChip()
        chip.configure(title: title, selected: selected, icon: icon)
        return chip
    }

    /// Sets the chip's title, selection and optional icon.
    func configure(title: String, selected: Bool, icon: FlowIcon? = nil) {
        titleLabel.text = title
        isSelectedState = selected
        self.icon = icon
        if let glyph = icon {
            iconView.isHidden = false
            iconView.icon = glyph
        } else {
            iconView.isHidden = true
        }
        accessibilityLabel = title
        updateSelectionTraits()
        applyTheme()
    }

    /// Changes the selection without animation.
    func setSelected(_ selected: Bool, animated: Bool = true) {
        guard selected != isSelectedState else { return }
        isSelectedState = selected
        updateSelectionTraits()
        if animated {
            FlowMotion.animate { self.applyTheme() }
        } else {
            applyTheme()
        }
    }

    private func updateSelectionTraits() {
        accessibilityTraits = isSelectedState ? [.button, .selected] : .button
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2.0
    }

    /// Repaints the chip in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        if isSelectedState {
            backgroundColor = scheme.secondaryContainer
            titleLabel.textColor = scheme.onSecondaryContainer
            iconView.iconColor = scheme.onSecondaryContainer
            layer.borderWidth = 0.0
        } else {
            backgroundColor = .clear
            titleLabel.textColor = scheme.onSurfaceVariant
            iconView.iconColor = scheme.onSurfaceVariant
            layer.borderWidth = 1.0
            layer.borderColor = scheme.outline.cgColor
        }
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.7 : 1.0
        }
    }

    @objc private func handleTap() {
        onTap?()
    }
}

/// A horizontal, single-line row of chips that scrolls when it overflows. Used for Home's
/// categories and Search's filters.
final class FlowChipRow: UIView {

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private(set) var chips: [FlowChip] = []

    /// Called with the index of the chip the viewer chose.
    var onSelect: ((Int) -> Void)?

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
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        addSubviewForAutoLayout(scrollView)

        stack.axis = .horizontal
        stack.spacing = FlowSpacing.md
        stack.alignment = .center
        scrollView.addSubviewForAutoLayout(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 40.0),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: FlowSpacing.screenMargin),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    /// Replaces the row's chips. The first selected index wins.
    func setTitles(_ titles: [String], selectedIndex: Int = 0) {
        for chip in chips {
            stack.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        chips = []
        for (index, title) in titles.enumerated() {
            let chip = FlowChip.make(title, selected: index == selectedIndex)
            chip.onTap = { [weak self] in
                self?.select(index: index)
            }
            chips.append(chip)
            stack.addArrangedSubview(chip)
        }
    }

    /// Selects one chip and notifies the owner.
    func select(index: Int) {
        guard index >= 0, index < chips.count else { return }
        for (position, chip) in chips.enumerated() {
            chip.setSelected(position == index)
        }
        onSelect?(index)
    }

    /// Repaints every chip.
    func applyTheme() {
        for chip in chips {
            chip.applyTheme()
        }
    }
}

/// A small, non-interactive pill used for a badge on a row — "4K", "CC", "New", "Live".
final class FlowBadge: UIView {

    private let label = UILabel()

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
        layer.masksToBounds = true
        label.font = FlowTypography.labelSmall
        label.numberOfLines = 1
        addSubviewForAutoLayout(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.sm),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.sm),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1.0),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1.0),
        ])
        applyTheme()
    }

    /// Creates a badge with text.
    static func make(_ text: String) -> FlowBadge {
        let badge = FlowBadge()
        badge.label.text = text
        return badge
    }

    /// Sets the badge's text. An empty string hides it.
    func setText(_ text: String) {
        label.text = text
        isHidden = text.isEmpty
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2.0
    }

    /// Repaints the badge in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = scheme.surfaceContainerHighest
        label.textColor = scheme.onSurfaceVariant
    }
}

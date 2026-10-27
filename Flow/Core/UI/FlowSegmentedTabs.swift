import UIKit

/// Material 3's primary tabs: a row of labels with a sliding indicator underneath, scrollable when
/// the labels overflow. The channel screen's tabs and the library's sections use this.
final class FlowSegmentedTabs: UIView {

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let indicator = UIView()
    private var buttons: [UIButton] = []
    private var indicatorLeading: NSLayoutConstraint?
    private var indicatorWidth: NSLayoutConstraint?

    private(set) var selectedIndex = 0
    private var titles: [String] = []

    /// Called when the viewer picks a tab.
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
        stack.spacing = 0.0
        stack.alignment = .fill
        stack.distribution = .fill
        scrollView.addSubviewForAutoLayout(stack)

        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.layer.cornerRadius = 1.5
        indicator.layer.masksToBounds = true
        scrollView.addSubview(indicator)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 48.0),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.heightAnchor.constraint(equalToConstant: 46.0),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.widthAnchor),
        ])

        indicatorLeading = indicator.leadingAnchor.constraint(equalTo: stack.leadingAnchor)
        indicatorLeading?.isActive = true
        indicatorWidth = indicator.widthAnchor.constraint(equalToConstant: 0.0)
        indicatorWidth?.isActive = true
        NSLayoutConstraint.activate([
            indicator.bottomAnchor.constraint(equalTo: bottomAnchor),
            indicator.heightAnchor.constraint(equalToConstant: 3.0),
        ])
        applyTheme()
    }

    /// Sets the tab titles and the initial selection.
    func setTitles(_ titles: [String], selectedIndex: Int = 0) {
        self.titles = titles
        for button in buttons {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons = []
        for (index, title) in titles.enumerated() {
            let button = UIButton(type: .custom)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = FlowTypography.titleSmall
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: FlowSpacing.xl, bottom: 0, right: FlowSpacing.xl)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.addClosureAction(for: .touchUpInside) { [weak self] in
                self?.select(index: index, notify: true)
            }
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        self.selectedIndex = min(max(selectedIndex, 0), max(titles.count - 1, 0))
        applyTheme()
        setNeedsLayout()
        layoutIfNeeded()
        updateIndicator(animated: false)
    }

    /// Selects a tab. `notify` runs the owner's callback.
    func select(index: Int, notify: Bool) {
        guard index >= 0, index < buttons.count else { return }
        selectedIndex = index
        applyTheme()
        updateIndicator(animated: true)
        if notify {
            onSelect?(index)
        }
    }

    /// The width of the selected tab, used to size the indicator.
    private func updateIndicator(animated: Bool) {
        guard selectedIndex < buttons.count else {
            indicatorWidth?.constant = 0.0
            return
        }
        let button = buttons[selectedIndex]
        let width = max(button.bounds.width, 24.0)
        let leading = button.convert(CGPoint.zero, to: stack).x
        indicatorWidth?.constant = width
        indicatorLeading?.constant = leading
        let target = scrollView.convert(button.frame, from: stack).insetBy(dx: -FlowSpacing.xl, dy: 0)
        if animated {
            FlowMotion.animate {
                self.layoutIfNeeded()
            }
        } else {
            layoutIfNeeded()
        }
        scrollView.scrollRectToVisible(target, animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateIndicator(animated: false)
    }

    /// Repaints the tabs in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        indicator.backgroundColor = scheme.primary
        for (index, button) in buttons.enumerated() {
            let active = index == selectedIndex
            button.setTitleColor(active ? scheme.primary : scheme.onSurfaceVariant, for: .normal)
            button.titleLabel?.font = active ? FlowTypography.titleSmallEmphasized : FlowTypography.titleSmall
        }
    }
}

/// A two-state segmented control, drawn as a pill with a sliding thumb. Used for the search
/// results' grid/list toggle and the settings' on/off rows that read better as two choices.
final class FlowSegmentedControl: UIControl {

    private let container = UIView()
    private let thumb = UIView()
    private let row = UIStackView()
    private var buttons: [UIButton] = []
    private var thumbLeading: NSLayoutConstraint?
    private var thumbWidth: NSLayoutConstraint?

    private(set) var selectedIndex = 0
    private var titles: [String] = []

    /// Called when the selection changes.
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
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 18.0
        container.layer.masksToBounds = true
        addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 36.0),
        ])

        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.layer.cornerRadius = 16.0
        thumb.layer.masksToBounds = true
        container.addSubview(thumb)
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: container.topAnchor, constant: 2.0),
            thumb.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2.0),
        ])
        thumbLeading = thumb.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2.0)
        thumbLeading?.isActive = true
        thumbWidth = thumb.widthAnchor.constraint(equalToConstant: 0.0)
        thumbWidth?.isActive = true

        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.distribution = .fillEqually
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2.0),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2.0),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 2.0),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2.0),
        ])
        applyTheme()
    }

    /// Sets the segment titles and the initial selection.
    func setTitles(_ titles: [String], selectedIndex: Int = 0) {
        self.titles = titles
        for button in buttons {
            row.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons = []
        for (index, title) in titles.enumerated() {
            let button = UIButton(type: .custom)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = FlowTypography.labelLarge
            button.addClosureAction(for: .touchUpInside) { [weak self] in
                self?.select(index: index)
            }
            buttons.append(button)
            row.addArrangedSubview(button)
        }
        self.selectedIndex = min(max(selectedIndex, 0), max(titles.count - 1, 0))
        container.bringSubviewToFront(thumb)
        applyTheme()
        setNeedsLayout()
    }

    /// Selects a segment and notifies the owner.
    func select(index: Int) {
        guard index >= 0, index < buttons.count, index != selectedIndex else { return }
        selectedIndex = index
        applyTheme()
        updateThumb(animated: true)
        onSelect?(index)
    }

    private func updateThumb(animated: Bool) {
        guard selectedIndex < buttons.count else { return }
        let width = (container.bounds.width - 4.0) / CGFloat(max(buttons.count, 1))
        thumbWidth?.constant = width
        thumbLeading?.constant = 2.0 + width * CGFloat(selectedIndex)
        if animated {
            FlowMotion.animate {
                self.container.layoutIfNeeded()
            }
        } else {
            container.layoutIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateThumb(animated: false)
    }

    /// Repaints the control in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        container.backgroundColor = scheme.surfaceContainerHighest
        thumb.backgroundColor = scheme.surface
        for (index, button) in buttons.enumerated() {
            let active = index == selectedIndex
            button.setTitleColor(active ? scheme.onSurface : scheme.onSurfaceVariant, for: .normal)
            button.titleLabel?.font = active ? FlowTypography.labelLargeEmphasized : FlowTypography.labelLarge
        }
    }
}

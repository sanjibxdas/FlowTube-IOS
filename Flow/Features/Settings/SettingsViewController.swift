import UIKit

// MARK: - Row model

/// One row in a settings list.
///
/// A screen describes its list as plain values and rebuilds it whenever something changes, rather
/// than mutating cells in place. That keeps the table's data source and what the viewer sees in
/// step, and it means a palette switch only has to call `rebuild()`.
enum SettingsRow {
    /// A row that pushes a screen or runs an action. A chevron marks the ones that navigate.
    case navigation(
        icon: FlowIcon?,
        title: String,
        subtitle: String?,
        value: String?,
        isDestructive: Bool,
        showsChevron: Bool,
        action: () -> Void
    )
    /// A row with a switch.
    case toggle(
        icon: FlowIcon?,
        title: String,
        subtitle: String?,
        isOn: Bool,
        isEnabled: Bool,
        onChange: (Bool) -> Void
    )
    /// A row with a continuous slider.
    case slider(
        title: String,
        valueText: String,
        value: Float,
        minimum: Float,
        maximum: Float,
        onChange: (Float) -> Void,
        onCommit: (Float) -> Void
    )
    /// A read-only row: a value the viewer cannot change here.
    case detail(icon: FlowIcon?, title: String, subtitle: String?, value: String?)
    /// A row a screen draws itself, for previews, swatches and segmented controls.
    case custom(configure: (SettingsCustomCell) -> Void, action: (() -> Void)?)
}

extension SettingsRow {
    /// A row that opens another screen.
    static func nav(
        _ title: String,
        icon: FlowIcon? = nil,
        subtitle: String? = nil,
        value: String? = nil,
        showsChevron: Bool = true,
        action: @escaping () -> Void
    ) -> SettingsRow {
        return .navigation(
            icon: icon,
            title: title,
            subtitle: subtitle,
            value: value,
            isDestructive: false,
            showsChevron: showsChevron,
            action: action
        )
    }

    /// A row that destroys something. The title is tinted with the error role.
    static func destructive(
        _ title: String,
        icon: FlowIcon? = nil,
        subtitle: String? = nil,
        value: String? = nil,
        action: @escaping () -> Void
    ) -> SettingsRow {
        return .navigation(
            icon: icon,
            title: title,
            subtitle: subtitle,
            value: value,
            isDestructive: true,
            showsChevron: false,
            action: action
        )
    }

    /// A switch row that is always available.
    static func toggle(
        _ title: String,
        icon: FlowIcon? = nil,
        subtitle: String? = nil,
        isOn: Bool,
        onChange: @escaping (Bool) -> Void
    ) -> SettingsRow {
        return .toggle(
            icon: icon,
            title: title,
            subtitle: subtitle,
            isOn: isOn,
            isEnabled: true,
            onChange: onChange
        )
    }
}

/// A titled group of rows, drawn as one card by `FlowInsetGroupedTable`.
struct SettingsSection {
    var header: String?
    var footer: String?
    var rows: [SettingsRow]

    init(header: String? = nil, footer: String? = nil, rows: [SettingsRow]) {
        self.header = header
        self.footer = footer
        self.rows = rows
    }
}

// MARK: - Base screen

/// The base for every settings screen.
///
/// It owns the inset-grouped table, the cell types the rows map to, the section headers and
/// footers, and the theme subscription. A subclass only has to override `sections`; everything
/// else — including repainting when the palette changes — is handled here.
class SettingsListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    /// The table the list is drawn in. Exposed so a subclass can scroll it or add a refresh control.
    let table = FlowInsetGroupedTable(insetGroupedStyle: true)

    /// The theme subscription, cancelled when the screen goes away.
    private var themeToken: ObservationToken?

    /// The list to show. Subclasses build it from current state each time it is asked for.
    var sections: [SettingsSection] {
        return []
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background

        table.dataSource = self
        table.delegate = self
        table.register(SettingsSwitchCell.self, forCellReuseIdentifier: SettingsSwitchCell.reuseIdentifier)
        table.register(SettingsSliderCell.self, forCellReuseIdentifier: SettingsSliderCell.reuseIdentifier)
        table.register(FlowInsetGroupedCell.self, forCellReuseIdentifier: SettingsListViewController.navigationCellIdentifier)
        table.register(
            FlowInsetGroupedHeader.self,
            forHeaderFooterViewReuseIdentifier: FlowInsetGroupedHeader.reuseIdentifier
        )
        table.register(
            SettingsFooterLabel.self,
            forHeaderFooterViewReuseIdentifier: SettingsFooterLabel.reuseIdentifier
        )

        view.addSubviewForAutoLayout(table)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
    }

    deinit {
        themeToken?.cancelObservation()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A child screen may have changed a preference, so the values shown here are re-read.
        rebuild()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Updating

    /// Reloads the list from `sections`.
    func rebuild() {
        table.reloadData()
    }

    /// Repaints the screen in the current palette. Reloading is deliberate: every row reads its
    /// colours from the theme when it is built, so a reload is the one path that cannot miss a view.
    func applyTheme() {
        view.backgroundColor = FlowTheme.shared.background
        table.applyTheme()
        table.reloadData()
        applyCustomTheme()
    }

    /// A hook for subclasses that draw their own preview views.
    func applyCustomTheme() {}

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let row = row(at: indexPath) else { return UITableViewCell() }
        switch row {
        case .navigation(let icon, let title, let subtitle, let value, let isDestructive, let showsChevron, _):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsListViewController.navigationCellIdentifier,
                for: indexPath
            )
            guard let themed = cell as? FlowInsetGroupedCell else { return cell }
            themed.configure(icon: icon, title: title, subtitle: subtitle, value: value)
            themed.titleColor = isDestructive ? FlowTheme.shared.scheme.error : nil
            themed.accessoryType = showsChevron ? .disclosureIndicator : .none
            themed.selectionStyle = showsChevron ? .default : .none
            themed.applyTheme()
            return themed

        case .toggle(let icon, let title, let subtitle, let isOn, let isEnabled, let onChange):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsSwitchCell.reuseIdentifier,
                for: indexPath
            )
            guard let toggleCell = cell as? SettingsSwitchCell else { return cell }
            toggleCell.configure(
                icon: icon,
                title: title,
                subtitle: subtitle,
                isOn: isOn,
                isEnabled: isEnabled,
                onChange: onChange
            )
            return toggleCell

        case .slider(let title, let valueText, let value, let minimum, let maximum, let onChange, let onCommit):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsSliderCell.reuseIdentifier,
                for: indexPath
            )
            guard let sliderCell = cell as? SettingsSliderCell else { return cell }
            sliderCell.configure(
                title: title,
                valueText: valueText,
                value: value,
                minimum: minimum,
                maximum: maximum,
                onChange: onChange,
                onCommit: onCommit
            )
            return sliderCell

        case .detail(let icon, let title, let subtitle, let value):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsListViewController.navigationCellIdentifier,
                for: indexPath
            )
            guard let themed = cell as? FlowInsetGroupedCell else { return cell }
            themed.configure(icon: icon, title: title, subtitle: subtitle, value: value)
            themed.titleColor = nil
            themed.accessoryType = .none
            themed.selectionStyle = .none
            themed.applyTheme()
            return themed

        case .custom(let configure, _):
            // Custom rows are built fresh: their content differs per row and per theme, and there
            // are few enough of them that reuse would only add state to reset.
            let cell = SettingsCustomCell(style: .default, reuseIdentifier: nil)
            configure(cell)
            cell.applyTheme()
            return cell
        }
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = row(at: indexPath) else { return }
        switch row {
        case .navigation(_, _, _, _, _, _, let action):
            action()
        case .custom(_, let action):
            action?()
        case .toggle, .slider, .detail:
            break
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let title = sections[section].header, !title.isEmpty else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: FlowInsetGroupedHeader.reuseIdentifier
        ) as? FlowInsetGroupedHeader ?? FlowInsetGroupedHeader(reuseIdentifier: FlowInsetGroupedHeader.reuseIdentifier)
        header.configure(title: title)
        header.applyTheme()
        return header
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard let text = sections[section].footer, !text.isEmpty else { return nil }
        let footer = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: SettingsFooterLabel.reuseIdentifier
        ) as? SettingsFooterLabel ?? SettingsFooterLabel(reuseIdentifier: SettingsFooterLabel.reuseIdentifier)
        footer.configure(text: text)
        footer.applyTheme()
        return footer
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard let title = sections[section].header, !title.isEmpty else { return 0.0 }
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        guard let text = sections[section].footer, !text.isEmpty else { return 0.0 }
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, estimatedHeightForFooterInSection section: Int) -> CGFloat {
        return 44.0
    }

    // MARK: - Helpers

    private static let navigationCellIdentifier = "SettingsNavigationCell"

    /// The row at an index path, or nil when the list changed under the table.
    func row(at indexPath: IndexPath) -> SettingsRow? {
        let all = sections
        guard indexPath.section >= 0, indexPath.section < all.count else { return nil }
        let rows = all[indexPath.section].rows
        guard indexPath.row >= 0, indexPath.row < rows.count else { return nil }
        return rows[indexPath.row]
    }

    /// Pushes a settings screen onto this screen's navigation stack.
    func pushSettings(_ controller: UIViewController) {
        if let navigation = navigationController {
            navigation.pushViewController(controller, animated: true)
        } else {
            let navigation = UINavigationController(rootViewController: controller)
            navigation.modalPresentationStyle = .fullScreen
            present(navigation, animated: true, completion: nil)
        }
    }
}

// MARK: - Switch row

/// A settings row with a switch on the trailing edge.
///
/// `UISwitch` is used rather than a custom control: it is the platform's switch, it is what people
/// expect in a settings list, and it brings the correct accessibility behaviour for free. Its
/// on-tint is set to the palette's primary so it still reads as part of the theme.
final class SettingsSwitchCell: UITableViewCell {

    static let reuseIdentifier = "SettingsSwitchCell"

    private let iconView = FlowIconView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let toggle = UISwitch()
    private var iconWidth: NSLayoutConstraint?
    private var onChange: ((Bool) -> Void)?
    /// Whether the row can be toggled. `UITableViewCell` is not a `UIControl`, so the row carries
    /// its own enabled flag and mirrors it onto the switch and the labels.
    var isEnabled: Bool = true {
        didSet { applyEnabledState() }
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
        selectionStyle = .none

        iconView.iconSize = 22.0
        iconView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconView)
        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 0.0)
        iconWidth?.isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 22.0).isActive = true
        iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor).isActive = true
        iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xl).isActive = true

        titleLabel.font = FlowTypography.bodyLarge
        titleLabel.numberOfLines = 2
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 3
        detailLabel.isHidden = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = FlowSpacing.xxs
        textStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textStack)

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(handleToggle), for: .valueChanged)
        contentView.addSubview(toggle)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: FlowSpacing.lg),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),

            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: FlowSpacing.md),
            toggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.xl),
            toggle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52.0),
        ])
        applyTheme()
    }

    /// Sets every part of the row.
    func configure(
        icon: FlowIcon?,
        title: String,
        subtitle: String?,
        isOn: Bool,
        isEnabled: Bool,
        onChange: @escaping (Bool) -> Void
    ) {
        self.onChange = onChange
        titleLabel.text = title
        detailLabel.text = subtitle
        detailLabel.isHidden = (subtitle ?? "").isEmpty
        toggle.isOn = isOn
        toggle.isEnabled = isEnabled
        self.isEnabled = isEnabled
        accessibilityLabel = title
        accessibilityValue = isOn ? "On" : "Off"

        if let glyph = icon {
            iconView.icon = glyph
            iconView.isHidden = false
            iconWidth?.constant = 22.0
        } else {
            iconView.icon = nil
            iconView.isHidden = true
            iconWidth?.constant = 0.0
        }
        applyTheme()
    }

    @objc private func handleToggle() {
        accessibilityValue = toggle.isOn ? "On" : "Off"
        onChange?(toggle.isOn)
    }

    /// Repaints the row in the current palette.
    private func applyEnabledState() {
        toggle.isEnabled = isEnabled
        toggle.alpha = isEnabled ? 1.0 : 0.4
        titleLabel.alpha = isEnabled ? 1.0 : 0.5
        detailLabel.alpha = isEnabled ? 1.0 : 0.5
        iconView.alpha = isEnabled ? 1.0 : 0.5
        accessibilityTraits = isEnabled ? [] : .notEnabled
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = isEnabled ? scheme.onSurface : scheme.onSurfaceVariant
        detailLabel.textColor = scheme.onSurfaceVariant
        iconView.iconColor = scheme.onSurfaceVariant
        toggle.onTintColor = scheme.primary
        toggle.tintColor = scheme.outline
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
        iconView.icon = nil
        titleLabel.text = nil
        detailLabel.text = nil
        detailLabel.isHidden = true
        toggle.isOn = false
        toggle.isEnabled = true
        isEnabled = true
        accessibilityLabel = nil
        accessibilityValue = nil
    }
}

// MARK: - Slider row

/// A settings row whose value is a continuous range: caption size, background opacity, speed.
///
/// The slider reports every movement through `onChange` so a preview can follow the thumb, and the
/// final value through `onCommit` so the preference is written once, not on every pixel.
final class SettingsSliderCell: UITableViewCell {

    static let reuseIdentifier = "SettingsSliderCell"

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    private var onChange: ((Float) -> Void)?
    private var onCommit: ((Float) -> Void)?

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
        selectionStyle = .none

        titleLabel.font = FlowTypography.bodyLarge
        titleLabel.numberOfLines = 2
        valueLabel.font = FlowTypography.bodyMedium
        valueLabel.textAlignment = .right
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        header.axis = .horizontal
        header.spacing = FlowSpacing.md
        header.alignment = .firstBaseline
        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(handleChange), for: .valueChanged)
        slider.addTarget(self, action: #selector(handleCommit), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        contentView.addSubview(slider)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xl),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.xl),
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),

            slider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xl),
            slider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.xl),
            slider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: FlowSpacing.sm),
            slider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.md),
        ])
        applyTheme()
    }

    /// Sets the row's label, value text and range.
    func configure(
        title: String,
        valueText: String,
        value: Float,
        minimum: Float,
        maximum: Float,
        onChange: @escaping (Float) -> Void,
        onCommit: @escaping (Float) -> Void
    ) {
        self.onChange = onChange
        self.onCommit = onCommit
        titleLabel.text = title
        valueLabel.text = valueText
        slider.minimumValue = minimum
        slider.maximumValue = maximum
        slider.value = min(max(value, minimum), maximum)
        accessibilityLabel = title
        accessibilityValue = valueText
        applyTheme()
    }

    @objc private func handleChange() {
        onChange?(slider.value)
    }

    @objc private func handleCommit() {
        onCommit?(slider.value)
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        valueLabel.textColor = scheme.onSurfaceVariant
        slider.minimumTrackTintColor = scheme.primary
        slider.maximumTrackTintColor = scheme.outlineVariant
        slider.thumbTintColor = scheme.primary
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
        onCommit = nil
        titleLabel.text = nil
        valueLabel.text = nil
    }
}

// MARK: - Custom row

/// A row whose content the owning screen builds. Used for theme swatches, previews and the
/// segmented style picker, where the row is a small piece of UI rather than a title and a value.
final class SettingsCustomCell: UITableViewCell {

    /// The vertical stack a screen adds its views to.
    let contentStack = UIStackView()

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
        selectionStyle = .none

        contentStack.axis = .vertical
        contentStack.spacing = FlowSpacing.lg
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xl),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.xl),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),
        ])
    }

    /// Repaints the row's background. The views a screen added repaint themselves.
    func applyTheme() {
        contentView.backgroundColor = .clear
    }
}

// MARK: - Footer

/// The explanation under a settings card. Material 3 puts this text below the group, in the
/// on-surface-variant role and the body-small size.
final class SettingsFooterLabel: UITableViewHeaderFooterView {

    static let reuseIdentifier = "SettingsFooterLabel"

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

        label.font = FlowTypography.bodySmall
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: FlowSpacing.screenMargin + FlowSpacing.xl
            ),
            label.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -FlowSpacing.screenMargin - FlowSpacing.xl
            ),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.sm),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),
        ])
        applyTheme()
    }

    /// Sets the footer's text.
    func configure(text: String) {
        label.text = text
        accessibilityLabel = text
    }

    /// Repaints the footer in the current palette.
    func applyTheme() {
        label.textColor = FlowTheme.shared.scheme.onSurfaceVariant
    }
}

// MARK: - Root screen

/// The settings tree: Appearance, Playback, Downloads, SponsorBlock, Subtitles, Privacy, Storage,
/// About and Recommendations.
///
/// Each area is a card with a row that opens its own screen plus the one or two switches worth
/// reaching without a second tap — the same shape as the Android settings list, where a group's
/// page row sits above its most-used toggles. Every value shown on this screen is read from the
/// store when the list is built, so returning from a child screen always shows the new value.
final class SettingsViewController: SettingsListViewController {

    private let prefs = FlowApp.shared.prefs

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        table.topPadding = FlowSpacing.lg
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    // MARK: - Sections

    override var sections: [SettingsSection] {
        return [
            appearanceSection(),
            playbackSection(),
            downloadsSection(),
            sponsorBlockSection(),
            subtitlesSection(),
            privacySection(),
            storageSection(),
            aboutSection(),
            recommendationsSection(),
        ]
    }

    private func appearanceSection() -> SettingsSection {
        let theme = FlowTheme.shared
        let themeName = theme.mode.displayName
        let styleName = theme.variant.displayName
        let fontName = theme.fontChoice.displayName
        return SettingsSection(
            header: "Appearance",
            footer: "Personalize your Flow experience",
            rows: [
                .nav(
                    "Theme",
                    icon: .moon,
                    subtitle: "\(themeName) · \(styleName)",
                    value: fontName,
                    action: { [weak self] in
                        self?.pushSettings(AppearanceSettingsViewController())
                    }
                ),
            ]
        )
    }

    private func playbackSection() -> SettingsSection {
        let quality = PlaybackSettingsViewController.qualityLabel(for: prefs.string(for: .playbackQuality) ?? "auto")
        let speed = Formatters.playbackSpeed(prefs.playbackSpeed)
        return SettingsSection(
            header: "Playback",
            footer: "Autoplay, gestures, captions and player buttons",
            rows: [
                .nav(
                    "Player Settings",
                    icon: .play,
                    subtitle: "Autoplay, Background Play, SponsorBlock",
                    value: "\(quality) · \(speed)",
                    action: { [weak self] in
                        self?.pushSettings(PlaybackSettingsViewController())
                    }
                ),
                .toggle(
                    "Background Play",
                    icon: .volume,
                    subtitle: "Continue playing when app is in background",
                    isOn: prefs.bool(for: .backgroundPlayback, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .backgroundPlayback)
                    }
                ),
                .toggle(
                    "Picture-in-Picture",
                    icon: .pip,
                    subtitle: "Keep the video in a floating window when you leave",
                    isOn: prefs.bool(for: .pictureInPicture, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .pictureInPicture)
                    }
                ),
            ]
        )
    }

    private func downloadsSection() -> SettingsSection {
        let used = Formatters.fileSize(FlowApp.shared.downloadStore.storageUsed())
        let quality = DownloadSettingsViewController.qualityLabel(for: prefs.string(for: .downloadQuality) ?? "720p")
        return SettingsSection(
            header: "Downloads",
            footer: "Download locations, defaults and media cache",
            rows: [
                .nav(
                    "Download Settings",
                    icon: .download,
                    subtitle: "Performance, Storage, Threads",
                    value: quality,
                    action: { [weak self] in
                        self?.pushSettings(DownloadSettingsViewController())
                    }
                ),
                .nav(
                    "Storage used",
                    icon: .downloaded,
                    subtitle: "Downloads on this device",
                    value: used,
                    showsChevron: false,
                    action: { [weak self] in
                        self?.pushSettings(StorageSettingsViewController())
                    }
                ),
                .toggle(
                    "Download over Wi-Fi only",
                    icon: .wifi,
                    subtitle: "Wait for Wi-Fi before downloading",
                    isOn: prefs.bool(for: .downloadWifiOnly, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .downloadWifiOnly)
                    }
                ),
            ]
        )
    }

    private func sponsorBlockSection() -> SettingsSection {
        let enabled = prefs.bool(for: .sponsorBlockEnabled, fallback: true)
        let count = prefs.sponsorBlockCategories.count
        return SettingsSection(
            header: "SponsorBlock",
            footer: "Skip sponsored segments, intros, outros and more",
            rows: [
                .nav(
                    "SponsorBlock, DeArrow & RYD",
                    icon: .filter,
                    subtitle: "Segment actions, DeArrow controls, and dislike count settings",
                    value: "\(count) categories",
                    action: { [weak self] in
                        self?.pushSettings(SponsorBlockSettingsViewController())
                    }
                ),
                .toggle(
                    "SponsorBlock",
                    icon: .filter,
                    subtitle: "Skip sponsored segments",
                    isOn: enabled,
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .sponsorBlockEnabled)
                    }
                ),
                .toggle(
                    "Auto-skip segments",
                    icon: .next,
                    subtitle: "Skip the moment playback reaches a segment",
                    isOn: prefs.bool(for: .sponsorBlockAutoSkip, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .sponsorBlockAutoSkip)
                    }
                ),
            ]
        )
    }

    private func subtitlesSection() -> SettingsSection {
        let style = SubtitleStyle.current
        let size = Int((style.fontScale * 100.0).rounded())
        return SettingsSection(
            header: "Subtitles",
            footer: "Captions open in your preferred language when the video has one",
            rows: [
                .nav(
                    "Subtitle Style",
                    icon: .subtitles,
                    subtitle: "Size, colour and background",
                    value: "\(size)%",
                    action: { [weak self] in
                        self?.pushSettings(SubtitleSettingsViewController())
                    }
                ),
                .toggle(
                    "Turn Captions On Automatically",
                    icon: .subtitles,
                    subtitle: "Turn on captions in your preferred language",
                    isOn: prefs.bool(for: .subtitlesEnabled, fallback: false),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .subtitlesEnabled)
                    }
                ),
            ]
        )
    }

    private func privacySection() -> SettingsSection {
        return SettingsSection(
            header: "Privacy",
            footer: "Flow has no account and sends nothing about what you watch",
            rows: [
                .nav(
                    "History & privacy",
                    icon: .clock,
                    subtitle: "Clear history, manage suggestions",
                    value: nil,
                    action: { [weak self] in
                        self?.pushSettings(PrivacySettingsViewController())
                    }
                ),
                .toggle(
                    "Pause watch history",
                    icon: .pause,
                    subtitle: "Stop saving what you watch. Deep Flow also pauses learning",
                    isOn: prefs.historyPaused,
                    onChange: { [weak self] value in
                        self?.prefs.historyPaused = value
                    }
                ),
            ]
        )
    }

    private func storageSection() -> SettingsSection {
        let downloads = Formatters.fileSize(FlowApp.shared.downloadStore.storageUsed())
        let images = Formatters.fileSize(FlowApp.shared.imageLoader.diskSize())
        return SettingsSection(
            header: "Storage",
            footer: "Clear cached images and downloaded media",
            rows: [
                .nav(
                    "Storage",
                    icon: .downloaded,
                    subtitle: "Cache size breakdown and clear actions",
                    value: "\(downloads) · \(images)",
                    action: { [weak self] in
                        self?.pushSettings(StorageSettingsViewController())
                    }
                ),
            ]
        )
    }

    private func aboutSection() -> SettingsSection {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return SettingsSection(
            header: "About",
            footer: "Version, licence and links",
            rows: [
                .nav(
                    "About Flow",
                    icon: .verified,
                    subtitle: "Version, License, Contributors",
                    value: "v\(version)",
                    action: { [weak self] in
                        self?.pushSettings(AboutViewController())
                    }
                ),
            ]
        )
    }

    private func recommendationsSection() -> SettingsSection {
        let topics = TopicStore.shared.topicCount
        return SettingsSection(
            header: "Recommendations",
            footer: "Recommendations are learned on this device from what you watch. Nothing leaves the phone.",
            rows: [
                .toggle(
                    "Show recommendations on Home",
                    icon: .home,
                    subtitle: "Personalized recommendations on the home feed",
                    isOn: prefs.bool(for: .recommendationsEnabled, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .recommendationsEnabled)
                    }
                ),
                .toggle(
                    "Search history",
                    icon: .search,
                    subtitle: "Suggest recent searches while you type",
                    isOn: prefs.bool(for: .searchHistoryEnabled, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .searchHistoryEnabled)
                    }
                ),
                .detail(
                    icon: .notes,
                    title: "Learned topics",
                    subtitle: "What the recommendation engine has picked up",
                    value: "\(topics)"
                ),
                .destructive(
                    "Reset Flow Personality",
                    icon: .trash,
                    subtitle: "Forget learned topics and start recommendations over",
                    action: { [weak self] in
                        self?.confirmResetPersonality()
                    }
                ),
            ]
        )
    }

    // MARK: - Actions

    /// Asks before erasing the learned profile, because it cannot be undone.
    private func confirmResetPersonality() {
        let alert = UIAlertController(
            title: "Reset Flow Personality?",
            message: "This erases your Flow Brain profile.\n\n• Learned topics are forgotten.\n• Personality traits reset.\n• Recommendations go back to default.\n\nThis cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Reset Everything", style: .destructive, handler: { [weak self] _ in
            TopicStore.shared.reset()
            self?.rebuild()
            FlowSnackbar.show("Recommendations reset")
        }))
        present(alert, animated: true, completion: nil)
    }
}

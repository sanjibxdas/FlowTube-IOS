import UIKit

/// The label a theme style is shown by. Kept next to the picker that uses it rather than on the
/// enum, which the player and the theme engine also read.
extension ThemeVariant {
    var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .amoled: return "AMOLED"
        }
    }
}

/// Appearance: the palette picker, the light/dark/AMOLED style, the font and the live preview.
///
/// The screen follows the Android theme picker's structure: a preview card for the current theme,
/// a style selector, the full catalogue of palettes as cards with three colour pills each, and the
/// font choice. Every choice is applied the moment it is made — there is no Save button — and the
/// screen itself repaints in the new palette, which is the point of a live preview.
final class AppearanceSettingsViewController: SettingsListViewController {

    private let prefs = FlowApp.shared.prefs
    private let theme = FlowTheme.shared

    /// The palette cards, rebuilt when the selection changes so the check mark moves.
    private var paletteCards: [ThemeMode: ThemePaletteCard] = [:]

    /// The preview card in the first section.
    private let preview = ThemePreviewCard()

    /// The style selector. Kept so the theme change can move its thumb.
    private let styleControl = FlowSegmentedControl()

    /// The font picker.
    private let fontControl = FlowSegmentedControl()

    private let fontPreview = FontPreviewCard()

    /// The palette filter: all palettes, or one family.
    private let filterRow = FlowChipRow()
    private var filter: PaletteFilter = .all

    private enum PaletteFilter: Int, CaseIterable {
        case all
        case light
        case dark
        case special

        var title: String {
            switch self {
            case .all: return "All"
            case .light: return "Light"
            case .dark: return "Dark"
            case .special: return "Special"
            }
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Appearance"
        buildControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
    }

    // MARK: - Sections

    override var sections: [SettingsSection] {
        return [
            previewSection(),
            styleSection(),
            paletteSection(),
            fontSection(),
        ]
    }

    private func previewSection() -> SettingsSection {
        return SettingsSection(
            header: "Current theme",
            footer: "Personalize your Flow experience",
            rows: [
                .custom(configure: { [weak self] cell in
                    guard let self = self else { return }
                    self.preview.removeFromSuperview()
                    cell.contentStack.addArrangedSubview(self.preview)
                    self.preview.applyTheme()
                }, action: nil),
            ]
        )
    }

    private func styleSection() -> SettingsSection {
        return SettingsSection(
            header: "Theme style",
            footer: "AMOLED paints pure black behind the palette, which saves power on an OLED screen.",
            rows: [
                .custom(configure: { [weak self] cell in
                    guard let self = self else { return }
                    self.styleControl.removeFromSuperview()
                    cell.contentStack.addArrangedSubview(self.styleControl)
                    self.styleControl.applyTheme()
                }, action: nil),
            ]
        )
    }

    private func paletteSection() -> SettingsSection {
        let modes = filteredPalettes()
        var rows: [SettingsRow] = [
            .custom(configure: { [weak self] cell in
                guard let self = self else { return }
                self.filterRow.removeFromSuperview()
                cell.contentStack.addArrangedSubview(self.filterRow)
                self.filterRow.applyTheme()
            }, action: nil),
        ]
        for mode in modes {
            rows.append(.custom(configure: { [weak self] cell in
                guard let self = self else { return }
                let card = self.card(for: mode)
                card.removeFromSuperview()
                cell.contentStack.addArrangedSubview(card)
                card.applyTheme()
            }, action: { [weak self] in
                self?.select(mode)
            }))
        }
        return SettingsSection(
            header: "Palettes",
            footer: "Material You draws its colours from the wallpaper on Android 12 and newer, so it is not available on iOS 12.",
            rows: rows
        )
    }

    private func fontSection() -> SettingsSection {
        return SettingsSection(
            header: "Font",
            footer: "The app font applies everywhere. Captions keep their own size and colour.",
            rows: [
                .custom(configure: { [weak self] cell in
                    guard let self = self else { return }
                    self.fontPreview.removeFromSuperview()
                    cell.contentStack.addArrangedSubview(self.fontPreview)
                    self.fontPreview.applyTheme()
                }, action: nil),
                .custom(configure: { [weak self] cell in
                    guard let self = self else { return }
                    self.fontControl.removeFromSuperview()
                    cell.contentStack.addArrangedSubview(self.fontControl)
                    self.fontControl.applyTheme()
                }, action: nil),
            ]
        )
    }

    // MARK: - Controls

    private func buildControls() {
        preview.onOpenCustomise = { [weak self] in
            self?.presentCustomiseNotice()
        }

        let variants = ThemeVariant.allCases
        styleControl.setTitles(variants.map { $0.displayName }, selectedIndex: index(of: theme.variant))
        styleControl.onSelect = { [weak self] index in
            guard let self = self, index >= 0, index < variants.count else { return }
            self.applyVariant(variants[index])
        }

        fontControl.setTitles(FlowFontChoice.allCases.map { $0.displayName }, selectedIndex: index(of: theme.fontChoice))
        fontControl.onSelect = { [weak self] index in
            guard let self = self, index >= 0, index < FlowFontChoice.allCases.count else { return }
            self.applyFont(FlowFontChoice.allCases[index])
        }

        filterRow.setTitles(PaletteFilter.allCases.map { $0.title }, selectedIndex: filter.rawValue)
        filterRow.onSelect = { [weak self] index in
            guard let self = self, let next = PaletteFilter(rawValue: index) else { return }
            self.filter = next
            self.rebuild()
        }
    }

    /// The card for a palette, made once and reused across reloads.
    private func card(for mode: ThemeMode) -> ThemePaletteCard {
        if let existing = paletteCards[mode] {
            existing.configure(mode: mode, isSelected: isSelected(mode), isEnabled: isEnabled(mode))
            return existing
        }
        let card = ThemePaletteCard()
        card.configure(mode: mode, isSelected: isSelected(mode), isEnabled: isEnabled(mode))
        card.onTap = { [weak self] in
            self?.select(mode)
        }
        paletteCards[mode] = card
        return card
    }

    // MARK: - Selection

    /// The palettes the current filter shows.
    private func filteredPalettes() -> [ThemeMode] {
        let all = ThemeMode.catalog
        switch filter {
        case .all:
            return all
        case .light:
            return all.filter { $0.defaultVariant == .light }
        case .dark:
            return all.filter { $0.defaultVariant == .dark }
        case .special:
            return all.filter { $0 == .materialYou || $0 == .monochrome || $0 == .yinYang }
        }
    }

    /// Whether `mode` is the palette in effect. A legacy spelling (`light`, `oled`) counts as the
    /// palette it folds into, so the check mark lands on Flow Default for either.
    private func isSelected(_ mode: ThemeMode) -> Bool {
        return theme.mode.canonicalFamily == mode.canonicalFamily
    }

    /// Material You needs the Android wallpaper service, which iOS does not expose.
    private func isEnabled(_ mode: ThemeMode) -> Bool {
        return mode != .materialYou
    }

    private func select(_ mode: ThemeMode) {
        guard isEnabled(mode) else {
            FlowSnackbar.show("Material You needs Android 12 or newer")
            return
        }
        theme.apply(mode: mode)
        theme.persist(to: prefs)
        rebuild()
        FlowSnackbar.show("Applied: " + mode.displayName)
    }

    private func applyVariant(_ variant: ThemeVariant) {
        guard variant != theme.variant else { return }
        theme.apply(mode: theme.mode, variant: variant)
        theme.persist(to: prefs)
        rebuild()
    }

    private func applyFont(_ choice: FlowFontChoice) {
        guard choice != theme.fontChoice else { return }
        theme.applyFont(choice)
        theme.persist(to: prefs)
        rebuild()
    }

    private func index(of variant: ThemeVariant) -> Int {
        return ThemeVariant.allCases.firstIndex(of: variant) ?? 0
    }

    private func index(of choice: FlowFontChoice) -> Int {
        return FlowFontChoice.allCases.firstIndex(of: choice) ?? 0
    }

    /// The custom palette editor is a separate screen in the Android app; on iOS the palette is
    /// edited in place from the preview card, and this explains where the colours come from.
    private func presentCustomiseNotice() {
        if let custom = prefs.customPalette() {
            theme.applyCustom(custom, variant: theme.variant)
            theme.persist(to: prefs)
            rebuild()
            return
        }
        let alert = UIAlertController(
            title: "Custom Theme Editor",
            message: "Adjust every Material 3 color role and preview changes instantly. A custom palette is built from the current one, so pick a palette first and then edit its roles.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Start from current", style: .default, handler: { [weak self] _ in
            guard let self = self else { return }
            let base = FlowPalettes.pair(for: self.theme.effectiveSlot.mode).colors(for: self.theme.effectiveSlot.variant)
            self.theme.applyCustom(base, variant: self.theme.effectiveSlot.variant)
            self.theme.persist(to: self.prefs)
            self.rebuild()
        }))
        present(alert, animated: true, completion: nil)
    }

    // MARK: - Theme

    override func applyTheme() {
        super.applyTheme()
        preview.applyTheme()
        fontPreview.applyTheme()
        styleControl.applyTheme()
        fontControl.applyTheme()
        filterRow.applyTheme()
        for card in paletteCards.values {
            card.applyTheme()
        }
    }
}

// MARK: - Preview card

/// The card at the top of Appearance: the current palette's name, its style, and a sample of the
/// surfaces and accents it produces.
final class ThemePreviewCard: UIControl {

    private let background = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let swatchRow = UIStackView()
    private let sampleButton = UILabel()
    private let sampleChip = UILabel()

    /// Called when the viewer asks to edit the palette.
    var onOpenCustomise: (() -> Void)?

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
        applyCornerRadius(FlowShapes.large)

        background.translatesAutoresizingMaskIntoConstraints = false
        background.isUserInteractionEnabled = false
        background.applyCornerRadius(FlowShapes.large)
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        titleLabel.font = FlowTypography.titleLarge
        titleLabel.numberOfLines = 2
        subtitleLabel.font = FlowTypography.bodyMedium
        subtitleLabel.numberOfLines = 3

        swatchRow.axis = .horizontal
        swatchRow.spacing = FlowSpacing.sm
        swatchRow.alignment = .center
        swatchRow.distribution = .fillEqually

        sampleButton.font = FlowTypography.labelLarge
        sampleButton.textAlignment = .center
        sampleButton.text = "Play"
        sampleButton.applyCornerRadius(FlowShapes.pill(for: 36.0))
        sampleButton.layer.masksToBounds = true

        sampleChip.font = FlowTypography.labelMedium
        sampleChip.textAlignment = .center
        sampleChip.text = "Chip"
        sampleChip.applyCornerRadius(FlowShapes.chip)
        sampleChip.layer.masksToBounds = true

        let buttonRow = UIStackView(arrangedSubviews: [sampleButton, sampleChip])
        buttonRow.axis = .horizontal
        buttonRow.spacing = FlowSpacing.md
        buttonRow.alignment = .center
        sampleButton.widthAnchor.constraint(equalToConstant: 96.0).isActive = true
        sampleButton.heightAnchor.constraint(equalToConstant: 36.0).isActive = true
        sampleChip.widthAnchor.constraint(equalToConstant: 72.0).isActive = true
        sampleChip.heightAnchor.constraint(equalToConstant: 28.0).isActive = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, swatchRow, buttonRow])
        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.xl),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.xl),
            swatchRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            swatchRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            swatchRow.heightAnchor.constraint(equalToConstant: 10.0),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        accessibilityTraits = .button
        applyTheme()
    }

    @objc private func handleTap() {
        onOpenCustomise?()
    }

    /// Repaints the preview from the live theme.
    func applyTheme() {
        let theme = FlowTheme.shared
        let scheme = theme.scheme
        background.backgroundColor = scheme.surfaceContainerLow
        titleLabel.textColor = scheme.onSurface
        subtitleLabel.textColor = scheme.onSurfaceVariant

        let mode = theme.effectiveSlot.mode
        let name = theme.mode == .custom ? "Custom" : mode.displayName
        titleLabel.text = name + " · " + theme.variant.displayName
        subtitleLabel.text = theme.mode == .custom
            ? "Your own palette, with every colour editable."
            : mode.summary

        for view in swatchRow.arrangedSubviews {
            view.removeFromSuperview()
        }
        let roles: [UIColor] = [
            scheme.primary,
            scheme.secondary,
            scheme.tertiary,
            scheme.surfaceContainerHighest,
            scheme.error,
        ]
        for colour in roles {
            let pill = UIView()
            pill.backgroundColor = colour
            pill.applyCornerRadius(5.0)
            swatchRow.addArrangedSubview(pill)
        }

        sampleButton.backgroundColor = scheme.primary
        sampleButton.textColor = scheme.onPrimary
        sampleChip.backgroundColor = scheme.secondaryContainer
        sampleChip.textColor = scheme.onSecondaryContainer
        accessibilityLabel = titleLabel.text
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.85 : 1.0
        }
    }
}

// MARK: - Palette card

/// One palette in the picker: a swatch tile showing the palette's own background with three
/// colour pills, the palette's name, a check mark when it is in use, and its description.
///
/// The tile is what makes the list readable at a glance: the palette's background is the tile, so
/// a light palette and a dark palette look different before the name is read.
final class ThemePaletteCard: UIControl {

    private let tile = UIView()
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    private let checkView = FlowIconView()
    private let disabledLabel = UILabel()
    private let container = UIView()
    private var mode: ThemeMode = .default

    /// Called when the card is tapped.
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
        applyCornerRadius(FlowShapes.medium)

        container.translatesAutoresizingMaskIntoConstraints = false
        container.isUserInteractionEnabled = false
        container.applyCornerRadius(FlowShapes.medium)
        container.layer.borderWidth = 1.0
        addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.applyCornerRadius(FlowShapes.small)
        tile.layer.borderWidth = 1.0
        container.addSubview(tile)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: FlowSpacing.lg),
            tile.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 64.0),
            tile.heightAnchor.constraint(equalToConstant: 52.0),
        ])

        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 1
        summaryLabel.font = FlowTypography.bodySmall
        summaryLabel.numberOfLines = 2

        checkView.icon = .check
        checkView.iconSize = 20.0
        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.widthAnchor.constraint(equalToConstant: 20.0).isActive = true
        checkView.heightAnchor.constraint(equalToConstant: 20.0).isActive = true

        disabledLabel.font = FlowTypography.labelSmall
        disabledLabel.text = "Unavailable"
        disabledLabel.isHidden = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, summaryLabel, disabledLabel])
        textStack.axis = .vertical
        textStack.spacing = FlowSpacing.xxs
        textStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textStack)
        container.addSubviewForAutoLayout(checkView)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: FlowSpacing.lg),
            textStack.topAnchor.constraint(equalTo: container.topAnchor, constant: FlowSpacing.lg),
            textStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -FlowSpacing.lg),
            textStack.trailingAnchor.constraint(equalTo: checkView.leadingAnchor, constant: -FlowSpacing.md),

            checkView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -FlowSpacing.lg),
            checkView.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 76.0),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        accessibilityTraits = .button
    }

    /// Sets the palette, whether it is in use and whether it can be chosen.
    func configure(mode: ThemeMode, isSelected: Bool, isEnabled: Bool) {
        self.mode = mode
        titleLabel.text = mode.displayName
        summaryLabel.text = mode.summary
        checkView.isHidden = !isSelected
        disabledLabel.isHidden = isEnabled
        isUserInteractionEnabled = isEnabled
        accessibilityLabel = mode.displayName
        accessibilityValue = isSelected ? "Selected" : nil
        accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        applyTheme()
    }

    @objc private func handleTap() {
        onTap?()
    }

    /// Repaints the card. The tile always shows the palette's own colours, not the app's: that is
    /// what the card is for.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        let selected = !checkView.isHidden
        let enabled = isUserInteractionEnabled

        container.backgroundColor = selected ? scheme.surfaceContainerHighest : scheme.surfaceContainerLow
        container.layer.borderWidth = selected ? 1.5 : 1.0
        container.layer.borderColor = (selected ? scheme.outline : scheme.outlineVariant).cgColor

        titleLabel.textColor = enabled ? scheme.onSurface : scheme.onSurfaceVariant
        summaryLabel.textColor = scheme.onSurfaceVariant
        checkView.iconColor = scheme.primary
        disabledLabel.textColor = scheme.onSurfaceVariant
        alpha = enabled ? 1.0 : 0.6

        let variant: ThemeVariant = mode.defaultVariant
        let colors = FlowPalettes.pair(for: mode).colors(for: variant)
        tile.backgroundColor = colors.background
        tile.layer.borderColor = colors.outline.withAlpha(0.6).cgColor

        for view in tile.subviews {
            view.removeFromSuperview()
        }
        let pills = UIStackView()
        pills.axis = .horizontal
        pills.spacing = 4.0
        pills.alignment = .center
        pills.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(pills)
        NSLayoutConstraint.activate([
            pills.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            pills.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            pills.heightAnchor.constraint(equalToConstant: 30.0),
        ])
        let roles: [UIColor] = [colors.primary, colors.secondary, colors.surfaceContainerHighest]
        for colour in roles {
            let pill = UIView()
            pill.backgroundColor = colour
            pill.applyCornerRadius(4.0)
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.widthAnchor.constraint(equalToConstant: 9.0).isActive = true
            pill.heightAnchor.constraint(equalToConstant: 30.0).isActive = true
            pills.addArrangedSubview(pill)
        }
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.8 : (isUserInteractionEnabled ? 1.0 : 0.6)
        }
    }
}

// MARK: - Font preview

/// The font sample above the font picker: the same sentence in the display, title, body and label
/// roles, so the difference between System, Condensed and Serif is visible before choosing.
final class FontPreviewCard: UIView {

    private let displayLabel = UILabel()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let labelLabel = UILabel()

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
        applyCornerRadius(FlowShapes.medium)

        displayLabel.text = "Aa"
        titleLabel.text = "The quick brown fox"
        bodyLabel.text = "Jumps over the lazy dog while the captions roll."
        labelLabel.text = "LABEL · 12:34"

        let stack = UIStackView(arrangedSubviews: [displayLabel, titleLabel, bodyLabel, labelLabel])
        stack.axis = .vertical
        stack.spacing = FlowSpacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.xl),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.xl),
        ])
        applyTheme()
    }

    /// Repaints the sample in the active font and palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = scheme.surfaceContainerLow
        displayLabel.font = FlowTypography.displayMedium
        titleLabel.font = FlowTypography.titleLarge
        bodyLabel.font = FlowTypography.bodyMedium
        labelLabel.font = FlowTypography.labelMedium
        displayLabel.textColor = scheme.primary
        titleLabel.textColor = scheme.onSurface
        bodyLabel.textColor = scheme.onSurfaceVariant
        labelLabel.textColor = scheme.onSurfaceVariant
    }
}

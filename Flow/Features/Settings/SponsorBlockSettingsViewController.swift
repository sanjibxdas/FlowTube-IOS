import UIKit

/// SponsorBlock: which kinds of segment are skipped, what happens when one is reached, and the
/// colour each category is drawn in on the seek bar.
///
/// The switches here are the categories the app asks the server for and acts on. They are stored as
/// the category ids SponsorBlock itself uses, so a category added to the service later appears here
/// without a migration. The colours are not editable: they are the ones people already know from
/// the SponsorBlock browser extension, and keeping them identical is what makes the seek bar
/// readable at a glance.
final class SponsorBlockSettingsViewController: SettingsListViewController {

    private let prefs = FlowApp.shared.prefs

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "SponsorBlock"
    }

    // MARK: - Sections

    override var sections: [SettingsSection] {
        return [
            masterSection(),
            categoriesSection(),
            legendSection(),
            deArrowSection(),
        ]
    }

    private func masterSection() -> SettingsSection {
        let enabled = prefs.bool(for: .sponsorBlockEnabled, fallback: true)
        return SettingsSection(
            header: "SponsorBlock",
            footer: "Segments come from the SponsorBlock community database. Nothing about what you watch is sent to it.",
            rows: [
                .toggle(
                    "SponsorBlock",
                    icon: .filter,
                    subtitle: "Skip sponsored segments",
                    isOn: enabled,
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .sponsorBlockEnabled)
                        self?.rebuild()
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
                .toggle(
                    "Notify when a segment is skipped",
                    icon: .notification,
                    subtitle: "Show a message naming the category that was skipped",
                    isOn: prefs.bool(for: .sponsorBlockNotifyOnSkip, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .sponsorBlockNotifyOnSkip)
                    }
                ),
                .toggle(
                    "Show segments on the seek bar",
                    icon: .chapter,
                    subtitle: "Mark each segment in its category colour",
                    isOn: prefs.bool(for: .sponsorBlockShowOnSeekBar, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .sponsorBlockShowOnSeekBar)
                    }
                ),
            ]
        )
    }

    private func categoriesSection() -> SettingsSection {
        let enabledCategories = Set(prefs.sponsorBlockCategories)
        let rows = SponsorBlockCategory.allCases.map { category -> SettingsRow in
            let isOn = enabledCategories.contains(category.rawValue)
            return .toggle(
                category.displayName,
                icon: nil,
                subtitle: nil,
                isOn: isOn,
                onChange: { [weak self] value in
                    self?.setCategory(category.rawValue, enabled: value)
                }
            )
        }
        return SettingsSection(
            header: "SponsorBlock Segment Actions",
            footer: "Turn a category off to leave those segments in the video. Filler and previews are off by default.",
            rows: rows
        )
    }

    private func legendSection() -> SettingsSection {
        var rows: [SettingsRow] = []
        for category in SponsorBlockCategory.allCases {
            rows.append(.custom(configure: { cell in
                let swatch = SponsorBlockSwatchRow()
                swatch.configure(category: category)
                cell.contentStack.addArrangedSubview(swatch)
            }, action: nil))
        }
        return SettingsSection(
            header: "Colour legend",
            footer: "These are the SponsorBlock colours, kept the same as the browser extension so a segment reads the same everywhere.",
            rows: rows
        )
    }

    private func deArrowSection() -> SettingsSection {
        return SettingsSection(
            header: "DeArrow & RYD",
            footer: "DeArrow replaces clickbait titles and thumbnails with community submissions. Return YouTube Dislike shows the dislike count.",
            rows: [
                .toggle(
                    "DeArrow",
                    icon: .edit,
                    subtitle: "Swap clickbait titles and thumbnails for community ones",
                    isOn: prefs.bool(for: .deArrowEnabled, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .deArrowEnabled)
                        self?.rebuild()
                    }
                ),
                .toggle(
                    "DeArrow titles",
                    icon: .edit,
                    subtitle: "Replace titles with community submissions",
                    isOn: prefs.bool(for: .deArrowTitles, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .deArrowTitles)
                    }
                ),
                .toggle(
                    "DeArrow thumbnails",
                    icon: .library,
                    subtitle: "Replace thumbnails with community submissions",
                    isOn: prefs.bool(for: .deArrowThumbnails, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .deArrowThumbnails)
                    }
                ),
                .toggle(
                    "Return YouTube Dislike",
                    icon: .dislike,
                    subtitle: "Show dislike counts from Return YouTube Dislike",
                    isOn: prefs.bool(for: .returnYouTubeDislikeEnabled, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .returnYouTubeDislikeEnabled)
                    }
                ),
            ]
        )
    }

    // MARK: - Actions

    /// Adds or removes one category from the stored list.
    private func setCategory(_ rawValue: String, enabled: Bool) {
        var categories = prefs.sponsorBlockCategories
        if enabled {
            if !categories.contains(rawValue) {
                categories.append(rawValue)
            }
        } else {
            categories.removeAll { $0 == rawValue }
        }
        // Keep the stored order stable so the settings list and the seek bar agree.
        let order = SponsorBlockCategory.all
        categories.sort { left, right in
            let leftIndex = order.firstIndex(of: left) ?? order.count
            let rightIndex = order.firstIndex(of: right) ?? order.count
            return leftIndex < rightIndex
        }
        prefs.sponsorBlockCategories = categories
        SponsorBlockService.shared.categories = categories
        rebuild()
    }
}

// MARK: - Swatch row

/// One line of the colour legend: the category's colour as a round swatch, its name, and what the
/// player does when it reaches one.
final class SponsorBlockSwatchRow: UIView {

    private let swatch = UIView()
    private let titleLabel = UILabel()
    private let actionLabel = UILabel()

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

        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.layer.cornerRadius = 12.0
        swatch.layer.masksToBounds = true
        swatch.layer.borderWidth = 1.0
        addSubview(swatch)

        titleLabel.font = FlowTypography.bodyLarge
        titleLabel.numberOfLines = 1
        actionLabel.font = FlowTypography.bodySmall
        actionLabel.numberOfLines = 1
        actionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubviewForAutoLayout(titleLabel)
        addSubviewForAutoLayout(actionLabel)

        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 24.0),
            swatch.heightAnchor.constraint(equalToConstant: 24.0),

            titleLabel.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.xs),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.xs),

            actionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: FlowSpacing.md),
            actionLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 32.0),
        ])
        applyTheme()
    }

    /// Sets the swatch colour and the action text for one category.
    func configure(category: SponsorBlockCategory) {
        let colour = UIColor(hex: UInt32(truncatingIfNeeded: SponsorBlockCategory.defaultColor(for: category.rawValue)))
        swatch.backgroundColor = colour
        titleLabel.text = category.displayName
        actionLabel.text = SponsorBlockCategory.defaultAction(for: category.rawValue).displayName
        accessibilityLabel = category.displayName
        accessibilityValue = actionLabel.text
        applyTheme()
    }

    /// Repaints the row in the current palette. The swatch keeps its category colour.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        actionLabel.textColor = scheme.onSurfaceVariant
        swatch.layer.borderColor = scheme.outlineVariant.cgColor
    }
}

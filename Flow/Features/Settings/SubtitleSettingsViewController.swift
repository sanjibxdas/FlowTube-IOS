import UIKit

/// Subtitles: the size, colour and background of captions, with a live preview above the controls.
///
/// The preview is drawn by `SubtitleRenderer` itself — the same view the player uses — so what the
/// screen shows is exactly what a video will show, including the font weight and the way the
/// background box hugs each line. The values are written straight into `PrefsStore`, which the
/// renderer reads when it reloads its style, so a change is visible in the player without a restart.
final class SubtitleSettingsViewController: SettingsListViewController {

    private let prefs = FlowApp.shared.prefs

    /// The preview renderer. It is a real renderer, not a mock-up.
    private let preview = SubtitleRenderer()

    /// The preview's backdrop, so white captions are readable in a light theme too.
    private let previewBackdrop = UIView()

    /// The colour choices offered for caption text.
    static let textColors: [(name: String, hex: String)] = [
        ("White", "#FFFFFF"),
        ("Yellow", "#FFEB3B"),
        ("Cyan", "#00E5FF"),
        ("Green", "#76FF03"),
        ("Black", "#000000"),
    ]

    /// The scale range the renderer accepts.
    static let minimumScale: Float = 0.6
    static let maximumScale: Float = 2.4

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Subtitle Style"
        buildPreview()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshPreview()
    }

    // MARK: - Sections

    override var sections: [SettingsSection] {
        return [
            previewSection(),
            sizeSection(),
            colourSection(),
            backgroundSection(),
            resetSection(),
        ]
    }

    private func previewSection() -> SettingsSection {
        return SettingsSection(
            header: "Preview Subtitle Text",
            footer: "This is the renderer the player uses, at the size and colours chosen below.",
            rows: [
                .custom(configure: { [weak self] cell in
                    guard let self = self else { return }
                    self.previewBackdrop.removeFromSuperview()
                    cell.contentStack.addArrangedSubview(self.previewBackdrop)
                    self.buildPreview()
                }, action: nil),
            ]
        )
    }

    private func sizeSection() -> SettingsSection {
        let style = SubtitleStyle.current
        let percent = Int((style.fontScale * 100.0).rounded())
        return SettingsSection(
            header: "Size",
            footer: "Captions scale with this setting and with the system text size.",
            rows: [
                .slider(
                    title: "Font Size",
                    valueText: "Font Size: \(percent)",
                    value: Float(style.fontScale),
                    minimum: SubtitleSettingsViewController.minimumScale,
                    maximum: SubtitleSettingsViewController.maximumScale,
                    onChange: { [weak self] value in
                        self?.prefs.set(Double(value), for: .subtitleFontScale)
                        self?.refreshPreview()
                    },
                    onCommit: { [weak self] value in
                        self?.prefs.set(Double(value), for: .subtitleFontScale)
                        self?.refreshPreview()
                        self?.rebuild()
                    }
                ),
            ]
        )
    }

    private func colourSection() -> SettingsSection {
        let current = prefs.string(for: .subtitleTextColor) ?? "#FFFFFF"
        var rows: [SettingsRow] = [
            .custom(configure: { [weak self] cell in
                guard let self = self else { return }
                let row = SubtitleColorPickerRow(
                    colors: SubtitleSettingsViewController.textColors,
                    selectedHex: self.prefs.string(for: .subtitleTextColor) ?? "#FFFFFF"
                )
                row.onSelect = { [weak self] hex in
                    self?.prefs.set(hex, for: .subtitleTextColor)
                    self?.refreshPreview()
                    self?.rebuild()
                }
                cell.contentStack.addArrangedSubview(row)
            }, action: nil),
        ]
        rows.append(.detail(
            icon: nil,
            title: "Text Color",
            subtitle: "The colour captions are drawn in",
            value: SubtitleSettingsViewController.textColors.first(where: { $0.hex == current })?.name ?? current
        ))
        return SettingsSection(
            header: "Text Color",
            footer: "A colour with enough contrast against the video is easier to read than a bright one.",
            rows: rows
        )
    }

    private func backgroundSection() -> SettingsSection {
        let style = SubtitleStyle.current
        let percent = Int((style.backgroundOpacity * 100.0).rounded())
        return SettingsSection(
            header: "Background",
            footer: "The box behind the text. Zero leaves captions with no background at all.",
            rows: [
                .slider(
                    title: "Background Opacity",
                    valueText: "Background Opacity: \(percent)%",
                    value: Float(style.backgroundOpacity),
                    minimum: 0.0,
                    maximum: 1.0,
                    onChange: { [weak self] value in
                        self?.prefs.set(Double(value), for: .subtitleBackgroundOpacity)
                        self?.refreshPreview()
                    },
                    onCommit: { [weak self] value in
                        self?.prefs.set(Double(value), for: .subtitleBackgroundOpacity)
                        self?.refreshPreview()
                        self?.rebuild()
                    }
                ),
                .detail(
                    icon: nil,
                    title: "Background Color",
                    subtitle: "Captions use black behind the text",
                    value: "#000000"
                ),
            ]
        )
    }

    private func resetSection() -> SettingsSection {
        return SettingsSection(
            header: nil,
            footer: nil,
            rows: [
                .destructive(
                    "Reset to Default",
                    icon: .trash,
                    subtitle: "White text at the default size and background",
                    action: { [weak self] in
                        self?.resetToDefault()
                    }
                ),
            ]
        )
    }

    // MARK: - Preview

    private func buildPreview() {
        previewBackdrop.translatesAutoresizingMaskIntoConstraints = false
        previewBackdrop.applyCornerRadius(FlowShapes.medium)
        previewBackdrop.heightAnchor.constraint(equalToConstant: 132.0).isActive = true

        preview.translatesAutoresizingMaskIntoConstraints = false
        previewBackdrop.addSubviewForAutoLayout(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: previewBackdrop.leadingAnchor, constant: FlowSpacing.md),
            preview.trailingAnchor.constraint(equalTo: previewBackdrop.trailingAnchor, constant: -FlowSpacing.md),
            preview.topAnchor.constraint(equalTo: previewBackdrop.topAnchor, constant: FlowSpacing.md),
            preview.bottomAnchor.constraint(equalTo: previewBackdrop.bottomAnchor, constant: -FlowSpacing.md),
        ])

        preview.style = SubtitleStyle.current
        preview.showPreviewText("Preview Subtitle Text\nCaptions look like this")
        applyTheme()
    }

    /// Re-reads the preferences into the preview renderer.
    private func refreshPreview() {
        preview.style = SubtitleStyle.current
        preview.reloadStyleFromPreferences()
        preview.showPreviewText("Preview Subtitle Text\nCaptions look like this")
        applyTheme()
    }

    private func resetToDefault() {
        prefs.set(1.0, for: .subtitleFontScale)
        prefs.set("#FFFFFF", for: .subtitleTextColor)
        prefs.set(0.6, for: .subtitleBackgroundOpacity)
        refreshPreview()
        rebuild()
        FlowSnackbar.show("Subtitle style reset")
    }

    // MARK: - Theme

    override func applyTheme() {
        super.applyTheme()
        let scheme = FlowTheme.shared.scheme
        // The preview sits on a dark backdrop in both themes: captions are drawn over video, and a
        // white-on-white preview would say nothing about how they read.
        previewBackdrop.backgroundColor = scheme.isDark ? UIColor(hex: 0x101010) : UIColor(hex: 0x1B1B1B)
        preview.applyStyle()
    }
}

// MARK: - Colour picker

/// A row of round colour swatches. The chosen one gets a ring in the palette's primary colour.
final class SubtitleColorPickerRow: UIView {

    private let stack = UIStackView()
    private var swatches: [(hex: String, view: UIView)] = []

    /// Called with the chosen colour's hex string.
    var onSelect: ((String) -> Void)?

    init(colors: [(name: String, hex: String)], selectedHex: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = FlowSpacing.lg
        stack.alignment = .center
        addSubviewForAutoLayout(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 44.0),
        ])

        for entry in colors {
            let swatch = UIControl()
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.backgroundColor = UIColor(hexString: entry.hex) ?? .white
            swatch.layer.cornerRadius = 18.0
            swatch.layer.masksToBounds = true
            swatch.layer.borderWidth = entry.hex == selectedHex ? 3.0 : 1.0
            swatch.widthAnchor.constraint(equalToConstant: 36.0).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 36.0).isActive = true
            swatch.accessibilityLabel = entry.name
            swatch.accessibilityTraits = .button
            swatch.isAccessibilityElement = true
            swatch.addClosureAction(for: .touchUpInside) { [weak self] in
                self?.onSelect?(entry.hex)
            }
            swatches.append((entry.hex, swatch))
            stack.addArrangedSubview(swatch)
        }
        applyTheme()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Repaints the selection rings in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        for entry in swatches {
            let isSelected = entry.view.layer.borderWidth > 2.0
            entry.view.layer.borderColor = (isSelected ? scheme.primary : scheme.outlineVariant).cgColor
        }
    }
}

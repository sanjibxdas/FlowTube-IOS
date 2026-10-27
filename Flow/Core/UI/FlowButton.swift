import UIKit

/// The button styles Material 3 defines, mapped to UIKit.
enum FlowButtonStyle {
    /// Filled with the primary colour. The single most important action on a screen.
    case filled
    /// Outlined, transparent. Secondary actions.
    case outlined
    /// No container, accent text. Inline and toolbar actions.
    case text
    /// Filled with the accent's container tint. Toggle-like actions.
    case tonal
    /// Filled with the error colour. Destructive actions.
    case destructive
}

/// A Material 3 button: a pill or rounded rectangle with a label, an optional leading icon, a
/// pressed state and a disabled state. Theming is applied through `applyTheme()` so a palette change
/// repaints every button that is on screen.
final class FlowButton: UIControl {

    private let titleLabel = UILabel()
    private let iconView = FlowIconView()
    private let container = UIView()
    private let stack = UIStackView()

    private(set) var style: FlowButtonStyle = .filled
    private var icon: FlowIcon?
    /// Set by `setIconColor`; re-applied after theming so a palette switch keeps it.
    private var iconColorOverride: UIColor?
    private var titleText: String = ""

    /// The action the button runs. Set by the owning screen.
    var onTap: (() -> Void)?

    /// Whether the button shows a spinner instead of its content.
    private(set) var isLoading = false
    private let spinner = UIActivityIndicatorView(style: .white)

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
        addSubviewForAutoLayout(container)
        container.isUserInteractionEnabled = false
        container.layer.masksToBounds = true

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = FlowSpacing.md
        stack.isUserInteractionEnabled = false
        container.addSubviewForAutoLayout(stack)

        titleLabel.font = FlowTypography.labelLarge
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1

        iconView.isHidden = true
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)

        spinner.hidesWhenStopped = true
        spinner.isUserInteractionEnabled = false
        addSubviewForAutoLayout(spinner)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 40.0),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: FlowSpacing.xl),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -FlowSpacing.xl),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTarget(self, action: #selector(handleTouchUpInside), for: .touchUpInside)
        addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
        addTarget(self, action: #selector(handleTouchUpOutside), for: [.touchUpOutside, .touchCancel, .touchDragExit])
        accessibilityTraits = .button
        applyTheme()
    }

    // MARK: - Construction

    /// Creates a button with a title.
    static func make(_ title: String, style: FlowButtonStyle = .filled, icon: FlowIcon? = nil) -> FlowButton {
        let button = FlowButton()
        button.configure(title: title, style: style, icon: icon)
        return button
    }

    /// Creates an icon-only button, still with a full tap target.
    static func makeIcon(_ icon: FlowIcon, style: FlowButtonStyle = .text) -> FlowButton {
        let button = FlowButton()
        button.configure(title: "", style: style, icon: icon)
        return button
    }

    /// Sets the title, style and optional leading icon.
    func configure(title: String, style: FlowButtonStyle, icon: FlowIcon? = nil) {
        titleText = title
        self.style = style
        self.icon = icon
        titleLabel.text = title
        titleLabel.isHidden = title.isEmpty
        if let glyph = icon {
            iconView.isHidden = false
            iconView.icon = glyph
            iconView.iconSize = 18.0
            iconView.widthAnchor.constraint(equalToConstant: 18.0).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 18.0).isActive = true
        } else {
            iconView.isHidden = true
        }
        accessibilityLabel = title.isEmpty ? (icon.map { FlowIcon.accessibilityName(for: $0) } ?? "Button") : title
        applyTheme()
    }

    /// Replaces the title after creation, e.g. "Subscribe" to "Subscribed".
    /// Overrides the icon tint for call sites that need a specific colour (for example the
    /// artist hero, where the share button sits on artwork rather than on a container).
    func setIconColor(_ color: UIColor) {
        iconColorOverride = color
        iconView.iconColor = color
    }

    func setTitle(_ title: String) {
        titleText = title
        titleLabel.text = title
        titleLabel.isHidden = title.isEmpty
        accessibilityLabel = title
    }

    /// Replaces the glyph after creation, e.g. a checkmark once an action succeeded.
    func setIcon(_ icon: FlowIcon?) {
        self.icon = icon
        guard let glyph = icon else {
            iconView.isHidden = true
            return
        }
        iconView.isHidden = false
        iconView.icon = glyph
    }

    /// Shows a spinner in place of the content while an action is in flight.
    func setLoading(_ loading: Bool) {
        isLoading = loading
        stack.isHidden = loading
        if loading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        isUserInteractionEnabled = !loading
    }

    // MARK: - Theming

    /// Repaints the button in the current palette. Called on creation and on every theme change.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        switch style {
        case .filled:
            container.backgroundColor = scheme.primary
            titleLabel.textColor = scheme.onPrimary
            iconView.iconColor = scheme.onPrimary
            spinner.style = .white
            container.layer.borderWidth = 0.0
        case .tonal:
            container.backgroundColor = scheme.secondaryContainer
            titleLabel.textColor = scheme.onSecondaryContainer
            iconView.iconColor = scheme.onSecondaryContainer
            spinner.style = .white
            container.layer.borderWidth = 0.0
        case .outlined:
            container.backgroundColor = .clear
            titleLabel.textColor = scheme.primary
            iconView.iconColor = scheme.primary
            spinner.style = .gray
            container.layer.borderWidth = 1.0
            container.layer.borderColor = scheme.outline.cgColor
        case .text:
            container.backgroundColor = .clear
            titleLabel.textColor = scheme.primary
            iconView.iconColor = scheme.primary
            spinner.style = .gray
            container.layer.borderWidth = 0.0
        case .destructive:
            container.backgroundColor = scheme.error
            titleLabel.textColor = scheme.onError
            iconView.iconColor = scheme.onError
            spinner.style = .white
            container.layer.borderWidth = 0.0
        }
        alpha = isEnabled ? 1.0 : 0.38
            if let override = iconColorOverride {
            iconView.iconColor = override
        }
}

    override func layoutSubviews() {
        super.layoutSubviews()
        container.layer.cornerRadius = min(bounds.height / 2.0, FlowShapes.extraSmall + 16.0)
    }

    // MARK: - State

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1.0 : 0.38
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard !isLoading else { return }
            let target: CGFloat = isHighlighted ? 0.86 : 1.0
            if UIAccessibility.isReduceMotionEnabled {
                container.alpha = target
            } else {
                UIView.animate(withDuration: FlowMotion.quick, delay: 0.0, options: [.curveEaseOut], animations: {
                    self.container.alpha = target
                }, completion: nil)
            }
        }
    }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: UIView.noIntrinsicMetric, height: 40.0)
    }

    @objc private func handleTouchUpInside() {
        onTap?()
    }

    @objc private func handleTouchDown() {
        isHighlighted = true
    }

    @objc private func handleTouchUpOutside() {
        isHighlighted = false
    }
}

extension FlowIcon {
    /// A spoken name for an icon, so an icon-only button is not announced as "button".
    static func accessibilityName(for icon: FlowIcon) -> String {
        switch icon {
        case .home: return "Home"
        case .shorts: return "Shorts"
        case .music: return "Music"
        case .subscriptions: return "Subscriptions"
        case .library: return "Library"
        case .search: return "Search"
        case .back: return "Back"
        case .close: return "Close"
        case .more: return "More options"
        case .play: return "Play"
        case .pause: return "Pause"
        case .next: return "Next"
        case .previous: return "Previous"
        case .shuffle: return "Shuffle"
        case .repeatAll: return "Repeat"
        case .repeatOne: return "Repeat one"
        case .volume: return "Volume"
        case .mute: return "Mute"
        case .fullscreen: return "Full screen"
        case .pip: return "Picture in picture"
        case .download: return "Download"
        case .downloaded: return "Downloaded"
        case .heart: return "Save"
        case .liked: return "Liked"
        case .playlist: return "Playlist"
        case .add: return "Add"
        case .check: return "Done"
        case .share: return "Share"
        case .settings: return "Settings"
        case .cast: return "Cast"
        case .subtitles: return "Subtitles"
        case .chapter: return "Chapters"
        case .clock: return "Clock"
        case .trash: return "Delete"
        case .edit: return "Edit"
        case .drag: return "Reorder"
        case .mic: return "Microphone"
        case .equalizer: return "Equalizer"
        case .wifi: return "Wi-Fi"
        case .moon: return "Dark theme"
        case .sun: return "Light theme"
        case .chevronDown: return "Expand"
        case .chevronRight: return "Open"
        case .filter: return "Filter"
        case .sort: return "Sort"
        case .notes: return "Notes"
        case .recap: return "Recap"
        case .sync: return "Sync"
        case .importIcon: return "Import"
        case .exportIcon: return "Export"
        case .notification: return "Notifications"
        case .verified: return "Verified"
        case .live: return "Live"
        case .dislike: return "Dislike"
        case .comment: return "Comments"
        case .queue: return "Queue"
        }
    }
}

import UIKit

/// A centred state for "nothing here yet", "could not load" and "you are offline". Every list screen
/// shows one of these instead of an empty table, matching the Android app's empty and error states.
final class FlowEmptyState: UIView {

    /// Which illustration and wording the state shows.
    enum Kind {
        case noResults
        case noHistory
        case noDownloads
        case noPlaylists
        case noSubscriptions
        case noNotes
        case noComments
        case noNetwork
        case error
        case custom(icon: FlowIcon, title: String, message: String)
    }

    private let iconView = FlowIconView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let actionButton = FlowButton.make("", style: .filled)
    private let stack = UIStackView()

    /// Called when the action button is tapped.
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
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = FlowSpacing.lg
        addSubviewForAutoLayout(stack)

        iconView.iconSize = 48.0
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 48.0).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 48.0).isActive = true

        titleLabel.font = FlowTypography.titleLarge
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        messageLabel.font = FlowTypography.bodyMedium
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 4

        actionButton.isHidden = true
        actionButton.onTap = { [weak self] in
            self?.onAction?()
        }

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(actionButton)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: FlowSpacing.xxxl),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -FlowSpacing.xxxl),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360.0),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        applyTheme()
    }

    /// Creates a state of the given kind, with an optional action.
    static func make(kind: Kind, actionTitle: String? = nil) -> FlowEmptyState {
        let view = FlowEmptyState()
        view.configure(kind: kind, actionTitle: actionTitle)
        return view
    }

    /// Sets the state's wording and illustration.
    func configure(kind: Kind, actionTitle: String? = nil) {
        let content: (FlowIcon, String, String)
        switch kind {
        case .noResults:
            content = (.search, "No results", "Try a different search or remove a filter.")
        case .noHistory:
            content = (.clock, "No watch history", "Videos you watch will show up here.")
        case .noDownloads:
            content = (.download, "No downloads", "Download a video to watch it without a connection.")
        case .noPlaylists:
            content = (.playlist, "No playlists", "Playlists you create will show up here.")
        case .noSubscriptions:
            content = (.subscriptions, "No subscriptions", "Subscribe to a channel to see its latest uploads.")
        case .noNotes:
            content = (.notes, "No notes", "Notes you write on a video will show up here.")
        case .noComments:
            content = (.comment, "No comments", "Comments are turned off for this video, or none have been posted yet.")
        case .noNetwork:
            content = (.wifi, "You are offline", "Check your connection and try again.")
        case .error:
            content = (.sync, "Something went wrong", "The request could not be completed.")
        case .custom(let icon, let title, let message):
            content = (icon, title, message)
        }
        iconView.icon = content.0
        titleLabel.text = content.1
        messageLabel.text = content.2
        if let action = actionTitle, !action.isEmpty {
            actionButton.configure(title: action, style: .filled)
            actionButton.isHidden = false
            actionButton.accessibilityLabel = action
        } else {
            actionButton.isHidden = true
        }
        accessibilityLabel = content.1
    }

    /// Repaints the state in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        iconView.iconColor = scheme.onSurfaceVariant
        titleLabel.textColor = scheme.onSurface
        messageLabel.textColor = scheme.onSurfaceVariant
        actionButton.applyTheme()
    }
}

/// A small inline error row with a retry button, for a page that loaded but whose next page failed.
final class FlowErrorRow: UIView {

    private let messageLabel = UILabel()
    private let retryButton = FlowButton.make("Retry", style: .text)
    private let stack = UIStackView()

    /// Called when Retry is tapped.
    var onRetry: (() -> Void)?

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
        stack.axis = .horizontal
        stack.spacing = FlowSpacing.md
        stack.alignment = .center
        addSubviewForAutoLayout(stack)

        messageLabel.font = FlowTypography.bodyMedium
        messageLabel.numberOfLines = 2

        retryButton.onTap = { [weak self] in
            self?.onRetry?()
        }

        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(retryButton)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.screenMargin),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.lg),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.lg),
        ])
        applyTheme()
    }

    /// Sets the error text.
    func configure(message: String) {
        messageLabel.text = message
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        messageLabel.textColor = scheme.onSurfaceVariant
        retryButton.applyTheme()
    }
}

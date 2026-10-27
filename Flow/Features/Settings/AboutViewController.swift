import UIKit

/// About: who makes Flow, where to find it, what it is licensed under, and the build you are running.
///
/// The structure follows the Android About screen: a header with the mark and version, the creator,
/// then contact, legal and device groups. Links open in the system browser rather than in an
/// in-app web view, because the licence and the repository are pages a person may want to keep
/// open beside the app.
final class AboutViewController: SettingsListViewController {

    /// The project's addresses. Kept together so a moved repository is one edit.
    enum Links {
        static let website = "https://flow-tube.org"
        static let github = "https://github.com/Flow-Tube/Flow"
        static let reddit = "https://www.reddit.com/r/Flow_Official/"
        static let creator = "https://github.com/A-EDev"
        static let creatorAvatar = "https://github.com/A-EDev.png?size=144"
        static let newPipe = "https://github.com/TeamNewPipe/NewPipeExtractor"
        static let license = "https://github.com/Flow-Tube/Flow/blob/main/License"
        static let sponsorBlock = "https://sponsor.ajay.app"
        static let deArrow = "https://dearrow.ajay.app"
        static let returnYouTubeDislike = "https://returnyoutubedislike.com"
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "About Flow"
    }

    // MARK: - Sections

    override var sections: [SettingsSection] {
        return [
            headerSection(),
            creatorSection(),
            appSection(),
            contactSection(),
            legalSection(),
            creditsSection(),
            deviceSection(),
        ]
    }

    private func headerSection() -> SettingsSection {
        let version = AboutViewController.version
        let build = AboutViewController.build
        return SettingsSection(
            header: nil,
            footer: "Flow is free software, licensed under the GNU General Public License v3.",
            rows: [
                .custom(configure: { cell in
                    let header = AboutHeaderView()
                    header.configure(version: version, build: build)
                    cell.contentStack.addArrangedSubview(header)
                }, action: nil),
            ]
        )
    }

    private func creatorSection() -> SettingsSection {
        return SettingsSection(
            header: "Creator",
            footer: "Flow is built and maintained by A-EDev, with the help of everyone who files an issue or sends a change.",
            rows: [
                .custom(configure: { cell in
                    let card = AboutCreatorCard()
                    card.onTap = { AboutViewController.openLink(AboutViewController.Links.creator) }
                    cell.contentStack.addArrangedSubview(card)
                }, action: nil),
            ]
        )
    }

    private func appSection() -> SettingsSection {
        return SettingsSection(
            header: "App",
            footer: nil,
            rows: [
                .detail(
                    icon: .verified,
                    title: "Version",
                    subtitle: nil,
                    value: AboutViewController.version
                ),
                .detail(
                    icon: .settings,
                    title: "Build",
                    subtitle: nil,
                    value: AboutViewController.build
                ),
                .nav(
                    "Source code",
                    icon: .exportIcon,
                    subtitle: "Read, build or change Flow yourself",
                    value: "GitHub",
                    showsChevron: false,
                    action: { AboutViewController.openLink(AboutViewController.Links.github) }
                ),
            ]
        )
    }

    private func contactSection() -> SettingsSection {
        return SettingsSection(
            header: "Contact",
            footer: nil,
            rows: [
                .nav(
                    "Website",
                    icon: .home,
                    subtitle: "flow-tube.org",
                    showsChevron: false,
                    action: { AboutViewController.openLink(AboutViewController.Links.website) }
                ),
                .nav(
                    "GitHub",
                    icon: .exportIcon,
                    subtitle: "Source code & Issues",
                    showsChevron: false,
                    action: { AboutViewController.openLink(AboutViewController.Links.github) }
                ),
                .nav(
                    "Reddit",
                    icon: .comment,
                    subtitle: "r/Flow_Official",
                    showsChevron: false,
                    action: { AboutViewController.openLink(AboutViewController.Links.reddit) }
                ),
            ]
        )
    }

    private func legalSection() -> SettingsSection {
        return SettingsSection(
            header: "Legal",
            footer: "Flow ships no third-party libraries. The services below are used over the network and are credited for their data.",
            rows: [
                .nav(
                    "License",
                    icon: .notes,
                    subtitle: "GNU GPL v3",
                    action: { [weak self] in
                        self?.pushSettings(LicenseViewController())
                    }
                ),
                .nav(
                    "NewPipe Extractor",
                    icon: .importIcon,
                    subtitle: "Core extraction library",
                    showsChevron: false,
                    action: { AboutViewController.openLink(AboutViewController.Links.newPipe) }
                ),
                .nav(
                    "Open source notices",
                    icon: .notes,
                    subtitle: "Word lists and code from other projects",
                    action: { [weak self] in
                        self?.presentNotices()
                    }
                ),
            ]
        )
    }

    private func creditsSection() -> SettingsSection {
        return SettingsSection(
            header: "Credits",
            footer: "These projects supply the data Flow shows beside a video. None of them is bundled with the app.",
            rows: [
                .nav(
                    "SponsorBlock",
                    icon: .clock,
                    subtitle: "Crowd-sourced segment data",
                    showsChevron: false,
                    action: { AboutViewController.openLink(AboutViewController.Links.sponsorBlock) }
                ),
                .nav(
                    "DeArrow",
                    icon: .edit,
                    subtitle: "Community titles and thumbnails",
                    showsChevron: false,
                    action: { AboutViewController.openLink(AboutViewController.Links.deArrow) }
                ),
                .nav(
                    "Return YouTube Dislike",
                    icon: .dislike,
                    subtitle: "Dislike counts",
                    showsChevron: false,
                    action: { AboutViewController.openLink(AboutViewController.Links.returnYouTubeDislike) }
                ),
            ]
        )
    }

    private func deviceSection() -> SettingsSection {
        return SettingsSection(
            header: "Device",
            footer: "Included so a bug report can say exactly what it ran on.",
            rows: [
                .detail(
                    icon: .settings,
                    title: "Device",
                    subtitle: nil,
                    value: AboutViewController.deviceModel
                ),
                .detail(
                    icon: .settings,
                    title: "System",
                    subtitle: nil,
                    value: "iOS " + AboutViewController.systemVersion
                ),
                .detail(
                    icon: .settings,
                    title: "App",
                    subtitle: nil,
                    value: "Flow " + AboutViewController.version + " (" + AboutViewController.build + ")"
                ),
            ]
        )
    }

    // MARK: - Actions

    private func presentNotices() {
        let content = AboutTextSheetContent(
            text: AboutViewController.notices,
            primaryTitle: "Read on GitHub",
            primaryAction: { AboutViewController.openLink(AboutViewController.Links.github) }
        )
        let sheet = FlowSheet(content: content, title: "Open source notices", detent: .large, showsGrabber: true)
        content.onClose = { [weak sheet] in
            sheet?.dismissSheet()
        }
        sheet.present(from: self)
    }

    /// Opens `string` in the system browser. A malformed URL is reported rather than silently
    /// swallowed, because a dead link on this screen is a bug worth seeing.
    static func openLink(_ string: String) {
        guard let url = URL(string: string) else {
            FlowSnackbar.showError("This link could not be opened")
            return
        }
        let application = UIApplication.shared
        guard application.canOpenURL(url) else {
            FlowSnackbar.showError("No app can open this link")
            return
        }
        application.open(url, options: [:], completionHandler: nil)
    }

    // MARK: - Build identity

    /// The marketing version, e.g. "1.0.0".
    static var version: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// The build number, e.g. "1".
    static var build: String {
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// The system version without the build suffix iOS sometimes appends.
    static var systemVersion: String {
        return UIDevice.current.systemVersion.components(separatedBy: " ").first ?? UIDevice.current.systemVersion
    }

    /// The hardware identifier ("iPhone11,8"), which is more useful in a bug report than "iPhone".
    static var deviceModel: String {
        var info = utsname()
        _ = uname(&info)
        let identifier = Mirror(reflecting: info.machine).children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    /// The third-party notices, verbatim from the Android app's `assets/licenses/notices.txt`.
    static let notices: String = """
    Snowball (snowballstem.org)
    Stemmers and stop word lists, used by the recommendation engine.

    Copyright (c) 2001, Dr Martin Porter
    Copyright (c) 2004,2005, Richard Boulton
    Copyright (c) 2013, Yoshiki Shibukawa
    Copyright (c) 2006-2025, Olly Betts
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

      1. Redistributions of source code must retain the above copyright notice,
         this list of conditions and the following disclaimer.
      2. Redistributions in binary form must reproduce the above copyright notice,
         this list of conditions and the following disclaimer in the documentation
         and/or other materials provided with the distribution.
      3. Neither the name of the Snowball project nor the names of its contributors
         may be used to endorse or promote products derived from this software
         without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
    ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
    ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
    (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
    ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
    SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


    stopwords-iso (github.com/stopwords-iso)
    Stop word lists, used by the recommendation engine.

    The MIT License (MIT)

    Copyright (c) 2020 Gene Diaz

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

    FrequencyWords (github.com/hermitdave/FrequencyWords)
    Word frequency lists from OpenSubtitles 2018 (opus.nlpl.eu), by Hermit Dave.
    Used, trimmed to the most frequent words of each language, in resources/neuro/freq.
    Licensed under the Creative Commons Attribution-ShareAlike 4.0 International
    License (https://creativecommons.org/licenses/by-sa/4.0/). The trimmed lists are
    shared under the same license.

    Open Chinese Convert (github.com/BYVoid/OpenCC)
    The Traditional to Simplified character table in resources/neuro/fold is made from
    OpenCC's TSCharacters.txt. Copyright (c) the OpenCC authors. Licensed under the
    Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
    """
}

// MARK: - Header

/// The app mark, name and version, centred at the top of About.
///
/// The mark is drawn rather than loaded from the icon catalogue: `UIImage(named: "AppIcon")` does
/// not return the app icon at runtime, and a missing image would leave a hole where the logo is.
final class AboutHeaderView: UIView {

    private let mark = UIView()
    private let glyph = FlowIconView()
    private let nameLabel = UILabel()
    private let versionLabel = UILabel()

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

        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.applyCornerRadius(18.0)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.icon = .play
        glyph.iconSize = 36.0
        mark.addSubviewForAutoLayout(glyph)

        nameLabel.font = FlowTypography.headlineMedium
        nameLabel.text = "Flow"
        nameLabel.textAlignment = .center

        versionLabel.font = FlowTypography.bodyMedium
        versionLabel.textAlignment = .center

        // One element, so VoiceOver reads "Flow, version 1.0.0, build 1" instead of three fragments.
        isAccessibilityElement = true

        let stack = UIStackView(arrangedSubviews: [mark, nameLabel, versionLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = FlowSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.md),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.md),
            mark.widthAnchor.constraint(equalToConstant: 72.0),
            mark.heightAnchor.constraint(equalToConstant: 72.0),
            glyph.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 36.0),
            glyph.heightAnchor.constraint(equalToConstant: 36.0),
        ])
        applyTheme()
    }

    /// Sets the version line, in the Android app's `v%1$s (%2$s)` shape.
    func configure(version: String, build: String) {
        versionLabel.text = "v" + version + " (" + build + ")"
        accessibilityLabel = "Flow, version " + version + ", build " + build
    }

    /// Repaints the header in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        mark.backgroundColor = scheme.primary
        glyph.iconColor = scheme.onPrimary
        nameLabel.textColor = scheme.onSurface
        versionLabel.textColor = scheme.onSurfaceVariant
    }
}

// MARK: - Creator card

/// The creator, with their GitHub avatar over a fallback initial while the image loads.
final class AboutCreatorCard: UIControl {

    /// Called when the card is tapped.
    var onTap: (() -> Void)?

    private let avatar = AsyncImageView()
    private let avatarContainer = UIView()
    private let initialLabel = UILabel()
    private let overlineLabel = UILabel()
    private let nameLabel = UILabel()
    private let roleLabel = UILabel()
    private let chevron = FlowIconView()

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

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.contentMode = .scaleAspectFill
        avatar.applyCornerRadius(24.0)
        avatar.fadesIn = true

        initialLabel.font = FlowTypography.titleLarge
        initialLabel.text = "A"
        initialLabel.textAlignment = .center
        initialLabel.translatesAutoresizingMaskIntoConstraints = false

        avatarContainer.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.applyCornerRadius(24.0)
        avatarContainer.clipsToBounds = true
        avatarContainer.addSubviewForAutoLayout(initialLabel)
        avatarContainer.addSubviewForAutoLayout(avatar)

        overlineLabel.font = FlowTypography.labelMedium
        overlineLabel.text = "Creator"

        nameLabel.font = FlowTypography.titleMedium
        nameLabel.text = "A-EDev"

        roleLabel.font = FlowTypography.bodyMedium
        roleLabel.text = "Creator and developer of Flow"
        roleLabel.numberOfLines = 2

        chevron.icon = .chevronRight
        chevron.iconSize = 18.0
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 18.0).isActive = true
        chevron.heightAnchor.constraint(equalToConstant: 18.0).isActive = true

        let labels = UIStackView(arrangedSubviews: [overlineLabel, nameLabel, roleLabel])
        labels.axis = .vertical
        labels.spacing = FlowSpacing.xxs

        let row = UIStackView(arrangedSubviews: [avatarContainer, labels, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = FlowSpacing.lg
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.lg),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.lg),
            row.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.lg),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.lg),
            avatarContainer.widthAnchor.constraint(equalToConstant: 48.0),
            avatarContainer.heightAnchor.constraint(equalToConstant: 48.0),
            initialLabel.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            initialLabel.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
            avatar.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            avatar.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            avatar.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            avatar.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
        ])

        addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.onTap?()
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "A-EDev, creator and developer of Flow"
        applyTheme()
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.7 : 1.0
        }
    }

    /// Repaints the card and starts the avatar request.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = scheme.surfaceContainerHigh
        initialLabel.textColor = scheme.onSurfaceVariant
        overlineLabel.textColor = scheme.onSurfaceVariant
        nameLabel.textColor = scheme.onSurface
        roleLabel.textColor = scheme.onSurfaceVariant
        chevron.iconColor = scheme.onSurfaceVariant
        // The avatar's own placeholder is transparent so the initial shows through until the
        // picture arrives; the container behind it carries the tint.
        avatarContainer.backgroundColor = scheme.surfaceContainerHighest
        avatar.placeholderColor = .clear
        avatar.setImage(url: AboutViewController.Links.creatorAvatar)
    }
}

// MARK: - Licence

/// The GPL-3.0 notice: the copyright line, the grant and the warranty disclaimer, with a way to
/// read the full text. The licence itself is 600 lines of legal prose; the notice is what the
/// licence asks an app to show, and the full text stays one tap away.
final class LicenseViewController: SettingsListViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "License"
        table.topPadding = FlowSpacing.lg
    }

    override var sections: [SettingsSection] {
        return [
            SettingsSection(
                header: "GNU General Public License",
                footer: nil,
                rows: [
                    .custom(configure: { cell in
                        let text = AboutTextBlock()
                        text.configure(
                            title: "Version 3, 29 June 2007",
                            body: LicenseViewController.notice
                        )
                        cell.contentStack.addArrangedSubview(text)
                    }, action: nil),
                ]
            ),
            SettingsSection(
                header: "Copyright",
                footer: nil,
                rows: [
                    .detail(
                        icon: .notes,
                        title: "Flow",
                        subtitle: "Copyright © 2025-2026 A-EDev",
                        value: nil
                    ),
                ]
            ),
            SettingsSection(
                header: nil,
                footer: "This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.",
                rows: [
                    .nav(
                        "Read the full license",
                        icon: .exportIcon,
                        subtitle: "Opens on GitHub",
                        showsChevron: false,
                        action: { AboutViewController.openLink(AboutViewController.Links.license) }
                    ),
                ]
            ),
        ]
    }

    /// The GPL's "How to Apply These Terms" notice, with Flow's name in place of the placeholders.
    static let notice: String = """
    Flow is free software: you can redistribute it and/or modify it under the terms of the GNU \
    General Public License as published by the Free Software Foundation, either version 3 of the \
    License, or (at your option) any later version.

    Flow is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even \
    the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU \
    General Public License for more details.

    You should have received a copy of the GNU General Public License along with Flow. If not, see \
    <https://www.gnu.org/licenses/>.

    The source code is available at github.com/Flow-Tube/Flow. Any project that uses Flow's source \
    code, including the FlowNeuroEngine algorithm, must also be open source under the GPLv3.
    """
}

// MARK: - Text block

/// A titled paragraph inside a settings card, used for the licence notice.
final class AboutTextBlock: UIView {

    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()

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
        titleLabel.font = FlowTypography.titleMedium
        titleLabel.numberOfLines = 0
        bodyLabel.font = FlowTypography.bodyMedium
        bodyLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme()
    }

    /// Sets the heading and the paragraph under it.
    func configure(title: String, body: String) {
        titleLabel.text = title
        bodyLabel.text = body
        applyTheme()
    }

    /// Repaints the block in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        bodyLabel.textColor = scheme.onSurfaceVariant
    }
}

// MARK: - Text sheet

/// A sheet holding a long block of selectable text with a primary action and a close button.
/// Used for the third-party notices, which are too long for an alert.
final class AboutTextSheetContent: UIView {

    /// Called when the close button is tapped.
    var onClose: (() -> Void)?

    private let textView = UITextView()
    private let primaryButton = FlowButton.make("", style: .tonal)
    private let closeButton = FlowButton.make("Close", style: .text)

    /// A sheet lives over the screen, so it has to repaint itself: nothing reloads it.
    private var themeToken: ObservationToken?

    init(text: String, primaryTitle: String, primaryAction: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: FlowSpacing.md, left: 0, bottom: FlowSpacing.md, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.font = FlowTypography.bodySmall
        textView.text = text
        textView.alwaysBounceVertical = true
        // The notices are a wall of legal prose; the reader's text size should still win.
        textView.adjustsFontForContentSizeCategory = true

        primaryButton.configure(title: primaryTitle, style: .tonal, icon: .exportIcon)
        primaryButton.onTap = primaryAction

        closeButton.onTap = { [weak self] in
            self?.onClose?()
        }

        let buttons = UIStackView(arrangedSubviews: [primaryButton, closeButton])
        buttons.axis = .horizontal
        buttons.spacing = FlowSpacing.md
        buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubviewForAutoLayout(textView)
        addSubviewForAutoLayout(buttons)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -FlowSpacing.md),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.lg),
            buttons.heightAnchor.constraint(equalToConstant: 44.0),
        ])
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
    }

    deinit {
        themeToken?.cancelObservation()
    }

    /// Repaints the sheet in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        textView.textColor = scheme.onSurfaceVariant
        primaryButton.applyTheme()
        closeButton.applyTheme()
    }
}

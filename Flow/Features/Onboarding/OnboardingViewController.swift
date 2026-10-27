import UIKit

// MARK: - Topic catalogue

/// The interests the setup screen offers, grouped the way the Android catalogue groups them. The
/// names are the recommendation signal: they are written to `PrefsStore.Key.interests` and read back
/// by the feed's ranking, so a topic is a plain string rather than an enum that would have to be
/// migrated whenever the catalogue grows.
enum OnboardingTopicCatalog {

    struct Category {
        let name: String
        let icon: FlowIcon
        let topics: [String]
    }

    /// The fewest topics the viewer must pick before the feed can be personalised.
    static let minimumTopics = 3

    /// Picked artists share the interests preference with the topics, so they are stored with this
    /// prefix. The feed reads the topics; the music engine reads the prefixed ids.
    static let artistPrefix = "artist:"

    static let categories: [Category] = [
        Category(name: "Gaming", icon: .play, topics: [
            "Gaming", "Minecraft", "Fortnite", "GTA", "Call of Duty", "Valorant",
            "League of Legends", "Pokemon", "Nintendo", "PlayStation", "Xbox",
            "PC Gaming", "Esports", "Speedruns", "Game Reviews", "Indie Games",
            "Retro Gaming", "Mobile Games", "Roblox", "Apex Legends", "FIFA",
        ]),
        Category(name: "Music", icon: .music, topics: [
            "Music", "Pop Music", "Hip Hop", "R&B", "Rock", "Metal", "Jazz",
            "Classical", "Electronic", "EDM", "Lo-Fi", "K-Pop", "J-Pop", "Country",
            "Indie Music", "Music Production", "Guitar", "Piano", "Singing",
            "Music Theory", "Album Reviews", "Concerts", "DJ",
        ]),
        Category(name: "Technology", icon: .settings, topics: [
            "Technology", "Programming", "Coding", "Web Development", "App Development",
            "AI", "Machine Learning", "Cybersecurity", "Linux", "Apple", "Android",
            "Smartphones", "Laptops", "PC Building", "Tech Reviews", "Gadgets",
            "Software", "Cloud Computing", "Blockchain", "Crypto", "Startups",
        ]),
        Category(name: "Entertainment", icon: .playlist, topics: [
            "Movies", "TV Shows", "Netflix", "Anime", "Marvel", "DC", "Star Wars",
            "Disney", "Comedy", "Stand-up Comedy", "Drama", "Horror", "Sci-Fi",
            "Documentary", "Film Analysis", "Movie Reviews", "Behind the Scenes",
            "Celebrities", "Award Shows", "Trailers", "Fan Theories",
        ]),
        Category(name: "Education", icon: .library, topics: [
            "Science", "Physics", "Chemistry", "Biology", "Mathematics", "History",
            "Geography", "Psychology", "Philosophy", "Economics", "Finance",
            "Investing", "Business", "Marketing", "Language Learning", "English",
            "Spanish", "Study Tips", "College", "University", "Tutorials",
        ]),
        Category(name: "Health & Fitness", icon: .heart, topics: [
            "Fitness", "Workout", "Gym", "Yoga", "Running", "CrossFit",
            "Bodybuilding", "Weight Loss", "Nutrition", "Healthy Eating",
            "Mental Health", "Meditation", "Self Improvement", "Productivity",
            "Motivation", "Sports", "Basketball", "Football", "Soccer", "MMA",
            "Boxing", "Tennis", "Golf",
        ]),
        Category(name: "Lifestyle", icon: .home, topics: [
            "Cooking", "Recipes", "Baking", "Food", "Restaurants", "Travel",
            "Vlogging", "Daily Vlog", "Fashion", "Style", "Beauty", "Skincare",
            "Home Decor", "Interior Design", "DIY", "Crafts", "Gardening", "Pets",
            "Dogs", "Cats", "Cars", "Motorcycles", "Photography",
        ]),
        Category(name: "Creative", icon: .edit, topics: [
            "Art", "Drawing", "Painting", "Digital Art", "Animation", "3D Modeling",
            "Graphic Design", "Video Editing", "Filmmaking", "Writing",
            "Storytelling", "Architecture", "Fashion Design", "Woodworking",
            "Sculpture",
        ]),
        Category(name: "Science & Nature", icon: .search, topics: [
            "Space", "Astronomy", "NASA", "Nature", "Animals", "Wildlife", "Ocean",
            "Marine Life", "Environment", "Climate", "Geology", "Paleontology",
            "Dinosaurs", "Engineering", "Inventions", "Experiments",
        ]),
        Category(name: "News & Current Events", icon: .notification, topics: [
            "News", "Politics", "World News", "Tech News", "Sports News",
            "Entertainment News", "Business News", "Analysis", "Commentary",
            "Podcasts", "Interviews", "Debates", "Current Events",
        ]),
    ]
}

// MARK: - Wrapping chip layout

/// Lays its subviews out left to right, wrapping to a new line when the next one would overflow.
/// Material's chip cloud has no UIKit equivalent on iOS 12, and a collection view would need a
/// self-sizing flow layout for what is a handful of chips.
final class FlowWrapView: UIView {

    var horizontalSpacing: CGFloat = FlowSpacing.md
    var verticalSpacing: CGFloat = FlowSpacing.md

    private(set) var arrangedSubviews: [UIView] = []
    private var measuredHeight: CGFloat = 0.0

    /// Replaces the content. The caller keeps ownership of the views it passes in.
    func setViews(_ views: [UIView]) {
        for view in arrangedSubviews {
            view.removeFromSuperview()
        }
        arrangedSubviews = views
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        measuredHeight = 0.0
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = layout(in: bounds.width, apply: true)
        if abs(height - measuredHeight) > 0.5 {
            measuredHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: UIViewNoIntrinsicMetric, height: measuredHeight)
    }

    @discardableResult
    private func layout(in width: CGFloat, apply: Bool) -> CGFloat {
        guard width > 0.0 else { return measuredHeight }
        var x: CGFloat = 0.0
        var y: CGFloat = 0.0
        var rowHeight: CGFloat = 0.0
        for view in arrangedSubviews {
            let size = view.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .fittingSizeLevel,
                verticalFittingPriority: .fittingSizeLevel
            )
            let itemWidth = min(size.width, width)
            let itemHeight = size.height
            if x > 0.0 && x + itemWidth > width {
                x = 0.0
                y += rowHeight + verticalSpacing
                rowHeight = 0.0
            }
            if apply {
                view.frame = CGRect(x: x, y: y, width: itemWidth, height: itemHeight)
            }
            x += itemWidth + horizontalSpacing
            rowHeight = max(rowHeight, itemHeight)
        }
        return arrangedSubviews.isEmpty ? 0.0 : y + rowHeight
    }
}

// MARK: - Progress

/// The segmented bar at the top of setup. The current step's segment is drawn wider than the rest,
/// which is how the Android scaffold shows "you are here" without a second label.
final class OnboardingProgressView: UIView {

    private var stepCount = 4
    private var currentIndex = 0
    private let currentWeight: CGFloat = 2.4

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = true
    }

    func configure(stepCount: Int, currentIndex: Int) {
        self.stepCount = max(stepCount, 1)
        self.currentIndex = min(max(currentIndex, 0), self.stepCount - 1)
        accessibilityLabel = "Step " + String(self.currentIndex + 1) + " of " + String(self.stepCount)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), stepCount > 0 else { return }
        let scheme = FlowTheme.shared.scheme
        let gap: CGFloat = 6.0
        let totalGap = gap * CGFloat(stepCount - 1)
        var weights: [CGFloat] = []
        for index in 0..<stepCount {
            weights.append(index == currentIndex ? currentWeight : 1.0)
        }
        let weightSum = weights.reduce(0.0, +)
        let usable = max(rect.width - totalGap, 0.0)
        var x = rect.minX
        context.saveGState()
        for index in 0..<stepCount {
            let width = usable * (weights[index] / weightSum)
            let segment = CGRect(x: x, y: rect.minY, width: width, height: rect.height)
            let path = UIBezierPath(roundedRect: segment, cornerRadius: rect.height / 2.0)
            if index <= currentIndex {
                scheme.primary.setFill()
            } else {
                scheme.surfaceContainerHighest.setFill()
            }
            path.fill()
            x += width + gap
        }
        context.restoreGState()
    }
}

// MARK: - Page scaffolding

/// One page of the setup pager: a vertical scroll view with a stack inside it. The pager scrolls
/// horizontally, each page scrolls vertically, and the two axes never fight.
class OnboardingPageView: UIView {

    let scrollView = UIScrollView()
    let contentStack = UIStackView()

    /// Labels the page created, with the colour role each one uses, so a palette change repaints
    /// them without every page keeping its own list.
    private var themedLabels: [(label: UILabel, usesPrimaryText: Bool)] = []

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
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = FlowSpacing.xl
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: FlowSpacing.xxl),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -FlowSpacing.xxl),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: FlowSpacing.lg),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -FlowSpacing.xxl),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -FlowSpacing.xxl * 2.0),
        ])
    }

    /// Adds the title and subtitle every step opens with.
    func addHeader(title: String, subtitle: String) {
        let titleLabel = UILabel.flow(title, font: FlowTypography.headlineMedium, color: FlowTheme.shared.onSurface, lines: 0)
        titleLabel.accessibilityTraits = .header
        let subtitleLabel = UILabel.flow(subtitle, font: FlowTypography.bodyLarge, color: FlowTheme.shared.onSurfaceVariant, lines: 0)
        themedLabels.append((titleLabel, true))
        themedLabels.append((subtitleLabel, false))
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(subtitleLabel)
        contentStack.setCustomSpacing(FlowSpacing.md, after: titleLabel)
    }

    /// Adds a small caption above a group of controls.
    func addSectionTitle(_ text: String) {
        let label = UILabel.flow(text, font: FlowTypography.titleSmall, color: FlowTheme.shared.onSurfaceVariant, lines: 0)
        label.accessibilityTraits = .header
        themedLabels.append((label, false))
        contentStack.addArrangedSubview(label)
    }

    /// Repaints the header labels. Subclasses call this from their own `applyTheme`.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        for entry in themedLabels {
            entry.label.textColor = entry.usesPrimaryText ? scheme.onSurface : scheme.onSurfaceVariant
        }
    }
}

// MARK: - Interests page

/// The topic cloud. Every category is a labelled block of chips; the hint under the title tells the
/// viewer how many more they need, which is the only gate on this step.
final class OnboardingInterestsPage: OnboardingPageView {

    /// Called whenever the selection changes, so the controller can update the bottom bar.
    var onChange: ((Set<String>) -> Void)?

    private(set) var selectedTopics: Set<String> = []
    private var chips: [String: FlowChip] = [:]
    private var categoryHeaders: [(icon: FlowIconView, label: UILabel)] = []
    private let hintLabel = UILabel()

    func build() {
        addHeader(
            title: "What do you enjoy?",
            subtitle: "Pick at least " + String(OnboardingTopicCatalog.minimumTopics)
                + " topics to personalise your feed."
        )

        hintLabel.font = FlowTypography.bodyMedium
        hintLabel.numberOfLines = 0
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(hintLabel)

        for category in OnboardingTopicCatalog.categories {
            let section = UIStackView()
            section.axis = .vertical
            section.spacing = FlowSpacing.md

            let header = UIStackView()
            header.axis = .horizontal
            header.spacing = FlowSpacing.sm
            header.alignment = .center
            let icon = FlowIconView.make(category.icon, color: FlowTheme.shared.onSurfaceVariant, size: 18.0)
            let label = UILabel.flow(category.name, font: FlowTypography.titleMedium, color: FlowTheme.shared.onSurface, lines: 1)
            categoryHeaders.append((icon, label))
            header.addArrangedSubview(icon)
            header.addArrangedSubview(label)
            section.addArrangedSubview(header)

            let wrap = FlowWrapView()
            wrap.horizontalSpacing = FlowSpacing.md
            wrap.verticalSpacing = FlowSpacing.md
            wrap.translatesAutoresizingMaskIntoConstraints = false
            var views: [UIView] = []
            for topic in category.topics {
                let chip = FlowChip.make(topic, selected: selectedTopics.contains(topic))
                chip.onTap = { [weak self] in
                    self?.toggle(topic)
                }
                chips[topic] = chip
                views.append(chip)
            }
            wrap.setViews(views)
            section.addArrangedSubview(wrap)
            contentStack.addArrangedSubview(section)
            contentStack.setCustomSpacing(FlowSpacing.xxl, after: section)
        }
        updateHint()
    }

    func configure(selected: Set<String>) {
        selectedTopics = selected
        for (topic, chip) in chips {
            chip.setSelected(selectedTopics.contains(topic), animated: false)
        }
        updateHint()
    }

    private func toggle(_ topic: String) {
        if selectedTopics.contains(topic) {
            selectedTopics.remove(topic)
        } else {
            selectedTopics.insert(topic)
        }
        chips[topic]?.setSelected(selectedTopics.contains(topic), animated: true)
        updateHint()
        onChange?(selectedTopics)
    }

    private func updateHint() {
        let remaining = max(OnboardingTopicCatalog.minimumTopics - selectedTopics.count, 0)
        let scheme = FlowTheme.shared.scheme
        if remaining == 0 {
            hintLabel.text = "Great selection. You can always update this later in settings."
            hintLabel.textColor = scheme.primary
        } else if selectedTopics.isEmpty {
            hintLabel.text = "Pick at least " + String(OnboardingTopicCatalog.minimumTopics) + " topics."
            hintLabel.textColor = scheme.onSurfaceVariant
        } else {
            hintLabel.text = String(remaining) + " more to go."
            hintLabel.textColor = scheme.onSurfaceVariant
        }
    }

    override func applyTheme() {
        super.applyTheme()
        let scheme = FlowTheme.shared.scheme
        for entry in categoryHeaders {
            entry.icon.iconColor = scheme.onSurfaceVariant
            entry.label.textColor = scheme.onSurface
        }
        for chip in chips.values {
            chip.applyTheme()
        }
        updateHint()
    }
}

// MARK: - Channel row

/// One search result in the channels step: avatar, name, subscriber count and a subscribe toggle.
final class OnboardingChannelRow: UIView {

    var onToggle: (() -> Void)?

    private let avatar = AsyncImageView.make(contentMode: .scaleAspectFill, cornerRadius: 22.0)
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let actionButton = FlowButton.make("Subscribe", style: .tonal)

    private(set) var channelId: String = ""
    private(set) var isSubscribed = false

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
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.clipsToBounds = true
        avatar.backgroundColor = FlowTheme.shared.scheme.surfaceContainerHigh

        nameLabel.font = FlowTypography.titleMedium
        nameLabel.numberOfLines = 1
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 1

        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.onTap = { [weak self] in
            self?.onToggle?()
        }

        let textStack = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = FlowSpacing.xxs
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(avatar)
        addSubview(textStack)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60.0),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 44.0),
            avatar.heightAnchor.constraint(equalToConstant: 44.0),

            textStack.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: FlowSpacing.lg),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: FlowSpacing.sm),

            actionButton.leadingAnchor.constraint(equalTo: textStack.trailingAnchor, constant: FlowSpacing.lg),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 104.0),
        ])
        applyTheme()
    }

    func configure(channel: Channel, subscribed: Bool) {
        channelId = channel.id
        isSubscribed = subscribed
        avatar.setImage(url: channel.thumbnailUrl)
        nameLabel.text = channel.name
        let count = channel.subscriberCountText.isEmpty
            ? Formatters.subscriberCount(Int(channel.subscriberCount))
            : channel.subscriberCountText
        detailLabel.text = count
        updateAction()
    }

    func setSubscribed(_ subscribed: Bool) {
        isSubscribed = subscribed
        updateAction()
    }

    private func updateAction() {
        actionButton.configure(
            title: isSubscribed ? "Subscribed" : "Subscribe",
            style: isSubscribed ? .text : .tonal,
            icon: isSubscribed ? .check : nil
        )
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        nameLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        avatar.backgroundColor = scheme.surfaceContainerHigh
        actionButton.applyTheme()
    }
}

// MARK: - Channels page

final class OnboardingChannelsPage: OnboardingPageView, UITextFieldDelegate {

    /// Called with the channel the viewer subscribed to or unsubscribed from.
    var onToggle: ((Channel, Bool) -> Void)?

    private let searchField = UITextField()
    private let searchContainer = UIView()
    private let resultsStack = UIStackView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let debouncer = FlowDebouncer(interval: 0.4)

    private var rows: [String: OnboardingChannelRow] = [:]
    private var results: [Channel] = []
    private var subscribedIds: Set<String> = []
    private var isSearching = false

    func build() {
        addHeader(
            title: "Find channels",
            subtitle: "Search for channels you already follow and subscribe in one tap."
        )

        searchContainer.backgroundColor = FlowTheme.shared.scheme.surfaceContainerHigh
        searchContainer.layer.cornerRadius = FlowShapes.pill(for: 48.0)
        searchContainer.translatesAutoresizingMaskIntoConstraints = false

        let glyph = FlowIconView.make(.search, color: FlowTheme.shared.onSurfaceVariant, size: 20.0)
        glyph.translatesAutoresizingMaskIntoConstraints = false

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = FlowTypography.bodyLarge
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        searchField.placeholder = "Search channels…"
        searchField.addTarget(self, action: #selector(handleEditingChanged), for: .editingChanged)

        searchContainer.addSubview(glyph)
        searchContainer.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchContainer.heightAnchor.constraint(equalToConstant: 48.0),
            glyph.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: FlowSpacing.xl),
            glyph.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: FlowSpacing.md),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -FlowSpacing.xl),
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor),
        ])
        contentStack.addArrangedSubview(searchContainer)

        statusLabel.font = FlowTypography.bodyMedium
        statusLabel.numberOfLines = 0
        statusLabel.text = "Type a channel name to search"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(statusLabel)

        spinner.hidesWhenStopped = true
        contentStack.addArrangedSubview(spinner)

        resultsStack.axis = .vertical
        resultsStack.spacing = FlowSpacing.md
        contentStack.addArrangedSubview(resultsStack)
        applyTheme()
    }

    func configure(subscribedIds: Set<String>) {
        self.subscribedIds = subscribedIds
        for (channelId, row) in rows {
            row.setSubscribed(subscribedIds.contains(channelId))
        }
    }

    override func applyTheme() {
        super.applyTheme()
        let scheme = FlowTheme.shared.scheme
        searchContainer.backgroundColor = scheme.surfaceContainerHigh
        searchField.textColor = scheme.onSurface
        searchField.attributedPlaceholder = NSAttributedString(
            string: "Search channels…",
            attributes: [.foregroundColor: scheme.onSurfaceVariant]
        )
        statusLabel.textColor = scheme.onSurfaceVariant
        for row in rows.values {
            row.applyTheme()
        }
    }

    // MARK: - Searching

    @objc private func handleEditingChanged() {
        debouncer.schedule { [weak self] in
            self?.search()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        debouncer.cancel()
        search()
        return true
    }

    private func search() {
        let query = (searchField.text ?? "").trimmed
        guard !query.isEmpty else {
            results = []
            rebuildRows()
            statusLabel.text = "Type a channel name to search"
            statusLabel.isHidden = false
            spinner.stopAnimating()
            return
        }
        guard !isSearching else { return }
        isSearching = true
        statusLabel.isHidden = true
        spinner.startAnimating()
        FlowApp.shared.youtubeAPI.search(query: query, filter: .channels) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isSearching = false
                self.spinner.stopAnimating()
                switch result {
                case .success(let page):
                    self.results = Array(page.channels.prefix(20))
                    self.rebuildRows()
                    if self.results.isEmpty {
                        self.statusLabel.text = "No channels found for \"" + query + "\""
                        self.statusLabel.isHidden = false
                    }
                case .failure(let error):
                    self.results = []
                    self.rebuildRows()
                    self.statusLabel.text = error.displayMessage
                    self.statusLabel.isHidden = false
                }
            }
        }
    }

    private func rebuildRows() {
        for view in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows.removeAll()
        for channel in results {
            let row = OnboardingChannelRow()
            row.configure(channel: channel, subscribed: subscribedIds.contains(channel.id))
            row.onToggle = { [weak self] in
                guard let self = self else { return }
                let next = !self.subscribedIds.contains(channel.id)
                if next {
                    self.subscribedIds.insert(channel.id)
                } else {
                    self.subscribedIds.remove(channel.id)
                }
                row.setSubscribed(next)
                self.onToggle?(channel, next)
            }
            rows[channel.id] = row
            resultsStack.addArrangedSubview(row)
        }
    }
}

// MARK: - Artist row

final class OnboardingArtistRow: UIView {

    var onToggle: (() -> Void)?

    private let avatar = AsyncImageView.make(contentMode: .scaleAspectFill, cornerRadius: 24.0)
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let checkView = FlowIconView()

    private(set) var artistId: String = ""
    private(set) var isPicked = false

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
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.clipsToBounds = true
        avatar.backgroundColor = FlowTheme.shared.scheme.surfaceContainerHigh

        nameLabel.font = FlowTypography.titleMedium
        nameLabel.numberOfLines = 1
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 1

        checkView.iconSize = 22.0
        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.widthAnchor.constraint(equalToConstant: 22.0).isActive = true
        checkView.heightAnchor.constraint(equalToConstant: 22.0).isActive = true

        let textStack = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = FlowSpacing.xxs
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(avatar)
        addSubview(textStack)
        addSubview(checkView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60.0),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 48.0),
            avatar.heightAnchor.constraint(equalToConstant: 48.0),

            textStack.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: FlowSpacing.lg),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: checkView.leadingAnchor, constant: -FlowSpacing.md),

            checkView.trailingAnchor.constraint(equalTo: trailingAnchor),
            checkView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
        accessibilityTraits = .button
        applyTheme()
    }

    func configure(artist: ArtistItem, picked: Bool) {
        artistId = artist.id
        isPicked = picked
        avatar.setImage(url: artist.thumbnailUrl)
        nameLabel.text = artist.title
        detailLabel.text = artist.subscriberCountText ?? "Artist"
        updateCheck()
    }

    func setPicked(_ picked: Bool) {
        isPicked = picked
        updateCheck()
    }

    private func updateCheck() {
        checkView.icon = isPicked ? .check : .add
        checkView.iconColor = isPicked ? FlowTheme.shared.primary : FlowTheme.shared.onSurfaceVariant
        accessibilityLabel = nameLabel.text
        accessibilityValue = isPicked ? "Selected" : "Not selected"
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        nameLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        avatar.backgroundColor = scheme.surfaceContainerHigh
        updateCheck()
    }

    @objc private func handleTap() {
        onToggle?()
    }
}

// MARK: - Artists page

final class OnboardingArtistsPage: OnboardingPageView, UITextFieldDelegate {

    var onChange: ((Set<String>) -> Void)?

    private let searchField = UITextField()
    private let searchContainer = UIView()
    private let resultsStack = UIStackView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let debouncer = FlowDebouncer(interval: 0.4)

    private var rows: [String: OnboardingArtistRow] = [:]
    private var pickedIds: Set<String> = []
    private var results: [ArtistItem] = []
    private var isSearching = false

    func build() {
        addHeader(
            title: "Artists you love",
            subtitle: "Optional. Your music recommendations start from the artists you pick here."
        )

        searchContainer.backgroundColor = FlowTheme.shared.scheme.surfaceContainerHigh
        searchContainer.layer.cornerRadius = FlowShapes.pill(for: 48.0)
        searchContainer.translatesAutoresizingMaskIntoConstraints = false

        let glyph = FlowIconView.make(.search, color: FlowTheme.shared.onSurfaceVariant, size: 20.0)
        glyph.translatesAutoresizingMaskIntoConstraints = false

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = FlowTypography.bodyLarge
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        searchField.placeholder = "Search artists…"
        searchField.addTarget(self, action: #selector(handleEditingChanged), for: .editingChanged)

        searchContainer.addSubview(glyph)
        searchContainer.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchContainer.heightAnchor.constraint(equalToConstant: 48.0),
            glyph.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: FlowSpacing.xl),
            glyph.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: FlowSpacing.md),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -FlowSpacing.xl),
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor),
        ])
        contentStack.addArrangedSubview(searchContainer)

        statusLabel.font = FlowTypography.bodyMedium
        statusLabel.numberOfLines = 0
        statusLabel.text = "Type an artist's name to search"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(statusLabel)

        spinner.hidesWhenStopped = true
        contentStack.addArrangedSubview(spinner)

        resultsStack.axis = .vertical
        resultsStack.spacing = FlowSpacing.md
        contentStack.addArrangedSubview(resultsStack)
        applyTheme()
    }

    func configure(pickedIds: Set<String>) {
        self.pickedIds = pickedIds
        for (artistId, row) in rows {
            row.setPicked(pickedIds.contains(artistId))
        }
    }

    override func applyTheme() {
        super.applyTheme()
        let scheme = FlowTheme.shared.scheme
        searchContainer.backgroundColor = scheme.surfaceContainerHigh
        searchField.textColor = scheme.onSurface
        searchField.attributedPlaceholder = NSAttributedString(
            string: "Search artists…",
            attributes: [.foregroundColor: scheme.onSurfaceVariant]
        )
        statusLabel.textColor = scheme.onSurfaceVariant
        for row in rows.values {
            row.applyTheme()
        }
    }

    @objc private func handleEditingChanged() {
        debouncer.schedule { [weak self] in
            self?.search()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        debouncer.cancel()
        search()
        return true
    }

    private func search() {
        let query = (searchField.text ?? "").trimmed
        guard !query.isEmpty else {
            results = []
            rebuildRows()
            statusLabel.text = "Type an artist's name to search"
            statusLabel.isHidden = false
            spinner.stopAnimating()
            return
        }
        guard !isSearching else { return }
        isSearching = true
        statusLabel.isHidden = true
        spinner.startAnimating()
        FlowApp.shared.youtubeAPI.musicSearch(query: query, filter: .artists) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isSearching = false
                self.spinner.stopAnimating()
                switch result {
                case .success(let page):
                    var artists: [ArtistItem] = []
                    for item in page.items {
                        if case .artist(let artist) = item {
                            artists.append(artist)
                        }
                    }
                    self.results = Array(artists.prefix(20))
                    self.rebuildRows()
                    if self.results.isEmpty {
                        self.statusLabel.text = "No artists found for \"" + query + "\""
                        self.statusLabel.isHidden = false
                    }
                case .failure(let error):
                    self.results = []
                    self.rebuildRows()
                    self.statusLabel.text = error.displayMessage
                    self.statusLabel.isHidden = false
                }
            }
        }
    }

    private func rebuildRows() {
        for view in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows.removeAll()
        for artist in results {
            let row = OnboardingArtistRow()
            row.configure(artist: artist, picked: pickedIds.contains(artist.id))
            row.onToggle = { [weak self] in
                guard let self = self else { return }
                if self.pickedIds.contains(artist.id) {
                    self.pickedIds.remove(artist.id)
                } else {
                    self.pickedIds.insert(artist.id)
                }
                row.setPicked(self.pickedIds.contains(artist.id))
                self.onChange?(self.pickedIds)
            }
            rows[artist.id] = row
            resultsStack.addArrangedSubview(row)
        }
    }
}

// MARK: - Import tile

/// One app a viewer can bring subscriptions from. Shows a check once that source has been imported.
final class OnboardingImportTile: UIControl {

    var onTap: (() -> Void)?

    private let iconView = FlowIconView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let checkView = FlowIconView()
    private let container = UIView()

    private(set) var sourceId: String = ""
    private(set) var isImported = false

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
        container.layer.cornerRadius = FlowShapes.large
        container.isUserInteractionEnabled = false
        addSubview(container)

        iconView.iconSize = 26.0
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 26.0).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 26.0).isActive = true

        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 3

        checkView.iconSize = 18.0
        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.widthAnchor.constraint(equalToConstant: 18.0).isActive = true
        checkView.heightAnchor.constraint(equalToConstant: 18.0).isActive = true
        checkView.isHidden = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = FlowSpacing.xs
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.isUserInteractionEnabled = false

        container.addSubview(iconView)
        container.addSubview(textStack)
        container.addSubview(checkView)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 132.0),

            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: FlowSpacing.xl),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: FlowSpacing.xl),

            checkView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -FlowSpacing.xl),
            checkView.topAnchor.constraint(equalTo: container.topAnchor, constant: FlowSpacing.xl),

            textStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: FlowSpacing.xl),
            textStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -FlowSpacing.xl),
            textStack.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: FlowSpacing.lg),
            textStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -FlowSpacing.xl),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        accessibilityTraits = .button
        applyTheme()
    }

    func configure(sourceId: String, icon: FlowIcon, title: String, detail: String, imported: Bool) {
        self.sourceId = sourceId
        self.isImported = imported
        iconView.icon = icon
        titleLabel.text = title
        detailLabel.text = detail
        checkView.isHidden = !imported
        accessibilityLabel = title
        accessibilityValue = imported ? "Imported" : nil
    }

    func setImported(_ imported: Bool) {
        isImported = imported
        checkView.isHidden = !imported
        accessibilityValue = imported ? "Imported" : nil
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        container.backgroundColor = scheme.surfaceContainerHigh
        iconView.iconColor = scheme.primary
        titleLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        checkView.icon = .check
        checkView.iconColor = scheme.primary
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.75 : 1.0
        }
    }

    @objc private func handleTap() {
        onTap?()
    }
}

// MARK: - Import page

/// The last step: bring subscriptions in from another app. Everything here is optional, and the
/// same imports are available later from Settings.
final class OnboardingImportPage: OnboardingPageView {

    /// Called with the source identifier once an import has finished.
    var onImported: ((String) -> Void)?
    /// Called with a message when an import fails.
    var onFailure: ((String) -> Void)?

    private var tiles: [String: OnboardingImportTile] = [:]
    private var importedIds: Set<String> = []
    private let footnote = UILabel()
    private var pendingSourceId: String?

    func build() {
        addHeader(
            title: "Import your data",
            subtitle: "Bring your subscriptions and history from other apps. Everything is optional."
        )

        let grid = UIStackView()
        grid.axis = .horizontal
        grid.distribution = .fillEqually
        grid.spacing = FlowSpacing.lg

        let flowTile = OnboardingImportTile()
        flowTile.configure(
            sourceId: "flow",
            icon: .sync,
            title: "Flow backup",
            detail: "Restore a Flow backup file (.zip).",
            imported: false
        )
        flowTile.onTap = { [weak self] in
            self?.pickFile(for: "flow")
        }

        let newPipeTile = OnboardingImportTile()
        newPipeTile.configure(
            sourceId: "newpipe",
            icon: .importIcon,
            title: "NewPipe",
            detail: "Import subscriptions from a NewPipe export (.json).",
            imported: false
        )
        newPipeTile.onTap = { [weak self] in
            self?.pickFile(for: "newpipe")
        }

        tiles["flow"] = flowTile
        tiles["newpipe"] = newPipeTile
        grid.addArrangedSubview(flowTile)
        grid.addArrangedSubview(newPipeTile)
        contentStack.addArrangedSubview(grid)

        footnote.font = FlowTypography.bodySmall
        footnote.numberOfLines = 0
        footnote.text = "Everything here is optional. Settings has the same imports."
        footnote.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(footnote)
        applyTheme()
    }

    func configure(importedIds: Set<String>) {
        self.importedIds = importedIds
        for (sourceId, tile) in tiles {
            tile.setImported(importedIds.contains(sourceId))
        }
    }

    override func applyTheme() {
        super.applyTheme()
        footnote.textColor = FlowTheme.shared.scheme.onSurfaceVariant
        for tile in tiles.values {
            tile.applyTheme()
        }
    }

    // MARK: - Picking and importing

    /// The controller that owns this page, found through the responder chain. A page inside the
    /// pager has no presentation context of its own.
    private var hostController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    private func pickFile(for sourceId: String) {
        guard let host = hostController else { return }
        pendingSourceId = sourceId
        let types: [String] = sourceId == "flow"
            ? ["public.zip-archive", "public.data"]
            : ["public.json", "public.text"]
        let picker = UIDocumentPickerViewController(documentTypes: types, in: .import)
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        host.flowTopMost.present(picker, animated: true, completion: nil)
    }

    private func importFlowBackup(at url: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let archive = try FlowBackupArchive.decode(zipData: data)
                let applied = archive.apply(merge: true)
                let total = applied.subscriptions + applied.history + applied.playlists + applied.notes
                DispatchQueue.main.async {
                    completion(.success(total))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func importNewPipe(at url: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let entries = try NewPipeSubscriptionCodec.decode(data: data)
                var imported = 0
                for entry in entries {
                    guard let channelId = entry.channelId, !channelId.isEmpty else { continue }
                    SubscriptionStore.shared.subscribe(
                        channelId: channelId,
                        name: entry.name.isEmpty ? channelId : entry.name,
                        avatarUrl: "",
                        subscriberCount: 0
                    )
                    imported += 1
                }
                DispatchQueue.main.async {
                    completion(.success(imported))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}

extension OnboardingImportPage: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let sourceId = pendingSourceId else { return }
        pendingSourceId = nil
        let finish: (Result<Int, Error>) -> Void = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let count):
                self.importedIds.insert(sourceId)
                self.tiles[sourceId]?.setImported(true)
                self.onImported?(sourceId)
                FlowSnackbar.show(count == 1 ? "1 item imported" : String(count) + " items imported")
            case .failure(let error):
                self.onFailure?(error.localizedDescription)
                FlowSnackbar.showError("Import failed: " + error.localizedDescription)
            }
        }
        if sourceId == "flow" {
            importFlowBackup(at: url, completion: finish)
        } else {
            importNewPipe(at: url, completion: finish)
        }
    }
}

// MARK: - Onboarding

/// The first-run flow: four steps — interests, channels, artists, import — in a horizontally paged
/// scroll view, with a segmented progress bar, a skip that finishes immediately, and a completion
/// flag written to `PrefsStore` so the flow never runs twice.
///
/// The step index is persisted as well, so a viewer who is interrupted mid-setup returns to the
/// step they were on rather than to the beginning.
final class OnboardingViewController: UIViewController, UIScrollViewDelegate {

    /// Called once the flow finishes, whether the viewer completed it or skipped it.
    var onFinished: (() -> Void)?

    // MARK: - State

    private let pager = UIScrollView()
    private let pagesStack = UIStackView()
    private let topBar = UIView()
    private let progressView = OnboardingProgressView()
    private let skipButton = FlowButton.make("Skip", style: .text)
    private let bottomBar = UIView()
    private let backButton = FlowButton.makeIcon(.back, style: .tonal)
    private let continueButton = FlowButton.make("Continue", style: .filled)

    private let interestsPage = OnboardingInterestsPage()
    private let channelsPage = OnboardingChannelsPage()
    private let artistsPage = OnboardingArtistsPage()
    private let importPage = OnboardingImportPage()

    private var pages: [OnboardingPageView] = []
    private var currentIndex = 0
    private var themeToken: ObservationToken?

    private var selectedTopics: Set<String> = []
    private var subscribedIds: Set<String> = []
    private var pickedArtistIds: Set<String> = []
    private var importedSourceIds: Set<String> = []

    private let stepCount = 4

    deinit {
        themeToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        restoreState()
        buildTopBar()
        buildPager()
        buildBottomBar()
        bindPages()
        applyTheme()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        showStep(currentIndex, animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - State

    private func restoreState() {
        let prefs = FlowApp.shared.prefs
        let stored = prefs.stringArray(for: .interests)
        selectedTopics = Set(stored.filter { !$0.hasPrefix(OnboardingTopicCatalog.artistPrefix) })
        pickedArtistIds = Set(
            stored
                .filter { $0.hasPrefix(OnboardingTopicCatalog.artistPrefix) }
                .map { String($0.dropFirst(OnboardingTopicCatalog.artistPrefix.count)) }
        )
        currentIndex = min(max(prefs.int(for: .onboardingStep, fallback: 0), 0), stepCount - 1)
        // The channels step works on the live subscription list, so a channel followed on a previous
        // run shows as subscribed without a second store.
        subscribedIds = Set(FlowApp.shared.subscriptionStore.all.map { $0.channelId })
    }

    private func persistState() {
        let prefs = FlowApp.shared.prefs
        var interests = Array(selectedTopics).sorted()
        for artistId in pickedArtistIds.sorted() {
            interests.append(OnboardingTopicCatalog.artistPrefix + artistId)
        }
        prefs.set(interests, for: .interests)
        prefs.set(currentIndex, for: .onboardingStep)
    }

    // MARK: - Build

    private func buildTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(progressView)

        skipButton.translatesAutoresizingMaskIntoConstraints = false
        skipButton.onTap = { [weak self] in
            self?.finish()
        }
        topBar.addSubview(skipButton)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 56.0),

            progressView.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: FlowSpacing.xxl),
            progressView.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 6.0),
            progressView.trailingAnchor.constraint(equalTo: skipButton.leadingAnchor, constant: -FlowSpacing.lg),

            skipButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -FlowSpacing.md),
            skipButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])
    }

    private func buildPager() {
        pager.translatesAutoresizingMaskIntoConstraints = false
        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.showsVerticalScrollIndicator = false
        pager.alwaysBounceHorizontal = true
        pager.alwaysBounceVertical = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.delegate = self
        view.addSubview(pager)

        pagesStack.axis = .horizontal
        pagesStack.distribution = .fill
        pagesStack.alignment = .fill
        pagesStack.translatesAutoresizingMaskIntoConstraints = false
        pager.addSubview(pagesStack)

        pages = [interestsPage, channelsPage, artistsPage, importPage]
        for page in pages {
            pagesStack.addArrangedSubview(page)
            page.widthAnchor.constraint(equalTo: pager.frameLayoutGuide.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            pager.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            pager.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            pagesStack.leadingAnchor.constraint(equalTo: pager.contentLayoutGuide.leadingAnchor),
            pagesStack.trailingAnchor.constraint(equalTo: pager.contentLayoutGuide.trailingAnchor),
            pagesStack.topAnchor.constraint(equalTo: pager.contentLayoutGuide.topAnchor),
            pagesStack.bottomAnchor.constraint(equalTo: pager.contentLayoutGuide.bottomAnchor),
            pagesStack.heightAnchor.constraint(equalTo: pager.frameLayoutGuide.heightAnchor),
        ])
    }

    private func buildBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.accessibilityLabel = "Back"
        backButton.onTap = { [weak self] in
            self?.goBack()
        }
        bottomBar.addSubview(backButton)

        continueButton.translatesAutoresizingMaskIntoConstraints = false
        continueButton.onTap = { [weak self] in
            self?.goForward()
        }
        bottomBar.addSubview(continueButton)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            backButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: FlowSpacing.xl),
            backButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: FlowSpacing.md),
            backButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: -FlowSpacing.md),
            backButton.widthAnchor.constraint(equalToConstant: 56.0),
            backButton.heightAnchor.constraint(equalToConstant: 48.0),

            continueButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: FlowSpacing.lg),
            continueButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -FlowSpacing.xl),
            continueButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: FlowSpacing.md),
            continueButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: -FlowSpacing.md),
            continueButton.heightAnchor.constraint(equalToConstant: 48.0),
        ])
    }

    private func bindPages() {
        interestsPage.build()
        channelsPage.build()
        artistsPage.build()
        importPage.build()

        interestsPage.configure(selected: selectedTopics)
        channelsPage.configure(subscribedIds: subscribedIds)
        artistsPage.configure(pickedIds: pickedArtistIds)
        importPage.configure(importedIds: importedSourceIds)

        interestsPage.onChange = { [weak self] topics in
            guard let self = self else { return }
            self.selectedTopics = topics
            self.persistState()
            self.updateBottomBar()
        }
        channelsPage.onToggle = { [weak self] channel, subscribed in
            guard let self = self else { return }
            if subscribed {
                FlowApp.shared.subscriptionStore.subscribe(
                    channelId: channel.id,
                    name: channel.name,
                    avatarUrl: channel.thumbnailUrl,
                    subscriberCount: Int(channel.subscriberCount)
                )
                self.subscribedIds.insert(channel.id)
            } else {
                FlowApp.shared.subscriptionStore.unsubscribe(channelId: channel.id)
                self.subscribedIds.remove(channel.id)
            }
        }
        artistsPage.onChange = { [weak self] ids in
            guard let self = self else { return }
            self.pickedArtistIds = ids
            self.persistState()
        }
        importPage.onImported = { [weak self] sourceId in
            guard let self = self else { return }
            self.importedSourceIds.insert(sourceId)
        }
        importPage.onFailure = { message in
            FlowSnackbar.showError(message)
        }
    }

    // MARK: - Navigation

    private func showStep(_ index: Int, animated: Bool) {
        currentIndex = min(max(index, 0), stepCount - 1)
        let width = pager.bounds.width
        if width > 0.0 {
            pager.setContentOffset(CGPoint(x: width * CGFloat(currentIndex), y: 0.0), animated: animated)
        }
        progressView.configure(stepCount: stepCount, currentIndex: currentIndex)
        updateBottomBar()
        persistState()
    }

    private func goForward() {
        guard currentIndex < stepCount - 1 else {
            finish()
            return
        }
        showStep(currentIndex + 1, animated: true)
    }

    private func goBack() {
        guard currentIndex > 0 else { return }
        showStep(currentIndex - 1, animated: true)
    }

    private func finish() {
        FlowApp.shared.prefs.set(true, for: .onboardingCompleted)
        FlowApp.shared.prefs.set(stepCount - 1, for: .onboardingStep)
        persistState()
        onFinished?()
    }

    private func updateBottomBar() {
        backButton.isHidden = currentIndex == 0
        let remaining = max(OnboardingTopicCatalog.minimumTopics - selectedTopics.count, 0)
        if currentIndex == 0 && remaining > 0 {
            continueButton.setTitle(remaining == 1 ? "Pick 1 more" : "Pick " + String(remaining) + " more")
            continueButton.setIcon(nil)
            continueButton.isEnabled = false
        } else if currentIndex == stepCount - 1 {
            continueButton.setTitle("Start watching")
            continueButton.setIcon(.play)
            continueButton.isEnabled = true
        } else {
            continueButton.setTitle("Continue")
            continueButton.setIcon(.chevronRight)
            continueButton.isEnabled = true
        }
        continueButton.applyTheme()
        backButton.applyTheme()
    }

    // MARK: - Scrolling

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === pager else { return }
        let width = scrollView.bounds.width
        guard width > 0.0 else { return }
        let index = Int(round(scrollView.contentOffset.x / width))
        guard index != currentIndex else { return }
        currentIndex = min(max(index, 0), stepCount - 1)
        progressView.configure(stepCount: stepCount, currentIndex: currentIndex)
        updateBottomBar()
        persistState()
        view.endEditing(true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === pager else { return }
        let width = scrollView.bounds.width
        guard width > 0.0 else { return }
        let index = Int(round(scrollView.contentOffset.x / width))
        currentIndex = min(max(index, 0), stepCount - 1)
        progressView.configure(stepCount: stepCount, currentIndex: currentIndex)
        updateBottomBar()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = pager.bounds.width
        guard width > 0.0 else { return }
        let expected = CGPoint(x: width * CGFloat(currentIndex), y: 0.0)
        if abs(pager.contentOffset.x - expected.x) > 1.0 && !pager.isDragging && !pager.isDecelerating {
            pager.setContentOffset(expected, animated: false)
        }
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        topBar.backgroundColor = scheme.background
        bottomBar.backgroundColor = scheme.background
        progressView.setNeedsDisplay()
        skipButton.applyTheme()
        backButton.applyTheme()
        continueButton.applyTheme()
        interestsPage.applyTheme()
        channelsPage.applyTheme()
        artistsPage.applyTheme()
        importPage.applyTheme()
    }
}

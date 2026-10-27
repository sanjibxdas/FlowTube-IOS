import UIKit

// MARK: - Metrics

/// The sizes the music screens share. Square artwork is the one constant of the design: a song, an
/// album, a playlist and an artist all get the same tile, so a mixed shelf reads as one row rather
/// than as four different components.
enum MusicMetrics {

    /// The width of one carousel tile, and therefore its artwork's height.
    static let cardWidth: CGFloat = 148.0
    static let cardArtworkSize: CGFloat = 148.0
    /// The two-line title and one-line subtitle below the artwork.
    static let cardTextHeight: CGFloat = 60.0
    static let cardHeight: CGFloat = cardArtworkSize + cardTextHeight

    /// A carousel's section header, including the spacing Material puts below it.
    static let carouselHeaderHeight: CGFloat = 48.0
    /// A carousel of tiles that carry text.
    static let carouselRowHeight: CGFloat = carouselHeaderHeight + cardHeight + 8.0
    /// A carousel of tiles that are the artwork alone, like the mood and genre tiles.
    static let tileRowHeight: CGFloat = carouselHeaderHeight + cardArtworkSize + 8.0

    static let trackRowHeight: CGFloat = 64.0
    static let trackArtworkSize: CGFloat = 48.0
    static let trackIndexWidth: CGFloat = 28.0

    static let heroArtworkSize: CGFloat = 232.0
    static let artistHeroSize: CGFloat = 180.0

    static let headerBarHeight: CGFloat = 56.0
    static let searchEntryHeight: CGFloat = 44.0
    static let carouselSpacing: CGFloat = 12.0
    static let moodButtonHeight: CGFloat = 48.0
    static let statusHeight: CGFloat = 72.0
    static let sectionSpacing: CGFloat = 8.0
}

// MARK: - Formatting

/// The wording the music screens share. The strings are the ones the Android app shows, so a song
/// count reads the same on both platforms.
enum MusicFormat {

    /// "1 song" / "12 songs".
    static func songCount(_ count: Int) -> String {
        return count == 1 ? "1 song" : String(count) + " songs"
    }

    /// "1 track" / "12 tracks".
    static func trackCount(_ count: Int) -> String {
        return count == 1 ? "1 track" : String(count) + " tracks"
    }

    /// A song's length, or an empty string when it is unknown.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        return Formatters.playbackTime(seconds)
    }

    /// The sum of the songs' lengths, ignoring the ones YouTube did not report.
    static func totalDuration(_ songs: [SongItem]) -> TimeInterval {
        return songs.reduce(0.0) { total, song in
            return total + TimeInterval(max(song.duration ?? 0, 0))
        }
    }

    /// Joins the parts of a metadata line with the separator the Android app uses.
    static func metadata(_ parts: [String?]) -> String {
        return parts
            .compactMap { $0 }
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// A year, when YouTube reported one.
    static func year(_ year: Int?) -> String? {
        guard let value = year, value > 0 else { return nil }
        return String(value)
    }
}

// MARK: - Navigation

/// Opens the destination a music item names. Every music screen routes through here so a song on
/// the home feed, in search and on an artist page all behave the same way.
enum MusicItemRouter {

    /// Opens `item`: a song plays, an album, playlist or artist page is pushed.
    static func open(_ item: MusicItem, from presenter: UIViewController, api: YouTubeAPI = YouTubeAPI()) {
        switch item {
        case .song(let song):
            play(songs: [song], startIndex: 0, title: nil, from: presenter)
        case .album(let album):
            openAlbum(id: album.browseId, from: presenter, api: api)
        case .playlist(let playlist):
            openPlaylist(id: playlist.id, from: presenter, api: api)
        case .artist(let artist):
            if artist.isProfile, let channelId = artist.channelId, !channelId.isEmpty {
                Router.shared.push(ChannelViewController(channelId: channelId, api: api), from: presenter)
            } else {
                openArtist(id: artist.id, from: presenter, api: api)
            }
        }
    }

    /// Pushes an artist's page.
    ///
    /// The router has no default builder for `.musicArtist`, so the concrete route is registered
    /// here before the push. That also makes a `flow://music/artist?id=…` link to this artist work
    /// for the rest of the session.
    static func openArtist(id: String, from presenter: UIViewController, api: YouTubeAPI = YouTubeAPI()) {
        guard !id.isEmpty else { return }
        let route = Route.musicArtist(id: id)
        Router.shared.register(route) { _ in
            return ArtistViewController(artistId: id, api: api)
        }
        Router.shared.push(ArtistViewController(artistId: id, api: api), from: presenter)
    }

    /// Pushes an album's page.
    static func openAlbum(id: String, from presenter: UIViewController, api: YouTubeAPI = YouTubeAPI()) {
        guard !id.isEmpty else { return }
        Router.shared.push(AlbumViewController(albumId: id, api: api), from: presenter)
    }

    /// Pushes a YouTube Music playlist's page.
    static func openPlaylist(id: String, from presenter: UIViewController, api: YouTubeAPI = YouTubeAPI()) {
        guard !id.isEmpty else { return }
        Router.shared.push(MusicCollectionViewController(source: .remote(playlistId: id), api: api), from: presenter)
    }

    /// Pushes the music search screen, optionally already searching for `query`.
    static func openSearch(query: String?, from presenter: UIViewController) {
        let controller = MusicSearchViewController()
        controller.initialQuery = query
        Router.shared.push(controller, from: presenter)
    }

    /// Replaces the queue with `songs` and opens the player at `startIndex`.
    static func play(songs: [SongItem], startIndex: Int, title: String?, from presenter: UIViewController) {
        guard !songs.isEmpty else { return }
        let items = songs.map { queueItem(for: $0) }
        let index = min(max(startIndex, 0), items.count - 1)
        FlowApp.shared.playback.play(items: items, startIndex: index, title: title, autoplay: true)
        presentPlayer(from: presenter)
    }

    /// Replaces the queue with `items` and opens the player at `startIndex`.
    static func play(items: [PlaybackQueueItem], startIndex: Int, title: String?, from presenter: UIViewController) {
        guard !items.isEmpty else { return }
        let index = min(max(startIndex, 0), items.count - 1)
        FlowApp.shared.playback.play(items: items, startIndex: index, title: title, autoplay: true)
        presentPlayer(from: presenter)
    }

    /// A queue entry for a song, carrying its downloaded file when there is one so the track plays
    /// with no network at all.
    static func queueItem(for song: SongItem) -> PlaybackQueueItem {
        var item = PlaybackQueueItem(song: song)
        if let record = DownloadStore.shared.record(videoId: song.id) {
            item.localFileURL = record.fileURL ?? record.audioURL
        }
        return item
    }

    /// Opens the full-screen player.
    static func presentPlayer(from presenter: UIViewController) {
        let player = MusicPlayerViewController(service: FlowApp.shared.playback)
        player.present(from: presenter)
    }
}

// MARK: - Cards

/// A square artwork tile with a two-line title and a one-line subtitle. Albums, playlists and
/// artists all use it; an artist's artwork is round, which is how YouTube Music marks a person
/// rather than a record.
final class MusicCollectionCardView: UIControl {

    private let artworkView = AsyncImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let explicitBadge = PaddedLabel()

    private let cardWidth: CGFloat
    private let circularArtwork: Bool

    /// Called when the tile is tapped.
    var onTap: (() -> Void)?

    init(width: CGFloat = MusicMetrics.cardWidth, circularArtwork: Bool = false) {
        cardWidth = width
        self.circularArtwork = circularArtwork
        super.init(frame: .zero)
        commonInit()
    }

    override init(frame: CGRect) {
        cardWidth = MusicMetrics.cardWidth
        circularArtwork = false
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        cardWidth = MusicMetrics.cardWidth
        circularArtwork = false
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = true

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.applyCornerRadius(circularArtwork ? cardWidth / 2.0 : FlowShapes.small)
        addSubview(artworkView)

        explicitBadge.translatesAutoresizingMaskIntoConstraints = false
        explicitBadge.font = FlowTypography.labelSmall
        explicitBadge.textColor = .white
        explicitBadge.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        explicitBadge.layer.cornerRadius = 3.0
        explicitBadge.layer.masksToBounds = true
        explicitBadge.textInsets = UIEdgeInsets(top: 1, left: 4, bottom: 1, right: 4)
        explicitBadge.text = "E"
        explicitBadge.isHidden = true
        addSubview(explicitBadge)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = FlowTypography.bodySmall
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: cardWidth),
            heightAnchor.constraint(equalToConstant: MusicMetrics.cardHeight),

            artworkView.leadingAnchor.constraint(equalTo: leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: trailingAnchor),
            artworkView.topAnchor.constraint(equalTo: topAnchor),
            artworkView.heightAnchor.constraint(equalToConstant: cardWidth),

            explicitBadge.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: -FlowSpacing.sm),
            explicitBadge.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: -FlowSpacing.sm),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: FlowSpacing.md),

            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        accessibilityTraits = .button
        applyTheme()
    }

    /// Fills the tile.
    func configure(title: String, subtitle: String?, artworkUrl: String?, isExplicit: Bool = false) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        artworkView.setImage(url: artworkUrl)
        explicitBadge.isHidden = !isExplicit
        accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ", ")
    }

    /// Repaints the tile's text in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        subtitleLabel.textColor = scheme.onSurfaceVariant
        artworkView.applyTheme()
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

/// A mood or genre tile: a solid colour block with the category's name in the middle. The colour is
/// the stripe YouTube assigns the category, which is what makes the moods row read at a glance.
final class MusicMoodCardView: UIControl {

    private let titleLabel = UILabel()
    private var fillColor: UIColor = .clear

    /// Called when the tile is tapped.
    var onTap: (() -> Void)?

    init() {
        super.init(frame: .zero)
        commonInit()
    }

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
        layer.cornerRadius = FlowShapes.small
        layer.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmallEmphasized
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: MusicMetrics.cardWidth),
            heightAnchor.constraint(equalToConstant: MusicMetrics.cardArtworkSize),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.md),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.md),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        accessibilityTraits = .button
    }

    /// Fills the tile from a mood or genre.
    func configure(_ mood: MoodAndGenre) {
        titleLabel.text = mood.title
        fillColor = UIColor(argb: UInt32(truncatingIfNeeded: mood.stripeColor))
        backgroundColor = fillColor
        titleLabel.textColor = fillColor.readableContentColor
        accessibilityLabel = mood.title
    }

    /// Mood tiles do not follow the theme, but the label's contrast is checked again in case the
    /// stripe colour arrived without an alpha channel.
    func applyTheme() {
        guard fillColor != UIColor.clear else { return }
        backgroundColor = fillColor
        titleLabel.textColor = fillColor.readableContentColor
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

// MARK: - Carousel

/// A titled row of tiles that scrolls sideways. The header is the same `FlowSectionHeader` every
/// other screen uses, so a music shelf and a video shelf are introduced identically.
final class MusicCarouselView: UIView {

    private let header = FlowSectionHeader()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var itemViews: [UIView] = []

    /// Called when the header's trailing action is tapped.
    var onAction: (() -> Void)? {
        didSet { header.onAction = onAction }
    }

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
        header.onAction = { [weak self] in self?.onAction?() }
        addSubviewForAutoLayout(header)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.decelerationRate = .fast
        addSubviewForAutoLayout(scrollView)

        stack.axis = .horizontal
        stack.spacing = MusicMetrics.carouselSpacing
        stack.alignment = .top
        scrollView.addSubviewForAutoLayout(stack)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.screenMargin),
            header.topAnchor.constraint(equalTo: topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: FlowSpacing.screenMargin),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    /// Sets the row's title and its optional trailing action.
    func configure(title: String, subtitle: String? = nil, actionTitle: String? = nil) {
        header.configure(title: title, subtitle: subtitle, actionTitle: actionTitle)
    }

    /// Replaces the row's tiles.
    func setItems(_ views: [UIView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        itemViews = views
        for view in views {
            stack.addArrangedSubview(view)
        }
    }

    /// Repaints the header and the tiles in the current palette.
    func applyTheme() {
        header.applyTheme()
        for view in itemViews {
            if let card = view as? MusicCollectionCardView {
                card.applyTheme()
            } else if let mood = view as? MusicMoodCardView {
                mood.applyTheme()
            }
        }
    }
}

// MARK: - Rows

/// A song row: artwork or a track number, the title, the artist and album, the length and a menu.
final class MusicTrackRowCell: UITableViewCell {

    static let reuseIdentifier = "MusicTrackRowCell"

    private let leadingContainer = UIView()
    private let artworkView = AsyncImageView()
    private let indexLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let durationLabel = UILabel()
    private let downloadedIcon = FlowIconView()
    private let menuButton = FlowIconButton()

    /// Called when the row's menu button is tapped.
    var onMenu: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        leadingContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(leadingContainer)

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.applyCornerRadius(FlowShapes.extraSmall)
        leadingContainer.addSubview(artworkView)

        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        indexLabel.font = FlowTypography.bodyMedium
        indexLabel.textAlignment = .center
        indexLabel.isHidden = true
        leadingContainer.addSubview(indexLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.bodyLarge
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = FlowTypography.bodySmall
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(subtitleLabel)

        downloadedIcon.translatesAutoresizingMaskIntoConstraints = false
        downloadedIcon.icon = .downloaded
        downloadedIcon.iconSize = 14.0
        downloadedIcon.isHidden = true
        contentView.addSubview(downloadedIcon)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = FlowTypography.bodySmall
        durationLabel.textAlignment = .right
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)
        durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentView.addSubview(durationLabel)

        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.accessibilityLabel = "More options"
        menuButton.addTarget(self, action: #selector(handleMenu), for: .touchUpInside)
        contentView.addSubview(menuButton)

        NSLayoutConstraint.activate([
            leadingContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            leadingContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            leadingContainer.widthAnchor.constraint(equalToConstant: MusicMetrics.trackArtworkSize),
            leadingContainer.heightAnchor.constraint(equalToConstant: MusicMetrics.trackArtworkSize),

            artworkView.leadingAnchor.constraint(equalTo: leadingContainer.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: leadingContainer.trailingAnchor),
            artworkView.topAnchor.constraint(equalTo: leadingContainer.topAnchor),
            artworkView.bottomAnchor.constraint(equalTo: leadingContainer.bottomAnchor),

            indexLabel.leadingAnchor.constraint(equalTo: leadingContainer.leadingAnchor),
            indexLabel.trailingAnchor.constraint(equalTo: leadingContainer.trailingAnchor),
            indexLabel.centerYAnchor.constraint(equalTo: leadingContainer.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: leadingContainer.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.topAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -19.0),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),

            downloadedIcon.leadingAnchor.constraint(equalTo: subtitleLabel.trailingAnchor, constant: FlowSpacing.xs),
            downloadedIcon.centerYAnchor.constraint(equalTo: subtitleLabel.centerYAnchor),
            downloadedIcon.widthAnchor.constraint(equalToConstant: 14.0),
            downloadedIcon.heightAnchor.constraint(equalToConstant: 14.0),

            durationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: FlowSpacing.md),
            durationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: downloadedIcon.trailingAnchor, constant: FlowSpacing.md),
            durationLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            menuButton.leadingAnchor.constraint(equalTo: durationLabel.trailingAnchor, constant: FlowSpacing.xs),
            menuButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.sm),
            menuButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 44.0),
            menuButton.heightAnchor.constraint(equalToConstant: 44.0),
        ])
        applyTheme()
    }

    /// Fills the row. A non-nil `position` shows the track number instead of the artwork, which is
    /// how an album's running order is drawn.
    func configure(
        position: Int?,
        title: String,
        subtitle: String,
        artworkUrl: String,
        duration: TimeInterval,
        isDownloaded: Bool,
        showsMenu: Bool = true
    ) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        artworkView.setImage(url: artworkUrl)
        artworkView.isHidden = position != nil
        indexLabel.isHidden = position == nil
        indexLabel.text = position.map { String($0) }
        let length = MusicFormat.duration(duration)
        durationLabel.text = length
        durationLabel.isHidden = length.isEmpty
        downloadedIcon.isHidden = !isDownloaded
        menuButton.isHidden = !showsMenu
        accessibilityLabel = [title, subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        subtitleLabel.textColor = scheme.onSurfaceVariant
        durationLabel.textColor = scheme.onSurfaceVariant
        indexLabel.textColor = scheme.onSurfaceVariant
        downloadedIcon.iconColor = scheme.primary
        menuButton.setIconColor(scheme.onSurfaceVariant)
    }

    override var isHighlighted: Bool {
        didSet {
            contentView.alpha = isHighlighted ? 0.7 : 1.0
        }
    }

    @objc private func handleMenu() {
        onMenu?()
    }
}

/// One carousel row inside the home table.
final class MusicCarouselCell: UITableViewCell {

    static let reuseIdentifier = "MusicCarouselCell"

    let carousel = MusicCarouselView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.addSubviewForAutoLayout(carousel)
        NSLayoutConstraint.activate([
            carousel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            carousel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            carousel.topAnchor.constraint(equalTo: contentView.topAnchor),
            carousel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }
}

/// The row that shows a spinner while the next page of the feed is in flight.
final class MusicStatusCell: UITableViewCell {

    static let reuseIdentifier = "MusicStatusCell"

    private let spinner = UIActivityIndicatorView(style: .gray)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        contentView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    /// Starts or stops the spinner.
    func setAnimating(_ animating: Bool) {
        if animating {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }

    /// Repaints the spinner in the current palette.
    func applyTheme() {
        spinner.color = FlowTheme.shared.scheme.onSurfaceVariant
    }
}

// MARK: - Home

/// The Music tab: the editorial shelves YouTube Music returns, each one a horizontal carousel of
/// square tiles, with a header that leads into music search.
///
/// The feed is whatever YouTube sends — "Listen again", "Quick picks", "Charts", "New releases" and
/// the rest — rather than a fixed set of rows, so a shelf YouTube adds appears without a code
/// change. The moods and genres row is appended from the explore surface, because it is the one
/// row the home feed does not carry.
final class MusicHomeViewController: UIViewController {

    // MARK: - State

    private enum Row {
        case section(HomeSection)
        case moods([MoodAndGenre])
        case status
    }

    private let api: YouTubeAPI
    private let titleLabel = UILabel()
    private let searchButton = FlowIconButton()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let shimmerView = FlowShimmerGrid()
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")

    private var rows: [Row] = []
    private var moods: [MoodAndGenre] = []
    private var continuation: String?
    private var isLoading = false
    private var isLoadingMore = false
    private var didLoad = false
    private var themeToken: ObservationToken?

    // MARK: - Construction

    init(api: YouTubeAPI = YouTubeAPI()) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
        title = "Music"
    }

    required init?(coder: NSCoder) {
        api = YouTubeAPI()
        super.init(coder: coder)
        title = "Music"
    }

    deinit {
        themeToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildHeader()
        buildTable()
        buildOverlays()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        applyTheme()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Build

    private func buildHeader() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.headlineSmall
        titleLabel.text = "Music"
        titleLabel.accessibilityTraits = .header
        view.addSubview(titleLabel)

        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.configure(icon: .search, color: FlowTheme.shared.onSurface, size: 22.0)
        searchButton.accessibilityLabel = "Search music"
        searchButton.addTarget(self, action: #selector(handleSearch), for: .touchUpInside)
        view.addSubview(searchButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.screenMargin),
            titleLabel.centerYAnchor.constraint(equalTo: searchButton.centerYAnchor),

            searchButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.md),
            searchButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchButton.widthAnchor.constraint(equalToConstant: 44.0),
            searchButton.heightAnchor.constraint(equalToConstant: MusicMetrics.headerBarHeight),
        ])
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: FlowSpacing.xxl, right: 0)

        tableView.register(MusicCarouselCell.self, forCellReuseIdentifier: MusicCarouselCell.reuseIdentifier)
        tableView.register(MusicStatusCell.self, forCellReuseIdentifier: MusicStatusCell.reuseIdentifier)

        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        tableView.refreshControl = refreshControl
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: searchButton.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildOverlays() {
        shimmerView.translatesAutoresizingMaskIntoConstraints = false
        shimmerView.isHidden = true
        shimmerView.setRowCount(3)
        view.addSubview(shimmerView)

        errorState.translatesAutoresizingMaskIntoConstraints = false
        errorState.isHidden = true
        errorState.onAction = { [weak self] in self?.load(force: true) }
        view.addSubview(errorState)

        NSLayoutConstraint.activate([
            shimmerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shimmerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shimmerView.topAnchor.constraint(equalTo: tableView.topAnchor),
            shimmerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            errorState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorState.topAnchor.constraint(equalTo: tableView.topAnchor),
            errorState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Loading

    private func load(force: Bool = false) {
        if isLoading && !force { return }
        isLoading = true
        if rows.isEmpty {
            errorState.isHidden = true
            shimmerView.isHidden = false
            shimmerView.startAnimating()
        }

        api.musicHome { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoading = false
                self.refreshControl.endRefreshing()
                switch result {
                case .success(let home):
                    self.didLoad = true
                    self.continuation = home.continuation
                    self.rebuildRows(home.sections)
                case .failure(let error):
                    self.shimmerView.stopAnimating()
                    self.shimmerView.isHidden = true
                    if self.rows.isEmpty {
                        self.errorState.isHidden = false
                        self.errorState.configure(
                            kind: .custom(icon: .wifi, title: "Couldn't load music", message: error.displayMessage),
                            actionTitle: "Retry"
                        )
                    } else {
                        FlowSnackbar.showError(error.displayMessage)
                    }
                }
            }
        }

        // The moods row is a second request, and a failure there must not take the feed down with
        // it: the home feed is the screen, the moods row is an extra.
        api.moodsAndGenres { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard case .success(let groups) = result else { return }
                var seen = Set<String>()
                var items: [MoodAndGenre] = []
                for group in groups {
                    for item in group.items where !seen.contains(item.browseId) {
                        seen.insert(item.browseId)
                        items.append(item)
                    }
                }
                self.moods = items
                self.appendMoodsRowIfNeeded()
            }
        }
    }

    private func loadMore() {
        guard let token = continuation, !token.isEmpty, !isLoadingMore else { return }
        isLoadingMore = true
        tableView.reloadData()
        api.musicHomeContinuation(token) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoadingMore = false
                switch result {
                case .success(let home):
                    self.continuation = home.continuation
                    let existing = self.rows
                    var sections = existing.compactMap { row -> HomeSection? in
                        if case .section(let section) = row { return section }
                        return nil
                    }
                    sections.append(contentsOf: home.sections)
                    self.rebuildRows(sections)
                case .failure(let error):
                    self.continuation = nil
                    self.tableView.reloadData()
                    FlowSnackbar.showError(error.displayMessage)
                }
            }
        }
    }

    /// Replaces the feed's shelves, keeping the moods row at the end.
    private func rebuildRows(_ sections: [HomeSection]) {
        var newRows: [Row] = sections.map { Row.section($0) }
        if !moods.isEmpty {
            newRows.append(.moods(moods))
        }
        if continuation != nil {
            newRows.append(.status)
        }
        rows = newRows
        shimmerView.stopAnimating()
        shimmerView.isHidden = true
        errorState.isHidden = true
        tableView.reloadData()
    }

    /// Adds the moods row once the groups arrive, without disturbing the shelves already shown.
    private func appendMoodsRowIfNeeded() {
        guard !moods.isEmpty, didLoad else { return }
        var newRows = rows.filter { row in
            if case .moods = row { return false }
            if case .status = row { return false }
            return true
        }
        newRows.append(.moods(moods))
        if continuation != nil {
            newRows.append(.status)
        }
        rows = newRows
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func handleSearch() {
        MusicItemRouter.openSearch(query: nil, from: self)
    }

    @objc private func handleRefresh() {
        load(force: true)
    }

    private func openMoods() {
        Router.shared.push(MoodsAndGenresViewController(api: api), from: self)
    }

    private func play(song: SongItem, in section: HomeSection) {
        let songs = section.items.compactMap { item -> SongItem? in
            if case .song(let value) = item { return value }
            return nil
        }
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else {
            MusicItemRouter.open(.song(song), from: self, api: api)
            return
        }
        MusicItemRouter.play(songs: songs, startIndex: index, title: section.title, from: self)
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        titleLabel.textColor = scheme.onSurface
        searchButton.setIconColor(scheme.onSurface)
        refreshControl.tintColor = scheme.onSurfaceVariant
        shimmerView.applyTheme()
        errorState.applyTheme()
        tableView.reloadData()
    }

    // MARK: - Row content

    private func cards(for section: HomeSection) -> [UIView] {
        var views: [UIView] = []
        for item in section.items {
            let circular = MusicHomeViewController.isArtist(item)
            let card = MusicCollectionCardView(circularArtwork: circular)
            card.configure(
                title: item.title,
                subtitle: MusicHomeViewController.subtitle(for: item),
                artworkUrl: item.thumbnailUrl,
                isExplicit: item.isExplicit
            )
            card.onTap = { [weak self] in
                guard let self = self else { return }
                switch item {
                case .song(let song):
                    self.play(song: song, in: section)
                default:
                    MusicItemRouter.open(item, from: self, api: self.api)
                }
            }
            views.append(card)
        }
        return views
    }

    private func moodCards() -> [UIView] {
        var views: [UIView] = []
        for mood in moods {
            let card = MusicMoodCardView()
            card.configure(mood)
            card.onTap = { [weak self] in
                guard let self = self else { return }
                // A mood's browse id is not a playlist id, so the tile opens a search for the
                // category instead — the same music, reached through the endpoint the app has.
                MusicItemRouter.openSearch(query: mood.title, from: self)
            }
            views.append(card)
        }
        return views
    }

    private static func isArtist(_ item: MusicItem) -> Bool {
        if case .artist = item { return true }
        return false
    }

    private static func subtitle(for item: MusicItem) -> String? {
        switch item {
        case .song(let song):
            return song.artistLine
        case .album(let album):
            return album.artistLine.isEmpty ? MusicFormat.year(album.year) : album.artistLine
        case .playlist(let playlist):
            return playlist.authorName ?? playlist.songCountText
        case .artist(let artist):
            return artist.subscriberCountText
        }
    }
}

// MARK: - Data source

extension MusicHomeViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let row = rows.element(at: indexPath.row) else {
            return UITableViewCell()
        }
        switch row {
        case .section(let section):
            let cell = tableView.dequeueReusableCell(withIdentifier: MusicCarouselCell.reuseIdentifier, for: indexPath)
            guard let carouselCell = cell as? MusicCarouselCell else { return cell }
            carouselCell.carousel.configure(title: section.title, subtitle: section.subtitle)
            carouselCell.carousel.setItems(cards(for: section))
            carouselCell.carousel.applyTheme()
            return carouselCell

        case .moods:
            let cell = tableView.dequeueReusableCell(withIdentifier: MusicCarouselCell.reuseIdentifier, for: indexPath)
            guard let carouselCell = cell as? MusicCarouselCell else { return cell }
            carouselCell.carousel.configure(title: "Moods & Genres", actionTitle: "See all")
            carouselCell.carousel.onAction = { [weak self] in self?.openMoods() }
            carouselCell.carousel.setItems(moodCards())
            carouselCell.carousel.applyTheme()
            return carouselCell

        case .status:
            let cell = tableView.dequeueReusableCell(withIdentifier: MusicStatusCell.reuseIdentifier, for: indexPath)
            if let statusCell = cell as? MusicStatusCell {
                statusCell.setAnimating(isLoadingMore)
                statusCell.applyTheme()
            }
            return cell
        }
    }
}

// MARK: - Delegate

extension MusicHomeViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let row = rows.element(at: indexPath.row) else { return 0.0 }
        switch row {
        case .section:
            return MusicMetrics.carouselRowHeight
        case .moods:
            return MusicMetrics.tileRowHeight
        case .status:
            return MusicMetrics.statusHeight
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        let offset = scrollView.contentOffset.y
        let height = scrollView.contentSize.height
        let visible = scrollView.bounds.height
        guard height > visible else { return }
        if offset > height - visible * 2.0 {
            loadMore()
        }
    }
}

// MARK: - Prefetching

extension MusicHomeViewController: UITableViewDataSourcePrefetching {

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        var urls: [String] = []
        for indexPath in indexPaths {
            guard let row = rows.element(at: indexPath.row) else { continue }
            if case .section(let section) = row {
                urls.append(contentsOf: section.items.map { $0.thumbnailUrl })
            }
        }
        ImageLoader.shared.prefetch(urls)
    }
}

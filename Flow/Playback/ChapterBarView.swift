import UIKit

/// The seek bar's chapter and SponsorBlock layer.
///
/// The bar is drawn under the player's scrubber: chapters as alternating subtle segments with their
/// titles, SponsorBlock segments in their category colours. It is deliberately a separate view from
/// the scrubber so a chapter can be tapped without moving the playhead, and so the video screen can
/// show it in the full-screen layout where the scrubber is a thin line.
///
/// Everything is drawn in `draw(_:)` rather than with subviews: a video can have a hundred chapters,
/// and a hundred `UIView`s on a bar that redraws every tick would be wasteful.
final class ChapterBarView: UIView {

    /// One chapter to draw.
    struct ChapterSegment {
        let title: String
        let start: TimeInterval
        let end: TimeInterval

        init(title: String, start: TimeInterval, end: TimeInterval) {
            self.title = title
            self.start = start
            self.end = end
        }

        init(chapter: Chapter, fallbackEnd: TimeInterval) {
            self.title = chapter.title
            self.start = chapter.startTime
            self.end = chapter.endTime ?? fallbackEnd
        }
    }

    /// The chapters, in order.
    private(set) var chapters: [ChapterSegment] = []

    /// The SponsorBlock segments, already filtered to the categories the viewer wants to see.
    private(set) var segments: [SponsorBlockSegment] = []

    /// The total duration the bar maps to.
    private(set) var duration: TimeInterval = 0

    /// The current position, drawn as a thin marker when `showsPlayhead` is on.
    private(set) var position: TimeInterval = 0

    /// Whether the bar draws a playhead line. Off for the full-screen bar, where the scrubber
    /// above already shows it.
    var showsPlayhead = true

    /// The height of the chapter strip.
    static let stripHeight: CGFloat = 4.0
    /// The height of the whole view, including the tap area.
    static let preferredHeight: CGFloat = 20.0

    private var chapterColors: [UIColor] = []
    private var segmentColors: [UIColor] = []

    /// Called when a chapter is tapped, with its start time.
    var onChapterSelected: ((TimeInterval) -> Void)?

    /// Called when a SponsorBlock segment is tapped, with the segment.
    var onSegmentSelected: ((SponsorBlockSegment) -> Void)?

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
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = false

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        heightAnchor.constraint(equalToConstant: ChapterBarView.preferredHeight).isActive = true
    }

    // MARK: - Content

    /// Sets the chapters and total duration.
    func setChapters(_ chapters: [ChapterSegment], duration: TimeInterval) {
        self.chapters = chapters.sorted { $0.start < $1.start }
        self.duration = max(duration, 0)
        recomputeChapterColors()
        setNeedsDisplay()
        updateAccessibility()
    }

    /// Sets the SponsorBlock segments to draw over the chapters.
    func setSegments(_ segments: [SponsorBlockSegment]) {
        self.segments = segments.filter { !$0.isFullVideo && $0.endTime > $0.startTime }
        recomputeSegmentColors()
        setNeedsDisplay()
        updateAccessibility()
    }

    /// Updates the playhead.
    func setPosition(_ position: TimeInterval) {
        guard showsPlayhead else { return }
        guard abs(position - self.position) > 0.1 else { return }
        self.position = position
        setNeedsDisplay()
    }

    /// Repaints in the current palette.
    func applyTheme() {
        recomputeChapterColors()
        recomputeSegmentColors()
        setNeedsDisplay()
    }

    private func recomputeChapterColors() {
        let scheme = FlowTheme.shared.scheme
        // Alternating rungs of the surface ladder read as separate chapters without adding lines.
        chapterColors = [
            scheme.onSurfaceVariant.withAlphaComponent(0.24),
            scheme.onSurfaceVariant.withAlphaComponent(0.14),
        ]
        _ = scheme
    }

    private func recomputeSegmentColors() {
        segmentColors = segments.map { segment in
            UIColor(hex: UInt32(truncatingIfNeeded: segment.color)).withAlpha(SponsorBlockCategory.segmentAlpha)
        }
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let stripHeight = ChapterBarView.stripHeight
        let stripRect = CGRect(
            x: 0,
            y: (bounds.height - stripHeight) / 2.0,
            width: bounds.width,
            height: stripHeight
        )
        let radius = stripHeight / 2.0
        let path = UIBezierPath(roundedRect: stripRect, cornerRadius: radius)

        // The track underneath everything, so a bar with no chapters still reads as a line.
        let scheme = FlowTheme.shared.scheme
        scheme.onSurfaceVariant.withAlphaComponent(0.18).setFill()
        path.fill()

        guard bounds.width > 0 else { return }
        context.saveGState()
        path.addClip()

        if duration > 0, !chapters.isEmpty {
            for (index, chapter) in chapters.enumerated() {
                let start = CGFloat(max(chapter.start, 0) / duration) * bounds.width
                let end = CGFloat(max(min(chapter.end, duration), chapter.start) / duration) * bounds.width
                let width = max(end - start, 0)
                guard width > 0.5 else { continue }
                let color = chapterColors.element(at: index % max(chapterColors.count, 1)) ?? chapterColors.first ?? UIColor.clear
                color.setFill()
                context.fill(CGRect(x: start, y: stripRect.minY, width: width, height: stripHeight))
            }
        }

        if duration > 0 {
            for (index, segment) in segments.enumerated() {
                let start = CGFloat(TimeInterval(segment.startTime) / duration) * bounds.width
                let end = CGFloat(TimeInterval(segment.endTime) / duration) * bounds.width
                let width = max(end - start, 0)
                guard width > 0.5 else { continue }
                let color = segmentColors.element(at: index) ?? UIColor.clear
                color.setFill()
                context.fill(CGRect(x: start, y: stripRect.minY, width: width, height: stripHeight))
            }
        }
        context.restoreGState()

        if showsPlayhead, duration > 0 {
            let x = CGFloat(min(max(position / duration, 0.0), 1.0)) * bounds.width
            let marker = CGRect(x: max(x - 1.0, 0), y: 0, width: 2.0, height: bounds.height)
            scheme.onSurface.setFill()
            UIBezierPath(roundedRect: marker, cornerRadius: 1.0).fill()
        }
    }

    // MARK: - Taps

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard duration > 0 else { return }
        let point = recognizer.location(in: self)
        let time = TimeInterval(point.x / max(bounds.width, 1)) * duration

        // A SponsorBlock segment wins over a chapter, because the viewer is more likely aiming at
        // the coloured band than at the chapter behind it.
        for segment in segments where segment.contains(Float(time)) {
            onSegmentSelected?(segment)
            return
        }
        guard let chapter = chapters.last(where: { $0.start <= time }) else { return }
        onChapterSelected?(chapter.start)
    }

    // MARK: - Accessibility

    private func updateAccessibility() {
        if chapters.isEmpty && segments.isEmpty {
            isAccessibilityElement = false
            accessibilityLabel = nil
            return
        }
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        var parts: [String] = []
        if !chapters.isEmpty {
            parts.append("\(chapters.count) chapters")
        }
        if !segments.isEmpty {
            parts.append("\(segments.count) sponsor segments")
        }
        accessibilityLabel = parts.joined(separator: ", ")
    }

    override func accessibilityIncrement() {
        guard let next = chapters.first(where: { $0.start > position + 0.5 }) else { return }
        onChapterSelected?(next.start)
    }

    override func accessibilityDecrement() {
        guard let previous = chapters.last(where: { $0.start < position - 0.5 }) else { return }
        onChapterSelected?(previous.start)
    }
}

/// A compact list of chapters, for the player's chapter sheet.
///
/// The video screen shows this when the viewer taps the chapter button: every chapter with its
/// timestamp, the current one highlighted, and a tap to jump.
final class ChapterListView: UIView, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var chapters: [ChapterBarView.ChapterSegment] = []
    private var currentIndex = -1

    /// Called when a chapter is chosen.
    var onSelect: ((TimeInterval) -> Void)?

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
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 56.0
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.register(ChapterCell.self, forCellReuseIdentifier: ChapterCell.reuseIdentifier)
        addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme()
    }

    /// Sets the chapters and the one playing.
    func setChapters(_ chapters: [ChapterBarView.ChapterSegment], currentTime: TimeInterval) {
        self.chapters = chapters
        currentIndex = chapters.lastIndex(where: { $0.start <= currentTime }) ?? -1
        tableView.reloadData()
        if currentIndex >= 0 {
            tableView.scrollToRow(at: IndexPath(row: currentIndex, section: 0), at: .middle, animated: false)
        }
    }

    /// Repaints in the current palette.
    func applyTheme() {
        tableView.backgroundColor = FlowTheme.shared.scheme.surfaceContainerLow
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return chapters.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ChapterCell.reuseIdentifier, for: indexPath)
        guard let chapterCell = cell as? ChapterCell, let chapter = chapters.element(at: indexPath.row) else {
            return cell
        }
        chapterCell.configure(
            index: indexPath.row + 1,
            title: chapter.title,
            time: chapter.start,
            isCurrent: indexPath.row == currentIndex
        )
        return chapterCell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let chapter = chapters.element(at: indexPath.row) else { return }
        currentIndex = indexPath.row
        tableView.reloadData()
        onSelect?(chapter.start)
    }
}

/// One chapter row: the number, the title and the timestamp.
private final class ChapterCell: UITableViewCell {

    static let reuseIdentifier = "ChapterCell"

    private let numberLabel = UILabel()
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()

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
        selectionStyle = .default
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.font = FlowTypography.labelMedium
        numberLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.bodyLarge
        titleLabel.numberOfLines = 2
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = FlowTypography.labelMedium
        contentView.addSubview(numberLabel)
        contentView.addSubview(titleLabel)
        contentView.addSubview(timeLabel)
        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xl),
            numberLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            numberLabel.widthAnchor.constraint(equalToConstant: 20.0),

            titleLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.md),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.md),

            timeLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: FlowSpacing.md),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.xl),
            timeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        applyTheme()
    }

    func configure(index: Int, title: String, time: TimeInterval, isCurrent: Bool) {
        numberLabel.text = String(index)
        titleLabel.text = title
        timeLabel.text = Formatters.playbackTime(time)
        applyTheme()
        titleLabel.textColor = isCurrent ? FlowTheme.shared.primary : FlowTheme.shared.onSurface
        numberLabel.textColor = isCurrent ? FlowTheme.shared.primary : FlowTheme.shared.onSurfaceVariant
        accessibilityLabel = "Chapter \(index), \(title), \(Formatters.playbackTime(time))"
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        numberLabel.textColor = scheme.onSurfaceVariant
        timeLabel.textColor = scheme.onSurfaceVariant
        backgroundColor = .clear
    }
}

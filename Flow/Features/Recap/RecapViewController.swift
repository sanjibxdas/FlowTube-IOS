import UIKit

// MARK: - Period

/// The span a recap covers. The Android screen offers month, year and all time; the phone port
/// keeps the three spans a viewer actually checks — the day they are in, the week, the month — and
/// draws the same cards for each.
enum RecapPeriod: Int, CaseIterable {
    case today
    case week
    case month

    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    /// How many days back the period reaches, counting today.
    var dayCount: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    /// The start of the period, at midnight.
    func startDate(now: Date = Date()) -> Date {
        return now.startOfDay.addingDays(-(dayCount - 1))
    }

    /// The equally long span immediately before this one, for the "more than last week" line.
    func previousStartDate(now: Date = Date()) -> Date {
        return startDate(now: now).addingDays(-dayCount)
    }

    /// What the comparison line calls the previous span.
    var previousName: String {
        switch self {
        case .today: return "yesterday"
        case .week: return "the week before"
        case .month: return "the month before"
        }
    }
}

// MARK: - Snapshot

/// One bar of the chart: a day, or an hour when the period is today.
struct RecapBar {
    let label: String
    let shortLabel: String
    let seconds: TimeInterval
    let date: Date
}

/// One row of a ranked list.
struct RecapRankedItem {
    let id: String
    let name: String
    let detail: String
    let count: Int
    let seconds: TimeInterval
    let imageUrl: String
}

/// Everything the recap screen shows, computed once per period from the watch history. The screen
/// holds no statistics of its own: every number here is a fold over the entries the store returns,
/// so the recap can never claim something the history does not contain.
struct RecapSnapshot {

    let period: RecapPeriod
    let totalSeconds: TimeInterval
    let previousTotalSeconds: TimeInterval
    let bars: [RecapBar]
    let topChannels: [RecapRankedItem]
    let topArtists: [RecapRankedItem]
    let videosWatched: Int
    let songsPlayed: Int
    let activeDays: Int
    let longestStreak: Int
    let busiestDayLabel: String
    let busiestDaySeconds: TimeInterval

    var isEmpty: Bool {
        return totalSeconds <= 0.0 && videosWatched == 0 && songsPlayed == 0
    }

    /// The change against the previous span, as a signed fraction. Zero when there is nothing to
    /// compare with.
    var changeFraction: Double {
        guard previousTotalSeconds > 0.0 else { return 0.0 }
        return (totalSeconds - previousTotalSeconds) / previousTotalSeconds
    }

    /// "3 hours 12 minutes more than the week before", or "About the same as yesterday".
    var comparisonText: String {
        guard previousTotalSeconds > 0.0 else {
            return "First recap for this period"
        }
        let delta = totalSeconds - previousTotalSeconds
        if abs(delta) < 60.0 {
            return "About the same as " + period.previousName
        }
        let amount = Formatters.longDuration(abs(delta))
        if delta > 0.0 {
            return amount + " more than " + period.previousName
        }
        return amount + " less than " + period.previousName
    }

    // MARK: - Building

    /// Folds the history into a snapshot for `period`.
    ///
    /// `entries` is the store's newest-first list; the snapshot only looks at the entries inside the
    /// period and at the ones inside the previous period for the comparison.
    static func build(period: RecapPeriod, entries: [HistoryEntry], now: Date = Date()) -> RecapSnapshot {
        let calendar = Calendar.current
        let start = period.startDate(now: now)
        let previousStart = period.previousStartDate(now: now)

        var current: [HistoryEntry] = []
        var previousSeconds: TimeInterval = 0.0
        for entry in entries {
            if entry.watchedAt >= start {
                current.append(entry)
            } else if entry.watchedAt >= previousStart {
                previousSeconds += max(0.0, entry.position)
            }
        }

        var total: TimeInterval = 0.0
        var videos = 0
        var songs = 0
        var channelCounts: [String: (name: String, count: Int, seconds: TimeInterval)] = [:]
        var artistCounts: [String: (name: String, count: Int, seconds: TimeInterval, image: String)] = [:]
        var daySeconds: [Date: TimeInterval] = [:]
        var hourSeconds: [Int: TimeInterval] = [:]

        for entry in current {
            let watched = max(0.0, entry.position)
            total += watched
            if entry.isMusic {
                songs += 1
            } else {
                videos += 1
            }
            let day = entry.watchedAt.startOfDay
            daySeconds[day] = (daySeconds[day] ?? 0.0) + watched
            let hour = calendar.component(.hour, from: entry.watchedAt)
            hourSeconds[hour] = (hourSeconds[hour] ?? 0.0) + watched

            if !entry.channelId.isEmpty {
                let existing = channelCounts[entry.channelId]
                let name = (existing?.name.isEmpty ?? true) ? entry.channelName : (existing?.name ?? "")
                channelCounts[entry.channelId] = (
                    name: name,
                    count: (existing?.count ?? 0) + 1,
                    seconds: (existing?.seconds ?? 0.0) + watched
                )
            }
            if entry.isMusic {
                let artistName = entry.channelName.isEmpty ? "Unknown artist" : entry.channelName
                let key = entry.channelId.isEmpty ? artistName : entry.channelId
                let existing = artistCounts[key]
                let image = (existing?.image.isEmpty ?? true) ? entry.thumbnailUrl : (existing?.image ?? "")
                artistCounts[key] = (
                    name: (existing?.name.isEmpty ?? true) ? artistName : (existing?.name ?? artistName),
                    count: (existing?.count ?? 0) + 1,
                    seconds: (existing?.seconds ?? 0.0) + watched,
                    image: image
                )
            }
        }

        let channels = channelCounts
            .map { RecapRankedItem(id: $0.key, name: $0.value.name, detail: "", count: $0.value.count, seconds: $0.value.seconds, imageUrl: "") }
            .sorted { $0.seconds > $1.seconds }
            .prefix(5)
        let artists = artistCounts
            .map { RecapRankedItem(id: $0.key, name: $0.value.name, detail: "", count: $0.value.count, seconds: $0.value.seconds, imageUrl: $0.value.image) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(5)

        let bars = buildBars(period: period, now: now, daySeconds: daySeconds, hourSeconds: hourSeconds)

        var streak = 0
        var bestStreak = 0
        var previousDay: Date?
        for day in daySeconds.keys.sorted() where (daySeconds[day] ?? 0.0) > 0.0 {
            if let last = previousDay, calendar.isDate(day, inSameDayAs: last.addingDays(1)) {
                streak += 1
            } else {
                streak = 1
            }
            bestStreak = max(bestStreak, streak)
            previousDay = day
        }

        let busiest = daySeconds.max { $0.value < $1.value }
        let busiestLabel: String
        if let busiest = busiest {
            busiestLabel = Formatters.dayHeading(busiest.key)
        } else {
            busiestLabel = "No activity"
        }

        return RecapSnapshot(
            period: period,
            totalSeconds: total,
            previousTotalSeconds: previousSeconds,
            bars: bars,
            topChannels: Array(channels),
            topArtists: Array(artists),
            videosWatched: videos,
            songsPlayed: songs,
            activeDays: daySeconds.filter { $0.value > 0.0 }.count,
            longestStreak: bestStreak,
            busiestDayLabel: busiestLabel,
            busiestDaySeconds: busiest?.value ?? 0.0
        )
    }

    private static func buildBars(
        period: RecapPeriod,
        now: Date,
        daySeconds: [Date: TimeInterval],
        hourSeconds: [Int: TimeInterval]
    ) -> [RecapBar] {
        let calendar = Calendar.current
        if period == .today {
            let today = now.startOfDay
            return (0..<24).map { hour in
                let label: String
                if hour == 0 {
                    label = "12 AM"
                } else if hour < 12 {
                    label = String(hour) + " AM"
                } else if hour == 12 {
                    label = "12 PM"
                } else {
                    label = String(hour - 12) + " PM"
                }
                return RecapBar(
                    label: label,
                    shortLabel: hour % 3 == 0 ? String(hour) : "",
                    seconds: hourSeconds[hour] ?? 0.0,
                    date: calendar.date(byAdding: .hour, value: hour, to: today) ?? today
                )
            }
        }

        let start = period.startDate(now: now)
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale.current
        dayFormatter.setLocalizedDateFormatFromTemplate("d")

        return (0..<period.dayCount).map { offset in
            let day = start.addingDays(offset)
            let label = formatter.string(from: day) + " " + dayFormatter.string(from: day)
            let short = period == .week ? formatter.string(from: day) : dayFormatter.string(from: day)
            return RecapBar(label: label, shortLabel: short, seconds: daySeconds[day] ?? 0.0, date: day)
        }
    }
}

// MARK: - Bar chart

/// A bar chart drawn with one `CAShapeLayer` per bar plus a baseline layer, so a value change is a
/// path animation rather than a redraw. Tapping a bar reports its index; the caption above the
/// chart shows what the selected bar stands for.
final class RecapBarChartView: UIView {

    /// Called with the index of the bar the viewer tapped.
    var onSelect: ((Int) -> Void)?

    private let gridLayer = CAShapeLayer()
    private let baselineLayer = CAShapeLayer()
    private let barsContainer = CALayer()
    private let labelRow = UIStackView()
    private let captionLabel = UILabel()

    private var bars: [RecapBar] = []
    private var barLayers: [CAShapeLayer] = []
    private var labels: [UILabel] = []
    private var selectedIndex: Int = -1

    private let chartHeight: CGFloat = 148.0

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

        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.font = FlowTypography.titleSmall
        captionLabel.numberOfLines = 1
        addSubview(captionLabel)

        layer.addSublayer(gridLayer)
        layer.addSublayer(baselineLayer)
        layer.addSublayer(barsContainer)
        gridLayer.lineWidth = 1.0
        baselineLayer.lineWidth = 1.0

        labelRow.translatesAutoresizingMaskIntoConstraints = false
        labelRow.axis = .horizontal
        labelRow.distribution = .fillEqually
        labelRow.alignment = .top
        addSubview(labelRow)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        isAccessibilityElement = true
        accessibilityTraits = .image

        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            captionLabel.topAnchor.constraint(equalTo: topAnchor),

            labelRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            labelRow.topAnchor.constraint(equalTo: topAnchor, constant: chartHeight + FlowSpacing.md),
            labelRow.heightAnchor.constraint(equalToConstant: 16.0),
            labelRow.bottomAnchor.constraint(equalTo: bottomAnchor),

            heightAnchor.constraint(equalToConstant: chartHeight + FlowSpacing.md + 16.0 + 20.0),
        ])
        applyTheme()
    }

    func configure(bars: [RecapBar], selectedIndex: Int = -1) {
        self.bars = bars
        self.selectedIndex = selectedIndex
        rebuildLabels()
        rebuildBars(animated: false)
        updateCaption()
    }

    func select(index: Int) {
        guard index >= 0, index < bars.count else { return }
        selectedIndex = index
        rebuildBars(animated: true)
        updateCaption()
    }

    private func rebuildLabels() {
        for label in labels {
            labelRow.removeArrangedSubview(label)
            label.removeFromSuperview()
        }
        labels = []
        for bar in bars {
            let label = UILabel()
            label.font = FlowTypography.labelSmall
            label.textAlignment = .center
            label.text = bar.shortLabel
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
            labels.append(label)
            labelRow.addArrangedSubview(label)
        }
    }

    private func rebuildBars(animated: Bool) {
        for layer in barLayers {
            layer.removeFromSuperlayer()
        }
        barLayers = []
        guard !bars.isEmpty else { return }

        let maximum = max(bars.map { $0.seconds }.max() ?? 0.0, 1.0)
        let width = bounds.width
        guard width > 0.0 else { return }
        let count = CGFloat(bars.count)
        let slot = width / count
        let barWidth = max(min(slot * 0.62, 26.0), 3.0)
        let scheme = FlowTheme.shared.scheme
        let baseY = chartHeight

        for (index, bar) in bars.enumerated() {
            let fraction = CGFloat(max(0.0, bar.seconds) / maximum)
            let height = max(fraction * (chartHeight - 8.0), bar.seconds > 0.0 ? 3.0 : 2.0)
            let x = slot * CGFloat(index) + (slot - barWidth) / 2.0
            let rect = CGRect(x: x, y: baseY - height, width: barWidth, height: height)

            let shape = CAShapeLayer()
            shape.path = UIBezierPath(roundedRect: rect, cornerRadius: min(barWidth / 2.0, 6.0)).cgPath
            let isSelected = index == selectedIndex
            if isSelected {
                shape.fillColor = scheme.primary.cgColor
            } else if bar.seconds > 0.0 {
                shape.fillColor = scheme.primary.withAlpha(0.55).cgColor
            } else {
                shape.fillColor = scheme.outlineVariant.withAlpha(0.45).cgColor
            }
            barsContainer.addSublayer(shape)
            barLayers.append(shape)

            if animated {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 0.35
                animation.toValue = 1.0
                animation.duration = FlowMotion.quick
                shape.add(animation, forKey: "highlight")
            }
        }

        let grid = UIBezierPath()
        for step in 1...2 {
            let y = chartHeight - (chartHeight / 3.0) * CGFloat(step)
            grid.move(to: CGPoint(x: 0.0, y: y))
            grid.addLine(to: CGPoint(x: width, y: y))
        }
        gridLayer.path = grid.cgPath
        gridLayer.strokeColor = scheme.outlineVariant.withAlpha(0.35).cgColor

        let baseline = UIBezierPath()
        baseline.move(to: CGPoint(x: 0.0, y: chartHeight))
        baseline.addLine(to: CGPoint(x: width, y: chartHeight))
        baselineLayer.path = baseline.cgPath
        baselineLayer.strokeColor = scheme.outlineVariant.cgColor
    }

    private func updateCaption() {
        if selectedIndex >= 0, let bar = bars.element(at: selectedIndex) {
            captionLabel.text = bar.label + " · " + Formatters.longDuration(bar.seconds)
        } else {
            let total = bars.reduce(0.0) { $0 + $1.seconds }
            captionLabel.text = Formatters.longDuration(total) + " in this period"
        }
        accessibilityLabel = captionLabel.text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The bars live in their own layer so a redraw never touches the grid or the labels.
        barsContainer.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: chartHeight)
        rebuildBars(animated: false)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard !bars.isEmpty else { return }
        let point = recognizer.location(in: self)
        guard point.y <= chartHeight + FlowSpacing.md else { return }
        let slot = bounds.width / CGFloat(bars.count)
        guard slot > 0.0 else { return }
        let index = min(max(Int(point.x / slot), 0), bars.count - 1)
        select(index: index)
        onSelect?(index)
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        captionLabel.textColor = scheme.onSurfaceVariant
        for label in labels {
            label.textColor = scheme.onSurfaceVariant
        }
        setNeedsLayout()
        rebuildBars(animated: false)
    }
}

// MARK: - Stat tile

/// One headline number with its label, in a rounded container. Two tiles share a row.
final class RecapStatTile: UIView {

    private let valueLabel = UILabel()
    private let titleLabel = UILabel()
    private let iconView = FlowIconView()

    init(icon: FlowIcon, title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = FlowShapes.medium
        layer.masksToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.icon = icon
        iconView.iconSize = 20.0
        iconView.widthAnchor.constraint(equalToConstant: 20.0).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 20.0).isActive = true
        addSubview(iconView)

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = FlowTypography.headlineSmall
        valueLabel.numberOfLines = 1
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.7
        addSubview(valueLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.bodySmall
        titleLabel.numberOfLines = 2
        titleLabel.text = title
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.lg),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.lg),

            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.lg),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.lg),
            valueLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: FlowSpacing.sm),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.lg),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.lg),
            titleLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 2.0),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.lg),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func setValue(_ value: String) {
        valueLabel.text = value
        accessibilityLabel = (titleLabel.text ?? "") + ": " + value
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = scheme.surfaceContainerHigh
        valueLabel.textColor = scheme.onSurface
        titleLabel.textColor = scheme.onSurfaceVariant
        iconView.iconColor = scheme.primary
    }
}

// MARK: - Ranked row

/// One channel or artist in a ranked list: artwork, name, how much it was watched and how long.
final class RecapRankedRow: UIView {

    private let artwork = AsyncImageView.make(contentMode: .scaleAspectFill, cornerRadius: FlowShapes.thumbnail)
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let rankLabel = UILabel()

    init(rank: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        rankLabel.translatesAutoresizingMaskIntoConstraints = false
        rankLabel.font = FlowTypography.titleSmall
        rankLabel.text = String(rank)
        rankLabel.textAlignment = .center
        rankLabel.widthAnchor.constraint(equalToConstant: 18.0).isActive = true
        addSubview(rankLabel)

        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 18.0
        addSubview(artwork)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = FlowTypography.titleSmall
        nameLabel.numberOfLines = 1
        addSubview(nameLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 1
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            rankLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            rankLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            artwork.leadingAnchor.constraint(equalTo: rankLabel.trailingAnchor, constant: FlowSpacing.md),
            artwork.centerYAnchor.constraint(equalTo: centerYAnchor),
            artwork.widthAnchor.constraint(equalToConstant: 36.0),
            artwork.heightAnchor.constraint(equalToConstant: 36.0),

            nameLabel.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: FlowSpacing.md),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.sm),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1.0),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.sm),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 52.0),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func configure(item: RecapRankedItem, isArtist: Bool) {
        nameLabel.text = item.name
        let plays = item.count == 1 ? "1 play" : String(item.count) + " plays"
        let watches = item.count == 1 ? "1 view" : String(item.count) + " views"
        detailLabel.text = (isArtist ? plays : watches) + " · " + Formatters.longDuration(item.seconds)
        if item.imageUrl.isEmpty {
            artwork.clearImage()
        } else {
            artwork.setImage(url: item.imageUrl)
        }
        accessibilityLabel = item.name + ", " + (detailLabel.text ?? "")
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        rankLabel.textColor = scheme.onSurfaceVariant
        nameLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        artwork.backgroundColor = scheme.surfaceContainerHighest
    }
}

// MARK: - Share card

/// The image the share sheet sends: the period, the total, the chart and the two top lists, laid
/// out at a fixed size so the picture looks the same whatever the device's screen is.
final class RecapShareCard: UIView {

    static let size = CGSize(width: 1080.0, height: 1350.0)

    private let markView = FlowIconView()
    private let titleLabel = UILabel()
    private let periodLabel = UILabel()
    private let totalLabel = UILabel()
    private let comparisonLabel = UILabel()
    private let chart = RecapBarChartView()
    private let channelsTitle = UILabel()
    private let artistsTitle = UILabel()
    private let channelsStack = UIStackView()
    private let artistsStack = UIStackView()
    private let footerLabel = UILabel()

    init(snapshot: RecapSnapshot) {
        super.init(frame: CGRect(origin: .zero, size: RecapShareCard.size))
        build()
        populate(snapshot: snapshot)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func build() {
        backgroundColor = FlowTheme.shared.scheme.background

        markView.translatesAutoresizingMaskIntoConstraints = false
        markView.icon = .recap
        markView.iconSize = 44.0
        markView.iconColor = FlowTheme.shared.scheme.primary
        addSubview(markView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.headlineMedium
        titleLabel.text = "Flow Recap"
        addSubview(titleLabel)

        periodLabel.translatesAutoresizingMaskIntoConstraints = false
        periodLabel.font = FlowTypography.titleMedium
        addSubview(periodLabel)

        totalLabel.translatesAutoresizingMaskIntoConstraints = false
        totalLabel.font = FlowTypography.displayMedium
        totalLabel.numberOfLines = 1
        totalLabel.adjustsFontSizeToFitWidth = true
        totalLabel.minimumScaleFactor = 0.6
        addSubview(totalLabel)

        comparisonLabel.translatesAutoresizingMaskIntoConstraints = false
        comparisonLabel.font = FlowTypography.bodyLarge
        comparisonLabel.numberOfLines = 2
        addSubview(comparisonLabel)

        chart.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chart)

        channelsTitle.translatesAutoresizingMaskIntoConstraints = false
        channelsTitle.font = FlowTypography.titleMedium
        channelsTitle.text = "Top channels"
        addSubview(channelsTitle)

        artistsTitle.translatesAutoresizingMaskIntoConstraints = false
        artistsTitle.font = FlowTypography.titleMedium
        artistsTitle.text = "Top artists"
        addSubview(artistsTitle)

        for stack in [channelsStack, artistsStack] {
            stack.axis = .vertical
            stack.spacing = 8.0
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = FlowTypography.bodySmall
        footerLabel.text = "Made with Flow"
        addSubview(footerLabel)

        NSLayoutConstraint.activate([
            markView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 64.0),
            markView.topAnchor.constraint(equalTo: topAnchor, constant: 64.0),
            markView.widthAnchor.constraint(equalToConstant: 44.0),
            markView.heightAnchor.constraint(equalToConstant: 44.0),

            titleLabel.leadingAnchor.constraint(equalTo: markView.trailingAnchor, constant: 16.0),
            titleLabel.centerYAnchor.constraint(equalTo: markView.centerYAnchor),

            periodLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 64.0),
            periodLabel.topAnchor.constraint(equalTo: markView.bottomAnchor, constant: 32.0),

            totalLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 64.0),
            totalLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -64.0),
            totalLabel.topAnchor.constraint(equalTo: periodLabel.bottomAnchor, constant: 8.0),

            comparisonLabel.leadingAnchor.constraint(equalTo: totalLabel.leadingAnchor),
            comparisonLabel.trailingAnchor.constraint(equalTo: totalLabel.trailingAnchor),
            comparisonLabel.topAnchor.constraint(equalTo: totalLabel.bottomAnchor, constant: 8.0),

            chart.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 64.0),
            chart.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -64.0),
            chart.topAnchor.constraint(equalTo: comparisonLabel.bottomAnchor, constant: 32.0),

            channelsTitle.leadingAnchor.constraint(equalTo: chart.leadingAnchor),
            channelsTitle.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 40.0),

            artistsTitle.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 24.0),
            artistsTitle.topAnchor.constraint(equalTo: channelsTitle.topAnchor),

            channelsStack.leadingAnchor.constraint(equalTo: channelsTitle.leadingAnchor),
            channelsStack.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -24.0),
            channelsStack.topAnchor.constraint(equalTo: channelsTitle.bottomAnchor, constant: 12.0),

            artistsStack.leadingAnchor.constraint(equalTo: artistsTitle.leadingAnchor),
            artistsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -64.0),
            artistsStack.topAnchor.constraint(equalTo: artistsTitle.bottomAnchor, constant: 12.0),

            footerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 64.0),
            footerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -48.0),
        ])
        applyTheme()
    }

    private func populate(snapshot: RecapSnapshot) {
        periodLabel.text = snapshot.period.title
        totalLabel.text = Formatters.longDuration(snapshot.totalSeconds)
        comparisonLabel.text = snapshot.comparisonText
        chart.configure(bars: snapshot.bars)

        fill(stack: channelsStack, items: snapshot.topChannels, isArtist: false)
        fill(stack: artistsStack, items: snapshot.topArtists, isArtist: true)
    }

    private func fill(stack: UIStackView, items: [RecapRankedItem], isArtist: Bool) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if items.isEmpty {
            let label = UILabel()
            label.font = FlowTypography.bodyMedium
            label.text = isArtist ? "No music yet" : "No channels yet"
            label.textColor = FlowTheme.shared.scheme.onSurfaceVariant
            stack.addArrangedSubview(label)
            return
        }
        for (index, item) in items.prefix(4).enumerated() {
            let row = RecapRankedRow(rank: index + 1)
            row.configure(item: item, isArtist: isArtist)
            stack.addArrangedSubview(row)
        }
    }

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = scheme.background
        titleLabel.textColor = scheme.onSurface
        periodLabel.textColor = scheme.onSurfaceVariant
        totalLabel.textColor = scheme.onSurface
        comparisonLabel.textColor = scheme.onSurfaceVariant
        channelsTitle.textColor = scheme.onSurface
        artistsTitle.textColor = scheme.onSurface
        footerLabel.textColor = scheme.onSurfaceVariant
        markView.iconColor = scheme.primary
    }

    /// Renders the card to an image at its fixed size.
    func renderImage() -> UIImage {
        setNeedsLayout()
        layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(size: RecapShareCard.size)
        return renderer.image { context in
            layer.render(in: context.cgContext)
        }
    }
}

// MARK: - Screen

/// The recap: how long the viewer watched today, this week or this month, drawn as a bar chart of
/// days (or hours, for today), with the channels and artists that took the most of that time, and a
/// share button that renders the whole card to an image.
final class RecapViewController: UIViewController {

    // MARK: - State

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let periodControl = FlowSegmentedControl()
    private let shareButton = FlowButton.make("Share recap", style: .tonal, icon: .share)
    private let totalLabel = UILabel()
    private let comparisonLabel = UILabel()
    private let chart = RecapBarChartView()
    private let statsGrid = UIStackView()
    private let channelsStack = UIStackView()
    private let artistsStack = UIStackView()
    private let channelsHeader = FlowSectionHeader.make(title: "Top channels")
    private let artistsHeader = FlowSectionHeader.make(title: "Top artists")
    private let emptyState = FlowEmptyState.make(
        kind: .custom(
            icon: .recap,
            title: "Nothing to recap yet",
            message: "Watch a few videos or listen to some music and your recap will fill in."
        )
    )

    private let watchedTile = RecapStatTile(icon: .play, title: "Videos watched")
    private let playedTile = RecapStatTile(icon: .music, title: "Songs played")
    private let daysTile = RecapStatTile(icon: .clock, title: "Days active")
    private let streakTile = RecapStatTile(icon: .recap, title: "Longest streak")

    private var period: RecapPeriod = .week
    private var snapshot: RecapSnapshot?
    private var themeToken: ObservationToken?
    private var historyToken: ObservationToken?

    deinit {
        themeToken?.cancelObservation()
        historyToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Recap"
        view.backgroundColor = FlowTheme.shared.background
        buildLayout()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        historyToken = FlowEventBus.shared.on("history") { [weak self] _ in
            DispatchQueue.main.async {
                self?.reload()
            }
        }
        applyTheme()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        reload()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Layout

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = FlowSpacing.xl
        scrollView.addSubview(contentStack)

        periodControl.setTitles(RecapPeriod.allCases.map { $0.title }, selectedIndex: period.rawValue)
        periodControl.onSelect = { [weak self] index in
            guard let self = self, let next = RecapPeriod(rawValue: index) else { return }
            self.period = next
            self.reload()
        }
        contentStack.addArrangedSubview(periodControl)

        contentStack.addArrangedSubview(makeHeadlineCard())
        contentStack.addArrangedSubview(makeChartCard())
        contentStack.addArrangedSubview(makeStatsGrid())
        contentStack.addArrangedSubview(makeRankedCard())
        contentStack.addArrangedSubview(shareButton)
        contentStack.addArrangedSubview(emptyState)

        shareButton.onTap = { [weak self] in
            self?.shareRecap()
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: FlowSpacing.screenMargin),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: FlowSpacing.md),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -FlowSpacing.xxl),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -FlowSpacing.screenMargin * 2.0),
        ])
    }

    private func makeHeadlineCard() -> UIView {
        let card = FlowCard.make(elevation: .standard)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)

        let caption = UILabel()
        caption.font = FlowTypography.titleSmall
        caption.text = "Time in Flow"

        totalLabel.font = FlowTypography.displaySmall
        totalLabel.numberOfLines = 1
        totalLabel.adjustsFontSizeToFitWidth = true
        totalLabel.minimumScaleFactor = 0.6

        comparisonLabel.font = FlowTypography.bodyMedium
        comparisonLabel.numberOfLines = 2

        stack.addArrangedSubview(caption)
        stack.addArrangedSubview(totalLabel)
        stack.addArrangedSubview(comparisonLabel)
        stack.setCustomSpacing(FlowSpacing.md, after: totalLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
        ])
        caption.textColor = FlowTheme.shared.scheme.onSurfaceVariant
        return card
    }

    private func makeChartCard() -> UIView {
        let card = FlowCard.make(elevation: .standard)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)

        let header = FlowSectionHeader.make(title: "Watch time", subtitle: nil)
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(chart)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
        ])
        return card
    }

    private func makeStatsGrid() -> UIView {
        statsGrid.axis = .vertical
        statsGrid.spacing = FlowSpacing.md
        statsGrid.translatesAutoresizingMaskIntoConstraints = false

        let firstRow = UIStackView(arrangedSubviews: [watchedTile, playedTile])
        firstRow.axis = .horizontal
        firstRow.spacing = FlowSpacing.md
        firstRow.distribution = .fillEqually

        let secondRow = UIStackView(arrangedSubviews: [daysTile, streakTile])
        secondRow.axis = .horizontal
        secondRow.spacing = FlowSpacing.md
        secondRow.distribution = .fillEqually

        statsGrid.addArrangedSubview(firstRow)
        statsGrid.addArrangedSubview(secondRow)
        return statsGrid
    }

    private func makeRankedCard() -> UIView {
        let card = FlowCard.make(elevation: .standard)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)

        channelsStack.axis = .vertical
        channelsStack.spacing = FlowSpacing.xs
        artistsStack.axis = .vertical
        artistsStack.spacing = FlowSpacing.xs

        stack.addArrangedSubview(channelsHeader)
        stack.addArrangedSubview(channelsStack)
        stack.setCustomSpacing(FlowSpacing.xl, after: channelsStack)
        stack.addArrangedSubview(artistsHeader)
        stack.addArrangedSubview(artistsStack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
        ])
        return card
    }

    // MARK: - Data

    private func reload() {
        let entries = FlowApp.shared.historyStore.recent(limit: 3000)
        let built = RecapSnapshot.build(period: period, entries: entries)
        snapshot = built

        totalLabel.text = Formatters.longDuration(built.totalSeconds)
        comparisonLabel.text = built.comparisonText
        chart.configure(bars: built.bars)

        watchedTile.setValue(String(built.videosWatched))
        playedTile.setValue(String(built.songsPlayed))
        daysTile.setValue(String(built.activeDays))
        streakTile.setValue(built.longestStreak == 1 ? "1 day" : String(built.longestStreak) + " days")

        fillRanked(stack: channelsStack, items: built.topChannels, isArtist: false, emptyText: "No channels watched in this period")
        fillRanked(stack: artistsStack, items: built.topArtists, isArtist: true, emptyText: "No music played in this period")

        let empty = built.isEmpty
        emptyState.isHidden = !empty
        chart.isHidden = empty
        shareButton.isHidden = empty
        statsGrid.isHidden = empty
        channelsHeader.isHidden = empty
        artistsHeader.isHidden = empty
        channelsStack.isHidden = empty
        artistsStack.isHidden = empty
    }

    private func fillRanked(stack: UIStackView, items: [RecapRankedItem], isArtist: Bool, emptyText: String) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if items.isEmpty {
            let label = UILabel()
            label.font = FlowTypography.bodyMedium
            label.text = emptyText
            label.textColor = FlowTheme.shared.scheme.onSurfaceVariant
            stack.addArrangedSubview(label)
            return
        }
        for (index, item) in items.enumerated() {
            let row = RecapRankedRow(rank: index + 1)
            row.configure(item: item, isArtist: isArtist)
            stack.addArrangedSubview(row)
        }
    }

    // MARK: - Sharing

    private func shareRecap() {
        guard let snapshot = snapshot, !snapshot.isEmpty else {
            FlowSnackbar.showError("There is nothing to share yet")
            return
        }
        let card = RecapShareCard(snapshot: snapshot)
        card.frame = CGRect(origin: .zero, size: RecapShareCard.size)
        card.layoutIfNeeded()
        let image = card.renderImage()
        let text = "My Flow recap for " + snapshot.period.title.lowercased() + ": " + Formatters.longDuration(snapshot.totalSeconds)
        let activity = UIActivityViewController(activityItems: [image, text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        activity.popoverPresentationController?.sourceRect = shareButton.bounds
        present(activity, animated: true, completion: nil)
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        scrollView.backgroundColor = .clear
        totalLabel.textColor = scheme.onSurface
        comparisonLabel.textColor = scheme.onSurfaceVariant
        periodControl.applyTheme()
        chart.applyTheme()
        shareButton.applyTheme()
        emptyState.applyTheme()
        watchedTile.applyTheme()
        playedTile.applyTheme()
        daysTile.applyTheme()
        streakTile.applyTheme()
        channelsHeader.applyTheme()
        artistsHeader.applyTheme()
        for stack in [channelsStack, artistsStack] {
            for view in stack.arrangedSubviews {
                if let row = view as? RecapRankedRow {
                    row.applyTheme()
                } else if let label = view as? UILabel {
                    label.textColor = scheme.onSurfaceVariant
                }
            }
        }
        for card in contentStack.arrangedSubviews {
            (card as? FlowCard)?.applyTheme()
        }
    }
}

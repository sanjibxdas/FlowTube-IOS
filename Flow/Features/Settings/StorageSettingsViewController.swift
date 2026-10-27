import UIKit

/// Storage: how much space the app is using, split into the parts a person can act on.
///
/// The breakdown is measured on a background queue and posted back to the main thread, because
/// walking the media and image directories can take a moment on a full device. Each row that can
/// be cleared says what it holds and offers the action beside it; the database row is informational,
/// since deleting it is "Clear all data" in Privacy and not a cache action.
final class StorageSettingsViewController: SettingsListViewController {

    /// The measured sizes. Zero until the first measurement finishes.
    private struct Breakdown {
        var downloads: Int64 = 0
        var images: Int64 = 0
        var database: Int64 = 0
        var downloadCount: Int = 0

        var total: Int64 {
            return downloads + images + database
        }
    }

    private var breakdown = Breakdown()
    private var isMeasuring = false
    private var hasMeasured = false

    /// Set when something changed while a measurement was in flight, so the numbers are not stale.
    private var needsRemeasure = false

    /// Keeps the breakdown honest when a download finishes or the cache is cleared elsewhere.
    private var observations = ObservationBag()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Storage"

        // A download that finishes while this screen is open changes the totals, and clearing the
        // cache from anywhere else changes them too. Both stores announce it on the event bus.
        observations.add(FlowEventBus.shared.on("downloads") { [weak self] _ in
            self?.measure()
        })
        observations.add(FlowEventBus.shared.on("images") { [weak self] _ in
            self?.measure()
        })
        measure()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Coming back from another screen may have changed the totals; the first appearance is
        // already covered by `viewDidLoad`.
        if hasMeasured {
            measure()
        }
    }

    // MARK: - Sections

    override var sections: [SettingsSection] {
        return [
            summarySection(),
            downloadsSection(),
            cacheSection(),
            databaseSection(),
        ]
    }

    private func summarySection() -> SettingsSection {
        let current = breakdown
        let measuring = isMeasuring
        return SettingsSection(
            header: "Storage",
            footer: "Everything Flow stores lives inside the app. Removing the app removes all of it.",
            rows: [
                .custom(configure: { cell in
                    let card = StorageSummaryCard()
                    card.configure(
                        total: current.total,
                        downloads: current.downloads,
                        images: current.images,
                        database: current.database,
                        isMeasuring: measuring
                    )
                    cell.contentStack.addArrangedSubview(card)
                }, action: nil),
            ]
        )
    }

    private func downloadsSection() -> SettingsSection {
        let count = breakdown.downloadCount
        let subtitle = count == 1 ? "1 downloaded video" : "\(count) downloaded videos"
        return SettingsSection(
            header: "Downloads",
            footer: "Deleting a download removes its file from the device. It can be downloaded again at any time.",
            rows: [
                .detail(
                    icon: .download,
                    title: "Downloaded media",
                    subtitle: subtitle,
                    value: Formatters.fileSize(breakdown.downloads)
                ),
                .destructive(
                    "Delete all downloads",
                    icon: .trash,
                    subtitle: "Remove every downloaded video and song",
                    action: { [weak self] in
                        self?.confirmDeleteDownloads()
                    }
                ),
            ]
        )
    }

    private func cacheSection() -> SettingsSection {
        return SettingsSection(
            header: "Cache",
            footer: "Artwork is re-downloaded as you browse. Clearing it never removes a download or a saved video.",
            rows: [
                .detail(
                    icon: .filter,
                    title: "Artwork",
                    subtitle: "Thumbnails, avatars and album covers",
                    value: Formatters.fileSize(breakdown.images)
                ),
                .destructive(
                    "Clear image cache",
                    icon: .trash,
                    subtitle: "Remove cached artwork and free the space",
                    action: { [weak self] in
                        self?.confirmClearImages()
                    }
                ),
            ]
        )
    }

    private func databaseSection() -> SettingsSection {
        return SettingsSection(
            header: "Database",
            footer: "History, subscriptions, playlists and notes. Clear it from Privacy when you want a fresh start.",
            rows: [
                .detail(
                    icon: .notes,
                    title: "Flow database",
                    subtitle: "History, subscriptions, playlists and notes",
                    value: Formatters.fileSize(breakdown.database)
                ),
            ]
        )
    }

    // MARK: - Measuring

    /// Measures the three stores off the main thread, then reloads.
    private func measure() {
        guard !isMeasuring else {
            needsRemeasure = true
            return
        }
        isMeasuring = true
        needsRemeasure = false
        rebuild()

        let downloads = FlowApp.shared.downloadStore
        let images = FlowApp.shared.imageLoader
        let databasePath = FlowDB.shared.filePath

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var result = Breakdown()
            result.downloads = downloads.storageUsed()
            result.downloadCount = downloads.completedCount
            result.images = images.diskSize()
            if let attributes = try? FileManager.default.attributesOfItem(atPath: databasePath),
               let size = attributes[.size] as? NSNumber {
                result.database = size.int64Value
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.breakdown = result
                self.isMeasuring = false
                self.hasMeasured = true
                self.rebuild()
                if self.needsRemeasure {
                    self.measure()
                }
            }
        }
    }

    // MARK: - Actions

    private func confirmDeleteDownloads() {
        guard breakdown.downloadCount > 0 else {
            FlowSnackbar.show("There are no downloads to delete")
            return
        }
        let alert = UIAlertController(
            title: "Delete all downloads?",
            message: "This removes " + Formatters.fileSize(breakdown.downloads) + " of downloaded media from this device. You can download it again later.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { _ in
            // The store broadcasts when the files are gone, which is what re-measures this screen.
            FlowApp.shared.downloadStore.removeAll()
            FlowSnackbar.show("Downloads deleted")
        }))
        present(alert, animated: true, completion: nil)
    }

    private func confirmClearImages() {
        guard breakdown.images > 0 else {
            FlowSnackbar.show("The image cache is already empty")
            return
        }
        let alert = UIAlertController(
            title: "Clear image cache?",
            message: "This removes " + Formatters.fileSize(breakdown.images) + " of cached artwork. Downloads and history stay.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive, handler: { _ in
            // `clearDisk` deletes on its own queue and broadcasts when it is done, so the
            // re-measurement is driven by that signal rather than by a guess at the timing.
            FlowApp.shared.imageLoader.clearMemory()
            FlowApp.shared.imageLoader.clearDisk()
            FlowSnackbar.show("Image cache cleared")
        }))
        present(alert, animated: true, completion: nil)
    }
}

// MARK: - Summary card

/// The storage summary: the total in the display size, then one bar per category and a legend.
///
/// The bar is drawn with plain views rather than a chart library: three segments in the palette's
/// primary, secondary and tertiary roles, so it reads in every theme.
final class StorageSummaryCard: UIView {

    private let totalLabel = UILabel()
    private let captionLabel = UILabel()
    private let bar = UIStackView()
    private let legend = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .gray)

    /// The category sizes, kept so `applyTheme` can repaint the bar without being handed them again.
    private var sizes: (downloads: Int64, images: Int64, database: Int64) = (0, 0, 0)

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

        totalLabel.font = FlowTypography.displaySmall
        totalLabel.adjustsFontSizeToFitWidth = true
        totalLabel.minimumScaleFactor = 0.6

        captionLabel.font = FlowTypography.bodyMedium

        bar.axis = .horizontal
        bar.spacing = 0.0
        bar.distribution = .fill
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.applyCornerRadius(5.0)
        bar.clipsToBounds = true

        legend.axis = .vertical
        legend.spacing = FlowSpacing.md

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // The spinner sits beside the total rather than over it, so "Measuring…" is never covered.
        let totalRow = UIStackView(arrangedSubviews: [totalLabel, spinner])
        totalRow.axis = .horizontal
        totalRow.alignment = .center
        totalRow.spacing = FlowSpacing.md

        let stack = UIStackView(arrangedSubviews: [totalRow, captionLabel, bar, legend])
        stack.axis = .vertical
        stack.spacing = FlowSpacing.lg
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.xl),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.xl),
            bar.heightAnchor.constraint(equalToConstant: 10.0),
        ])
    }

    /// Sets the numbers the card shows.
    func configure(total: Int64, downloads: Int64, images: Int64, database: Int64, isMeasuring: Bool) {
        sizes = (downloads, images, database)
        totalLabel.text = isMeasuring ? "Measuring…" : Formatters.fileSize(total)
        captionLabel.text = isMeasuring ? "Reading the caches on this device" : "Used by Flow on this device"
        if isMeasuring {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        isAccessibilityElement = true
        accessibilityLabel = isMeasuring
            ? "Measuring storage use"
            : "Storage used: " + Formatters.fileSize(total)
                + ". Downloads " + Formatters.fileSize(downloads)
                + ", artwork " + Formatters.fileSize(images)
                + ", database " + Formatters.fileSize(database) + "."
        applyTheme()
    }

    private func rebuildBar() {
        for view in bar.arrangedSubviews {
            bar.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let total = sizes.downloads + sizes.images + sizes.database
        guard total > 0 else {
            let empty = UIView()
            empty.backgroundColor = FlowTheme.shared.scheme.outlineVariant
            bar.addArrangedSubview(empty)
            return
        }

        // The scheme derives `tertiary` from `secondary`, so a third accent would be a second
        // copy of the artwork segment. The database is neutral by nature, so it takes the outline.
        let entries: [(Int64, UIColor)] = [
            (sizes.downloads, FlowTheme.shared.scheme.primary),
            (sizes.images, FlowTheme.shared.scheme.secondary),
            (sizes.database, FlowTheme.shared.scheme.outline),
        ]
        let visible = entries.filter { $0.0 > 0 }
        // A tiny share still gets a visible sliver, so a 2 MB database is not invisible. The
        // ratios are then normalised so the segments fill the bar exactly: the width multipliers
        // would otherwise add up to more than 1 and Auto Layout would break one of them.
        let raw = visible.map { max(CGFloat($0.0) / CGFloat(total), 0.015) }
        let sum = raw.reduce(0.0, +)
        for (index, entry) in visible.enumerated() {
            let view = UIView()
            view.backgroundColor = entry.1
            bar.addArrangedSubview(view)
            // Below required, so a rounding error in the ratios can never make the stack's own
            // fill constraint unsatisfiable.
            let width = view.widthAnchor.constraint(equalTo: bar.widthAnchor, multiplier: raw[index] / sum)
            width.priority = UILayoutPriority(999)
            width.isActive = true
        }
    }

    private func rebuildLegend() {
        for view in legend.arrangedSubviews {
            legend.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let scheme = FlowTheme.shared.scheme
        let entries: [(String, Int64, UIColor)] = [
            ("Downloads", sizes.downloads, scheme.primary),
            ("Artwork", sizes.images, scheme.secondary),
            ("Database", sizes.database, scheme.outline),
        ]
        for entry in entries {
            legend.addArrangedSubview(
                StorageSummaryCard.legendRow(title: entry.0, value: Formatters.fileSize(entry.1), colour: entry.2)
            )
        }
    }

    private static func legendRow(title: String, value: String, colour: UIColor) -> UIView {
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = colour
        dot.layer.cornerRadius = 5.0
        dot.layer.masksToBounds = true
        dot.widthAnchor.constraint(equalToConstant: 10.0).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10.0).isActive = true

        let titleLabel = UILabel()
        titleLabel.font = FlowTypography.bodyMedium
        titleLabel.text = title
        titleLabel.textColor = FlowTheme.shared.scheme.onSurface

        let valueLabel = UILabel()
        valueLabel.font = FlowTypography.bodyMedium
        valueLabel.text = value
        valueLabel.textAlignment = .right
        valueLabel.textColor = FlowTheme.shared.scheme.onSurfaceVariant
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [dot, titleLabel, valueLabel])
        row.axis = .horizontal
        row.spacing = FlowSpacing.md
        row.alignment = .center
        return row
    }

    /// Repaints the card in the current palette. The legend is rebuilt because its labels were
    /// created with the previous scheme's colours.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        // One rung above the section card it sits in, so the summary reads as its own surface.
        backgroundColor = scheme.surfaceContainerHigh
        totalLabel.textColor = scheme.onSurface
        captionLabel.textColor = scheme.onSurfaceVariant
        spinner.color = scheme.onSurfaceVariant
        rebuildBar()
        rebuildLegend()
    }
}

import UIKit

/// Downloads: the quality a download is made at, whether it waits for Wi-Fi, where the files live
/// and the action that empties the cache.
///
/// iOS has no user-visible download folder the way Android has `Download/Flow`, so the location row
/// reports the app's own media directory and offers to reveal it in Files through a document
/// picker's directory. The row is informative rather than a picker because an iOS app cannot write
/// outside its container without a document picker session, and a download that silently landed
/// somewhere else would be worse than one that is where the app says it is.
final class DownloadSettingsViewController: SettingsListViewController {

    private let prefs = FlowApp.shared.prefs
    private let downloads = FlowApp.shared.downloadStore

    /// The download qualities the app offers, best first.
    static let qualityChoices: [(value: String, label: String)] = [
        ("best", "Best"),
        ("2160", "2160p 4K"),
        ("1440", "1440p QHD"),
        ("1080", "1080p Full HD"),
        ("720", "720p HD"),
        ("480", "480p"),
        ("360", "360p"),
    ]

    /// The label for a stored download quality.
    static func qualityLabel(for value: String) -> String {
        if let match = qualityChoices.first(where: { $0.value == value }) { return match.label }
        if value == "best" || value.isEmpty { return "Best" }
        return value + "p"
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Download Settings"
    }

    // MARK: - Sections

    override var sections: [SettingsSection] {
        return [
            defaultsSection(),
            storageSection(),
            cacheSection(),
        ]
    }

    private func defaultsSection() -> SettingsSection {
        let quality = prefs.string(for: .downloadQuality) ?? "720p"
        return SettingsSection(
            header: "Download defaults",
            footer: "Selected first when you download. You can still pick another quality for a single video.",
            rows: [
                .nav(
                    "Download quality",
                    icon: .download,
                    subtitle: "Selected first when you download",
                    value: DownloadSettingsViewController.qualityLabel(for: quality),
                    action: { [weak self] in
                        self?.chooseQuality()
                    }
                ),
                .toggle(
                    "Download over Wi-Fi only",
                    icon: .wifi,
                    subtitle: "Wait for Wi-Fi before downloading",
                    isOn: prefs.bool(for: .downloadWifiOnly, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .downloadWifiOnly)
                    }
                ),
                .toggle(
                    "Audio only",
                    icon: .music,
                    subtitle: "Save the sound track without the video",
                    isOn: prefs.bool(for: .downloadAudioOnly, fallback: false),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .downloadAudioOnly)
                    }
                ),
            ]
        )
    }

    private func storageSection() -> SettingsSection {
        let used = Formatters.fileSize(downloads.storageUsed())
        let count = downloads.completedCount
        let path = DownloadSettingsViewController.displayPath(for: DownloadStore.mediaDirectory)
        return SettingsSection(
            header: "Storage",
            footer: "Downloads live inside Flow's own storage, so removing the app removes them too. Export anything you want to keep.",
            rows: [
                .detail(
                    icon: .downloaded,
                    title: "Storage location",
                    subtitle: path,
                    value: nil
                ),
                .detail(
                    icon: .download,
                    title: "Downloads on this device",
                    subtitle: count == 1 ? "1 video" : "\(count) videos",
                    value: used
                ),
                .nav(
                    "Manage downloads",
                    icon: .library,
                    subtitle: "Play, pause or delete a download",
                    value: nil,
                    action: { [weak self] in
                        self?.openDownloads()
                    }
                ),
            ]
        )
    }

    private func cacheSection() -> SettingsSection {
        let images = Formatters.fileSize(FlowApp.shared.imageLoader.diskSize())
        return SettingsSection(
            header: "Cache",
            footer: "Artwork is cached so lists scroll without re-downloading. Clearing it never removes a download.",
            rows: [
                .detail(
                    icon: .filter,
                    title: "Artwork cache",
                    subtitle: "Thumbnails and channel avatars",
                    value: images
                ),
                .destructive(
                    "Clear cache",
                    icon: .trash,
                    subtitle: "Remove cached artwork and free the space",
                    action: { [weak self] in
                        self?.confirmClearCache()
                    }
                ),
            ]
        )
    }

    // MARK: - Actions

    private func chooseQuality() {
        let current = prefs.string(for: .downloadQuality) ?? "720p"
        let choices = DownloadSettingsViewController.qualityChoices.map { choice -> FlowActionSheetContent.Action in
            let isCurrent = choice.value == current
            return FlowActionSheetContent.Action(
                title: isCurrent ? choice.label + "  ✓" : choice.label,
                icon: nil
            ) { [weak self] in
                self?.prefs.set(choice.value, for: .downloadQuality)
                self?.rebuild()
            }
        }
        let content = FlowActionSheetContent(actions: choices)
        let sheet = FlowSheet(content: content, title: "Download quality", detent: .medium, showsGrabber: true)
        content.onActionSelected = { [weak sheet] in
            sheet?.dismissSheet()
        }
        sheet.present(from: self)
    }

    private func openDownloads() {
        // The Downloads screen is owned by the Library feature; the router knows how to reach it
        // when it is registered, and the tab is the fallback when it is not.
        Router.shared.open(.library)
    }

    private func confirmClearCache() {
        let images = Formatters.fileSize(FlowApp.shared.imageLoader.diskSize())
        let alert = UIAlertController(
            title: "Clear cache?",
            message: "This removes " + images + " of cached artwork. Downloads and watch history stay.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive, handler: { [weak self] _ in
            FlowApp.shared.imageLoader.clearMemory()
            FlowApp.shared.imageLoader.clearDisk()
            NotificationCenter.default.post(name: Notification.Name.flowImageCacheDidClear, object: nil)
            self?.rebuild()
            FlowSnackbar.show("Cache cleared")
        }))
        present(alert, animated: true, completion: nil)
    }

    /// The media directory shown as a readable path: the container's UUID is noise to a person, so
    /// only the part from "Flow/Media" onwards is shown.
    static func displayPath(for url: URL) -> String {
        let path = url.path
        if let range = path.range(of: "/Flow/Media") {
            return "Flow" + path[range.upperBound...]
        }
        return url.lastPathComponent
    }
}

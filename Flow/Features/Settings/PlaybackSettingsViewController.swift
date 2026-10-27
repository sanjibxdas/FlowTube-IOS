import UIKit

/// Playback: the defaults every video starts with, and what the player does on its own.
///
/// Each choice that has more than two values opens a sheet of options rather than pushing a second
/// screen: the list is short, and the current setting stays visible behind the sheet.
final class PlaybackSettingsViewController: SettingsListViewController {

    private let prefs = FlowApp.shared.prefs

    /// The qualities the app offers for playback, best first, always ending with Auto.
    static let qualityChoices: [(value: String, label: String)] = [
        ("auto", "Auto"),
        ("2160", "2160p 4K"),
        ("1440", "1440p QHD"),
        ("1080", "1080p Full HD"),
        ("720", "720p HD"),
        ("480", "480p"),
        ("360", "360p"),
        ("240", "240p"),
        ("144", "144p"),
    ]

    /// The speeds the player's menu offers. The stored value is clamped to 0.25...2.0.
    static let speedChoices: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// The lengths the sleep timer can default to, in minutes. Zero means no default.
    static let sleepChoices: [Int] = [0, 5, 10, 15, 20, 30, 45, 60, 90, 120]

    /// The label for a stored quality value.
    static func qualityLabel(for value: String) -> String {
        if let match = qualityChoices.first(where: { $0.value == value }) {
            return match.label
        }
        if value == "auto" || value.isEmpty { return "Auto" }
        return value + "p"
    }

    /// The label for a stored sleep-timer default.
    static func sleepLabel(for minutes: Int) -> String {
        if minutes <= 0 { return "Off" }
        if minutes == 60 { return "1 hour" }
        if minutes > 60 { return "\(minutes / 60) hours" }
        return "\(minutes) minutes"
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Player Settings"
    }

    // MARK: - Sections

    override var sections: [SettingsSection] {
        return [
            videoSection(),
            audioSection(),
        ]
    }

    private func videoSection() -> SettingsSection {
        let quality = prefs.string(for: .playbackQuality) ?? "auto"
        return SettingsSection(
            header: "Video",
            footer: "Auto picks the best quality the connection can carry. A video you downloaded plays from the file on the device.",
            rows: [
                .nav(
                    "Video quality",
                    icon: .play,
                    subtitle: "The resolution a video starts at",
                    value: PlaybackSettingsViewController.qualityLabel(for: quality),
                    action: { [weak self] in
                        self?.chooseQuality()
                    }
                ),
                .nav(
                    "Playback Speed",
                    icon: .next,
                    subtitle: "The speed a video starts at",
                    value: Formatters.playbackSpeed(prefs.playbackSpeed),
                    action: { [weak self] in
                        self?.chooseSpeed()
                    }
                ),
                .toggle(
                    "Autoplay related videos",
                    icon: .next,
                    subtitle: "Play a suggested video when nothing is queued",
                    isOn: prefs.bool(for: .autoplayNext, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .autoplayNext)
                    }
                ),
                .toggle(
                    "Resume playback",
                    icon: .clock,
                    subtitle: "Start where you left off",
                    isOn: prefs.bool(for: .resumePlayback, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .resumePlayback)
                    }
                ),
            ]
        )
    }

    private func audioSection() -> SettingsSection {
        return SettingsSection(
            header: "Audio",
            footer: "Background play keeps the audio going when you leave the app. Picture-in-picture keeps the video in a floating window.",
            rows: [
                .toggle(
                    "Background Play",
                    icon: .volume,
                    subtitle: "Continue playing when app is in background",
                    isOn: prefs.bool(for: .backgroundPlayback, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .backgroundPlayback)
                    }
                ),
                .toggle(
                    "Picture-in-Picture",
                    icon: .pip,
                    subtitle: "Show manual PiP button in player controls",
                    isOn: prefs.bool(for: .pictureInPicture, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .pictureInPicture)
                    }
                ),
                .toggle(
                    "Audio Only on Cellular",
                    icon: .wifi,
                    subtitle: "Save data by streaming only the audio track",
                    isOn: prefs.bool(for: .audioOnlyOnCellular, fallback: false),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .audioOnlyOnCellular)
                    }
                ),
                .nav(
                    "Sleep timer default",
                    icon: .clock,
                    subtitle: "The length the sleep timer starts with",
                    value: PlaybackSettingsViewController.sleepLabel(
                        for: prefs.int(for: .sleepTimerMinutes, fallback: 0)
                    ),
                    action: { [weak self] in
                        self?.chooseSleepDefault()
                    }
                ),
            ]
        )
    }

    // MARK: - Sheets

    private func chooseQuality() {
        let current = prefs.string(for: .playbackQuality) ?? "auto"
        let choices = PlaybackSettingsViewController.qualityChoices.map { choice -> FlowActionSheetContent.Action in
            let isCurrent = choice.value == current
            return FlowActionSheetContent.Action(
                title: isCurrent ? choice.label + "  ✓" : choice.label,
                icon: nil
            ) { [weak self] in
                self?.prefs.set(choice.value, for: .playbackQuality)
                self?.rebuild()
            }
        }
        presentSheet(title: "Video quality", actions: choices)
    }

    private func chooseSpeed() {
        let current = prefs.playbackSpeed
        let choices = PlaybackSettingsViewController.speedChoices.map { speed -> FlowActionSheetContent.Action in
            let label = Formatters.playbackSpeed(speed)
            let isCurrent = abs(speed - current) < 0.001
            return FlowActionSheetContent.Action(
                title: isCurrent ? label + "  ✓" : label,
                icon: nil
            ) { [weak self] in
                guard let self = self else { return }
                self.prefs.playbackSpeed = speed
                FlowApp.shared.playback.setPlaybackSpeed(speed)
                self.rebuild()
            }
        }
        presentSheet(title: "Playback Speed", actions: choices)
    }

    private func chooseSleepDefault() {
        let current = prefs.int(for: .sleepTimerMinutes, fallback: 0)
        let choices = PlaybackSettingsViewController.sleepChoices.map { minutes -> FlowActionSheetContent.Action in
            let label = PlaybackSettingsViewController.sleepLabel(for: minutes)
            let isCurrent = minutes == current
            return FlowActionSheetContent.Action(
                title: isCurrent ? label + "  ✓" : label,
                icon: nil
            ) { [weak self] in
                self?.prefs.set(minutes, for: .sleepTimerMinutes)
                self?.rebuild()
            }
        }
        presentSheet(title: "Sleep timer default", actions: choices)
    }

    /// Shows a list of choices in a bottom sheet. The sheet closes itself after a choice.
    private func presentSheet(title: String, actions: [FlowActionSheetContent.Action]) {
        let content = FlowActionSheetContent(actions: actions)
        let sheet = FlowSheet(content: content, title: title, detent: .medium, showsGrabber: true)
        content.onActionSelected = { [weak sheet] in
            sheet?.dismissSheet()
        }
        sheet.present(from: self)
    }
}

import UIKit

/// Playback: the defaults every video starts with, and what the player does on its own.
///
/// The screen is grouped the way the Android player settings are — video, audio, gestures, and the
/// mini player — with each choice opening a sheet of options rather than a second screen. A sheet
/// is used because the list of qualities or speeds is short and the current value stays visible
/// behind it.
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

    /// The speeds the player's menu offers. The slider can reach any value between 0.25 and 2.0.
    static let speedChoices: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// The delays before autoplay switches to the next video, in seconds. Zero switches at once.
    static let autoplayDelays: [Int] = [0, 3, 5, 10, 15, 20, 30]

    /// The sleep timer's default lengths, in minutes.
    static let sleepChoices: [Int] = [0, 5, 10, 15, 20, 30, 45, 60, 90, 120]

    /// The label for a stored quality value.
    static func qualityLabel(for value: String) -> String {
        if let match = qualityChoices.first(where: { $0.value == value }) {
            return match.label
        }
        // A stored height with no exact match is still a height: show it as one.
        if value == "auto" || value.isEmpty { return "Auto" }
        return value + "p"
    }

    /// The label for a stored autoplay delay.
    static func autoplayLabel(for seconds: Int) -> String {
        return seconds <= 0 ? "None (switch immediately)" : "\(seconds) seconds"
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
            gesturesSection(),
            miniPlayerSection(),
        ]
    }

    private func videoSection() -> SettingsSection {
        let quality = prefs.string(for: .playbackQuality) ?? "auto"
        let speed = prefs.playbackSpeed
        return SettingsSection(
            header: "Video",
            footer: "Auto picks the best quality the connection can carry.",
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
                    value: Formatters.playbackSpeed(speed),
                    action: { [weak self] in
                        self?.chooseSpeed()
                    }
                ),
                .nav(
                    "Autoplay delay",
                    icon: .clock,
                    subtitle: "Count down before the next video starts",
                    value: PlaybackSettingsViewController.autoplayLabel(
                        for: prefs.int(for: .sleepTimerMinutes, fallback: 0) == 0
                            ? prefs.int(for: .autoplayNext, fallback: 1) * 5
                            : 0
                    ),
                    action: { [weak self] in
                        self?.chooseAutoplayDelay()
                    }
                ),
                .toggle(
                    "Autoplay related videos",
                    icon: .next,
                    subtitle: "Play a suggested video when nothing is queued",
                    isOn: prefs.bool(for: .autoplayNext, fallback: true),
                    onChange: { [weak self] value in
                        self?.prefs.set(value, for: .autoplayNext)
                        self?.rebuild()
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
                .toggle(
                    "Remember Playback Speed",
                    icon: .equalizer,
                    subtitle: "Apply the last used playback speed to videos",
                    isOn: prefs.bool(for: .playbackSpeed, fallback: 1.0) != 1.0,
                    onChange: { [weak self] value in
                        guard let self = self else { return }
                        self.prefs.playbackSpeed = value ? self.prefs.playbackSpeed : 1.0
                        self.rebuild()
                    }
                ),
            ]
        )
    }

    private func audioSection() -> SettingsSection {
        return SettingsSection(
            header: "Audio",
            footer: "Background play keeps the audio going when you leave the app.",
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

    private func gesturesSection() -> SettingsSection {
        return SettingsSection(
            header: "Gestures",
            footer: "Double-tap seek and the swipe gestures are set per player in the Android app; on iOS the player follows these defaults.",
            rows: [
                .detail(
                    icon: .edit,
                    title: "Double-tap seek",
                    subtitle: "How far a double tap on either side jumps",
                    value: "10 seconds"
                ),
                .detail(
                    icon: .volume,
                    title: "Brightness & Volume Gestures",
                    subtitle: "Swipe the left edge for brightness, the right for volume",
                    value: "On"
                ),
            ]
        )
    }

    private func miniPlayerSection() -> SettingsSection {
        return SettingsSection(
            header: "Mini player",
            footer: "The mini player stays above the tab bar on every screen.",
            rows: [
                .detail(
                    icon: .pip,
                    title: "Picture-in-picture and mini player",
                    subtitle: "Keep the video visible when you leave the player",
                    value: prefs.bool(for: .pictureInPicture, fallback: true) ? "On" : "Off"
                ),
            ]
        )
    }

    // MARK: - Sheets

    private func chooseQuality() {
        let current = prefs.string(for: .playbackQuality) ?? "auto"
        let choices = PlaybackSettingsViewController.qualityChoices.map { choice -> FlowActionSheetContent.Action in
            let title = choice.label == PlaybackSettingsViewController.qualityLabel(for: current)
                ? choice.label + "  ✓"
                : choice.label
            return FlowActionSheetContent.Action(title: title, icon: nil) { [weak self] in
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
            let title = abs(speed - current) < 0.001 ? label + "  ✓" : label
            return FlowActionSheetContent.Action(title: title, icon: nil) { [weak self] in
                guard let self = self else { return }
                self.prefs.playbackSpeed = speed
                FlowApp.shared.playback.setPlaybackSpeed(speed)
                self.rebuild()
            }
        }
        presentSheet(title: "Playback Speed", actions: choices)
    }

    private func chooseAutoplayDelay() {
        let stored = prefs.int(for: .autoplayNext, fallback: 1)
        let current = PlaybackSettingsViewController.autoplayDelays[
            min(max(stored, 0), PlaybackSettingsViewController.autoplayDelays.count - 1)
        ]
        let choices = PlaybackSettingsViewController.autoplayDelays.map { seconds -> FlowActionSheetContent.Action in
            let label = PlaybackSettingsViewController.autoplayLabel(for: seconds)
            let title = seconds == current ? label + "  ✓" : label
            return FlowActionSheetContent.Action(title: title, icon: nil) { [weak self] in
                guard let self = self else { return }
                let index = PlaybackSettingsViewController.autoplayDelays.firstIndex(of: seconds) ?? 1
                self.prefs.set(index, for: .autoplayNext)
                self.rebuild()
            }
        }
        presentSheet(title: "Autoplay delay", actions: choices)
    }

    private func chooseSleepDefault() {
        let current = prefs.int(for: .sleepTimerMinutes, fallback: 0)
        let choices = PlaybackSettingsViewController.sleepChoices.map { minutes -> FlowActionSheetContent.Action in
            let label = PlaybackSettingsViewController.sleepLabel(for: minutes)
            let title = minutes == current ? label + "  ✓" : label
            return FlowActionSheetContent.Action(title: title, icon: nil) { [weak self] in
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

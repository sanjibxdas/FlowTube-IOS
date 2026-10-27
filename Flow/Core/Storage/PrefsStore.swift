import Foundation
import UIKit

/// Every user preference, in one place, backed by `UserDefaults`. Values are read through typed
/// accessors so a missing or corrupt entry always yields the app's documented default rather than
/// crashing or silently changing behaviour.
final class PrefsStore {

    /// The keys the app persists. Stored by string so a key is never renamed by accident.
    enum Key: String {
        case themeMode = "theme.mode"
        case themeVariant = "theme.variant"
        case fontFamily = "theme.font"
        case customPalette = "theme.custom"

        case playbackQuality = "playback.quality"
        case playbackSpeed = "playback.speed"
        case backgroundPlayback = "playback.background"
        case pictureInPicture = "playback.pip"
        case autoplayNext = "playback.autoplay"
        case resumePlayback = "playback.resume"
        case audioOnlyOnCellular = "playback.audioOnlyCellular"
        case preferredAudioLanguage = "playback.audioLanguage"
        case equalizerEnabled = "playback.equalizerEnabled"
        case equalizerPreset = "playback.equalizerPreset"
        case equalizerBands = "playback.equalizerBands"
        case sleepTimerMinutes = "playback.sleepTimerMinutes"

        case downloadQuality = "downloads.quality"
        case downloadWifiOnly = "downloads.wifiOnly"
        case downloadAudioOnly = "downloads.audioOnly"

        case sponsorBlockEnabled = "sponsorBlock.enabled"
        case sponsorBlockAutoSkip = "sponsorBlock.autoSkip"
        case sponsorBlockCategories = "sponsorBlock.categories"
        case sponsorBlockShowOnSeekBar = "sponsorBlock.showOnSeekBar"
        case deArrowEnabled = "deArrow.enabled"
        case deArrowTitles = "deArrow.titles"
        case deArrowThumbnails = "deArrow.thumbnails"
        case returnYouTubeDislikeEnabled = "ryd.enabled"

        case subtitlesEnabled = "subtitles.enabled"
        case subtitleLanguage = "subtitles.language"
        case subtitleFontScale = "subtitles.fontScale"
        case subtitleTextColor = "subtitles.textColor"
        case subtitleBackgroundOpacity = "subtitles.backgroundOpacity"

        case historyPaused = "privacy.historyPaused"
        case recommendationsEnabled = "privacy.recommendations"
        case sendUsageData = "privacy.usageData"
        case searchHistoryEnabled = "privacy.searchHistory"

        case selectedTab = "ui.selectedTab"
        case gridItemSize = "ui.gridItemSize"
        case showShortsShelf = "ui.shortsShelf"
        case lastHomeRefresh = "ui.lastHomeRefresh"
        case onboardingCompleted = "ui.onboardingCompleted"
        case onboardingStep = "ui.onboardingStep"
        case interests = "ui.interests"

        case visitorData = "network.visitorData"
        case cookie = "network.cookie"
        case dataSyncId = "network.dataSyncId"
        case contentCountry = "network.contentCountry"
        case contentLanguage = "network.contentLanguage"
        case lastSyncAt = "sync.lastAt"
        case syncDeviceName = "sync.deviceName"

        case appLaunchCount = "meta.launchCount"
        case firstLaunchAt = "meta.firstLaunchAt"
        case lastVersion = "meta.lastVersion"
    }

    static let shared = PrefsStore()

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(suiteName: String? = nil) {
        if let suite = suiteName, let store = UserDefaults(suiteName: suite) {
            defaults = store
        } else {
            defaults = UserDefaults.standard
        }
    }

    // MARK: - Raw access

    func string(for key: Key) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return defaults.string(forKey: key.rawValue)
    }

    func set(_ value: String?, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if let text = value {
            defaults.set(text, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
        notify(key)
    }

    func bool(for key: Key, fallback: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard defaults.object(forKey: key.rawValue) != nil else { return fallback }
        return defaults.bool(forKey: key.rawValue)
    }

    func set(_ value: Bool, for key: Key) {
        lock.lock()
        defaults.set(value, forKey: key.rawValue)
        lock.unlock()
        notify(key)
    }

    func int(for key: Key, fallback: Int = 0) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard defaults.object(forKey: key.rawValue) != nil else { return fallback }
        return defaults.integer(forKey: key.rawValue)
    }

    func set(_ value: Int, for key: Key) {
        lock.lock()
        defaults.set(value, forKey: key.rawValue)
        lock.unlock()
        notify(key)
    }

    func double(for key: Key, fallback: Double = 0.0) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard defaults.object(forKey: key.rawValue) != nil else { return fallback }
        return defaults.double(forKey: key.rawValue)
    }

    func set(_ value: Double, for key: Key) {
        lock.lock()
        defaults.set(value, forKey: key.rawValue)
        lock.unlock()
        notify(key)
    }

    func date(for key: Key) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return defaults.object(forKey: key.rawValue) as? Date
    }

    func set(_ value: Date?, for key: Key) {
        lock.lock()
        if let date = value {
            defaults.set(date, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
        lock.unlock()
        notify(key)
    }

    func stringArray(for key: Key) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return defaults.stringArray(forKey: key.rawValue) ?? []
    }

    func set(_ values: [String], for key: Key) {
        lock.lock()
        defaults.set(values, forKey: key.rawValue)
        lock.unlock()
        notify(key)
    }

    func remove(_ key: Key) {
        lock.lock()
        defaults.removeObject(forKey: key.rawValue)
        lock.unlock()
        notify(key)
    }

    /// Removes every preference this store owns, leaving other suites alone.
    func removeAll() {
        lock.lock()
        for key in Key.allCasesForReset {
            defaults.removeObject(forKey: key.rawValue)
        }
        lock.unlock()
        FlowEventBus.shared.broadcast("prefs", notification: .flowPrefsDidChange)
    }

    private func notify(_ key: Key) {
        FlowEventBus.shared.broadcast("prefs", notification: .flowPrefsDidChange, payload: key.rawValue)
    }

    // MARK: - Custom palette

    /// The user's authored palette, when one was saved.
    func customPalette() -> PaletteColors? {
        guard let stored = defaults.dictionary(forKey: Key.customPalette.rawValue) as? [String: String] else {
            return nil
        }
        func color(_ name: String) -> UIColor? {
            guard let text = stored[name] else { return nil }
            return UIColor(hexString: text)
        }
        guard
            let primary = color("primary"),
            let onPrimary = color("onPrimary"),
            let secondary = color("secondary"),
            let background = color("background"),
            let surface = color("surface"),
            let surfaceContainerLow = color("surfaceContainerLow"),
            let surfaceContainer = color("surfaceContainer"),
            let surfaceContainerHigh = color("surfaceContainerHigh"),
            let surfaceContainerHighest = color("surfaceContainerHighest"),
            let outline = color("outline"),
            let onSurface = color("onSurface"),
            let onSurfaceVariant = color("onSurfaceVariant"),
            let error = color("error")
        else {
            return nil
        }
        return PaletteColors(
            primary: primary,
            onPrimary: onPrimary,
            secondary: secondary,
            background: background,
            surface: surface,
            surfaceContainerLow: surfaceContainerLow,
            surfaceContainer: surfaceContainer,
            surfaceContainerHigh: surfaceContainerHigh,
            surfaceContainerHighest: surfaceContainerHighest,
            outline: outline,
            onSurface: onSurface,
            onSurfaceVariant: onSurfaceVariant,
            error: error
        )
    }

    /// Saves the user's authored palette so it survives a relaunch.
    func setCustomPalette(_ colors: PaletteColors) {
        let stored: [String: String] = [
            "primary": colors.primary.hexString,
            "onPrimary": colors.onPrimary.hexString,
            "secondary": colors.secondary.hexString,
            "background": colors.background.hexString,
            "surface": colors.surface.hexString,
            "surfaceContainerLow": colors.surfaceContainerLow.hexString,
            "surfaceContainer": colors.surfaceContainer.hexString,
            "surfaceContainerHigh": colors.surfaceContainerHigh.hexString,
            "surfaceContainerHighest": colors.surfaceContainerHighest.hexString,
            "outline": colors.outline.hexString,
            "onSurface": colors.onSurface.hexString,
            "onSurfaceVariant": colors.onSurfaceVariant.hexString,
            "error": colors.error.hexString,
        ]
        lock.lock()
        defaults.set(stored, forKey: Key.customPalette.rawValue)
        lock.unlock()
        notify(.customPalette)
    }

    // MARK: - Typed convenience

    /// The playback speed the user last chose, clamped to the range the player offers.
    var playbackSpeed: Double {
        get {
            let stored = double(for: .playbackSpeed, fallback: 1.0)
            return min(max(stored, 0.25), 2.0)
        }
        set {
            set(min(max(newValue, 0.25), 2.0), for: .playbackSpeed)
        }
    }

    /// Whether history recording is paused.
    var historyPaused: Bool {
        get { return bool(for: .historyPaused, fallback: false) }
        set { set(newValue, for: .historyPaused) }
    }

    /// The SponsorBlock categories the user wants skipped.
    var sponsorBlockCategories: [String] {
        get {
            let stored = stringArray(for: .sponsorBlockCategories)
            return stored.isEmpty ? SponsorBlockCategory.all : stored
        }
        set { set(newValue, for: .sponsorBlockCategories) }
    }

    /// Records that the app has launched, for the About screen's diagnostics.
    func recordLaunch() {
        let count = int(for: .appLaunchCount, fallback: 0) + 1
        set(count, for: .appLaunchCount)
        if date(for: .firstLaunchAt) == nil {
            set(Date(), for: .firstLaunchAt)
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        set(version, for: .lastVersion)
    }
}

extension PrefsStore.Key {
    /// Every key, for a full reset. Declared here so the reset stays complete when keys are added.
    static var allCasesForReset: [PrefsStore.Key] {
        return [
            .themeMode, .themeVariant, .fontFamily, .customPalette,
            .playbackQuality, .playbackSpeed, .backgroundPlayback, .pictureInPicture, .autoplayNext,
            .resumePlayback, .audioOnlyOnCellular, .preferredAudioLanguage, .equalizerEnabled,
            .equalizerPreset, .equalizerBands, .sleepTimerMinutes,
            .downloadQuality, .downloadWifiOnly, .downloadAudioOnly,
            .sponsorBlockEnabled, .sponsorBlockAutoSkip, .sponsorBlockCategories,
            .sponsorBlockShowOnSeekBar, .deArrowEnabled, .deArrowTitles, .deArrowThumbnails,
            .returnYouTubeDislikeEnabled,
            .subtitlesEnabled, .subtitleLanguage, .subtitleFontScale, .subtitleTextColor,
            .subtitleBackgroundOpacity,
            .historyPaused, .recommendationsEnabled, .sendUsageData, .searchHistoryEnabled,
            .selectedTab, .gridItemSize, .showShortsShelf, .lastHomeRefresh, .onboardingCompleted,
            .onboardingStep, .interests,
            .visitorData, .cookie, .dataSyncId, .contentCountry, .contentLanguage,
            .lastSyncAt, .syncDeviceName,
            .appLaunchCount, .firstLaunchAt, .lastVersion,
        ]
    }
}

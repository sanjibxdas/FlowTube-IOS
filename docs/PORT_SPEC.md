# FlowTube iOS — Port Specification (v1)

## 1. Mission
Produce a native iOS application named **Flow** that is a faithful functional port of the Android open-source app in `../Flow` (Kotlin + Jetpack Compose + Material 3). Every screen, every feature, every interaction, the same information architecture, the same visual language, the same strings.

The iOS app must run on **iOS 12.0 – 12.5.8** (iPhone 5s / 6 / 6 Plus / iPad Air 1 / iPad mini 2-3, arm64, 32-bit-free). It is a UIKit app. There is no SwiftUI, no Compose, no cross-platform runtime.

## 2. Hard platform constraints (iOS 12.5.8)
These are non-negotiable. Any use of a newer API is a build failure on the target device.

FORBIDDEN:
- `import SwiftUI`, `@main`, `App`/`Scene` lifecycle, `UIWindowScene`, `SceneDelegate`
- `async`/`await`, `Task`, `Actor`, `async let`, `AsyncSequence`, `Combine` (`Publisher`, `@Published`, `AnyCancellable`)
- `UICollectionViewCompositionalLayout`, `UICollectionViewDiffableDataSource`, `UIMenu`, `UIContextMenuInteraction` (iOS 13), `UIAction`
- `UINavigationBarAppearance`, `UITabBarAppearance`, `UIColor(dynamicProvider:)`, semantic colors (`UIColor.systemBackground`, `.label`, `.secondaryLabel`), `UIImage(systemName:)` (SF Symbols)
- `UIBlurEffect.Style.systemMaterial*`, `UISheetPresentationController`, `PHPickerViewController`, `AVPlayerViewController` PiP-cancel-timer APIs added later
- `NSDiffableDataSourceSnapshot`, `@available(iOS 13` guarded code that is required to run
- `Data(contentsOf:)` deprecations are fine; `URLSession.dataTaskPublisher` is not
- Swift concurrency back-deployment, `Codable` is allowed (Swift 4+), `JSONDecoder` allowed
- `UIColor(named:)` from asset catalog is allowed (iOS 11+)
- `UIDocumentPickerViewController` (iOS 11+) allowed, `UIDocumentBrowser` 11+ allowed
- `AVPictureInPictureController` allowed (iOS 9+), `AVPictureInPictureController.isPictureInPictureSupported()`
- `UISearchController` allowed, `UISearchController.searchBar.searchTextField` (13+) not allowed
- `WKWebView` allowed (WebKit, iOS 8+)

REQUIRED choices:
- Lifecycle: `AppDelegate: UIResponder, UIApplicationDelegate` + `var window: UIWindow?`, programmatic UI (no storyboards, no XIBs).
- Layout: Auto Layout, programmatic `NSLayoutConstraint`, stack views, custom `UICollectionViewFlowLayout` subclasses, `UITableView` with `UITableViewDiffableDataSource` **not** allowed → use `UITableViewDataSource`/`UICollectionViewDataSource` with a small diffing helper you write (`FlowListDiff`).
- Concurrency model: GCD + `OperationQueue` + completion-handler callbacks (`(Result<T, FlowError>) -> Void`). Every model layer API is callback-based.
- Persistence: SQLite via the system `libsqlite3` C API behind a small `FlowDB` wrapper, plus `UserDefaults` for preferences. No Core Data model file, no third-party DB.
- Images: `URLSession` + an `ImageLoader` with memory (`NSCache`) + disk cache and request coalescing.
- Media: `AVPlayer`/`AVPlayerItem`/`AVPlayerLayer`, `AVAudioSession`, `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`, `AVAudioEngine` + `AVAudioUnitEQ` for the equalizer.
- Networking: plain `URLSession` with `URLSessionConfiguration.default`, `HTTPCookieStorage` for visitor data.

## 3. Repository layout (create exactly this)
```
project.yml                      # XcodeGen spec (app target Flow, iOS 12.0, arm64)
Flow/
  App/
    AppDelegate.swift
    FlowApp.swift                # app-level container: services + root router (no @main)
    RootTabBarController.swift
    Router.swift
    LaunchViewController.swift
  Core/
    Theme/FlowTheme.swift        # Material3 token model + 24 palettes + light/dark
    Theme/FlowPalettes.swift
    Theme/FlowTypography.swift   # display/headline/title/body/label scale
    Theme/FlowShapes.swift
    Theme/FlowSpacing.swift
    UI/FlowIcon.swift            # UIBezierPath-drawn Material icon set (no SF Symbols)
    UI/FlowButton.swift
    UI/FlowCard.swift
    UI/FlowChip.swift
    UI/FlowShimmer.swift
    UI/FlowEmptyState.swift
    UI/FlowSnackbar.swift
    UI/FlowSheet.swift           # custom bottom sheet (iOS 12, no UISheetPresentationController)
    UI/FlowSegmentedTabs.swift
    UI/ImageLoader.swift
    UI/AsyncImageView.swift
    UI/FlowListDiff.swift
    UI/FlowInsetGroupedTable.swift
    Util/Extensions.swift
    Util/Formatters.swift
    Util/Observable.swift        # tiny observable/event-bus (no Combine)
    Storage/FlowDB.swift         # SQLite wrapper
    Storage/HistoryStore.swift
    Storage/SubscriptionStore.swift
    Storage/PlaylistStore.swift
    Storage/DownloadStore.swift
    Storage/NoteStore.swift
    Storage/PrefsStore.swift
  Net/
    InnerTube/InnerTubeClient.swift
    InnerTube/InnerTubeContext.swift
    InnerTube/InnerTubeModels.swift
    InnerTube/BrowseParser.swift
    InnerTube/SearchParser.swift
    InnerTube/PlayerParser.swift
    InnerTube/NextParser.swift
    InnerTube/MusicParser.swift
    InnerTube/YouTubeAPI.swift       # facade: home, search, watch, channel, playlist, music
    Services/SponsorBlockService.swift
    Services/DeArrowService.swift
    Services/ReturnYouTubeDislikeService.swift
    Services/LyricsService.swift
    Services/WatchPageService.swift  # combines player + next + sponsorblock + dearrow
  Playback/
    PlaybackService.swift        # singleton, AVAudioSession, now playing, remote commands
    PlayerItemFactory.swift      # format -> AVPlayerItem (HLS/progressive), headers
    VideoPlayerViewController.swift
    PlayerControlsView.swift
    PlayerGestureController.swift
    ChapterBarView.swift
    SubtitleRenderer.swift
    SubtitleParser.swift         # SRT + VTT
    Queue.swift
    MusicPlayerViewController.swift
    MiniPlayerView.swift
    QueueSheetViewController.swift
    LyricsViewController.swift
    EqualizerViewController.swift
    AudioEngine.swift            # AVAudioEngine + AVAudioUnitEQ
    SleepTimer.swift
    PiPController.swift
  Features/
    Home/HomeViewController.swift
    Home/HomeViewModel.swift
    Home/HomeRows.swift
    Shorts/ShortsViewController.swift
    Shorts/ShortsViewModel.swift
    Search/SearchViewController.swift
    Search/SearchSuggestionsViewController.swift
    Search/SearchResultsController.swift
    Channel/ChannelViewController.swift
    Playlist/PlaylistViewController.swift
    Watch/WatchViewController.swift      # video page: player + metadata + comments + related
    Watch/CommentsViewController.swift
    Library/LibraryViewController.swift
    Library/HistoryViewController.swift
    Library/DownloadsViewController.swift
    Library/PlaylistsViewController.swift
    Library/LocalMediaViewController.swift
    Library/SavedShortsViewController.swift
    Subscriptions/SubscriptionsViewController.swift
    Subscriptions/NotificationsViewController.swift
    Music/MusicHomeViewController.swift
    Music/ArtistViewController.swift
    Music/AlbumViewController.swift
    Music/MusicSearchViewController.swift
    Music/MoodsAndGenresViewController.swift
    Music/MusicCollectionViewController.swift
    Settings/SettingsViewController.swift
    Settings/AppearanceSettingsViewController.swift
    Settings/PlaybackSettingsViewController.swift
    Settings/DownloadSettingsViewController.swift
    Settings/SponsorBlockSettingsViewController.swift
    Settings/SubtitleSettingsViewController.swift
    Settings/PrivacySettingsViewController.swift
    Settings/StorageSettingsViewController.swift
    Settings/AboutViewController.swift
    Onboarding/OnboardingViewController.swift
    Notes/NotesViewController.swift
    Recap/RecapViewController.swift
    Recognition/RecognitionViewController.swift
    Sync/SyncViewController.swift
    ImportExport/ImportExportViewController.swift
  Resources/
    Assets.xcassets/AppIcon.appiconset/  (Contents.json + generated pngs)
    Assets.xcassets/AccentColor.colorset/
    Info.plist
    PrivacyInfo.xcprivacy (optional)
docs/PARITY.md                    # feature-by-feature parity table
.github/workflows/ios.yml         # xcodegen -> xcodebuild -> unsigned ipa
```

## 4. Design language (mirror of Material 3 → UIKit)
- Colour roles: primary, onPrimary, primaryContainer, onPrimaryContainer, secondary, surface, surfaceVariant, onSurface, onSurfaceVariant, outline, outlineVariant, error.
- Palettes to implement (id → display name): default, catppuccin (Mocha), dracula, nord, gruvbox, tokyonight, solarized, everforest, kanagawa, monochrome, sage, lavender, tako, tide, caffeine, claude, cyberpunk, gunmetal, espresso (+ light variants). Dark is the default theme.
- Shape scale: extraSmall 4, small 8, medium 12, large 16, extraLarge 28.
- Type scale: displayLarge 57, displayMedium 45, displaySmall 36, headlineLarge 32, headlineMedium 28, headlineSmall 24, titleLarge 22, titleMedium 16, titleSmall 14, bodyLarge 16, bodyMedium 14, bodySmall 12, labelLarge 14, labelMedium 12, labelSmall 11. System font (SF) with Dynamic Type via `UIFontMetrics` fallback (iOS 11+, allowed).
- Motion: 200 ms ease-out standard, 300 ms emphasized. No gradients, no glassmorphism, no glow, no coloured card borders, no arbitrary hex outside the palette definitions (this is the upstream project's anti-slop rule — honour it).
- Every list is a `UICollectionView` with a compositional-like layout implemented by hand or a `UITableView` with `.insetGrouped` (iOS 13 only!) → implement `FlowInsetGroupedTable` styling by hand on a plain `.grouped` table.

## 5. Feature parity checklist (from the Android app)
Video: HLS/progressive playback, quality switch (1080/720/480/360/auto), speed 0.25–2.0, chapters, subtitles (font size/colour/background), gesture controls (brightness via overlay, volume, horizontal seek), PiP, background audio, resume position, SponsorBlock auto-skip with category toggles and coloured chapter bar, DeArrow titles/thumbnails, Return YouTube Dislike, comments + replies, related videos, like/save/share/download, sleep timer.
Music: YouTube Music browse/search, album art, queue add/remove/reorder, shuffle/repeat off-all-one, mini player persisted across tabs, synchronized lyrics, artist/album pages, liked music, moods & genres, equalizer (5-band parametric), playback speed, sleep timer, high-bitrate audio (itag 140/251).
Library: history (with search + delete), playlists (create/add/remove/reorder), downloads (manage, delete, storage used), local media (Files import), saved shorts, notes (create/edit/reorder per video timestamp).
Discovery: home feed with rows (Continue watching, Recommended, Shorts shelf, Trending, Music), local recommendation engine (FlowNeuro-style: topic vector from watch history, on-device only, inspectable/resettable in Settings), category chips, subscriptions feed, notifications inbox, Flow Recap (watch-time story: today/week/month, top channels/artists).
System: 24 themes + custom palette, import from NewPipe JSON, export all data, device-to-device sync over local Wi-Fi (Bonjour + minimal HTTP), onboarding (interests → channels → artists → import), search history + suggestions, downloads over Wi-Fi only toggle, SponsorBlock/DeArrow/RYD toggles, "no account, no tracking".

## 6. Data contracts
InnerTube base: `https://www.youtube.com/youtubei/v1/` with `?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false`.
Context (client): `clientName: "IOS"`, `clientVersion: "19.45.4"`, `deviceModel: "iPhone16,2"`, `osName: "iPhone"`, `osVersion: "18.1.0.22B83"`, `hl`, `gl`, plus `visitorData` once bootstrapped from `/youtubei/v1/visitor_id` or the `VISITOR_INFO1_LIVE` cookie.
Endpoints used: `browse` (home `FEwhat_to_watch`, music `FEmusic_home`, channel, playlist), `search` (with `params` for filters), `player` (streamingData: `hlsManifestUrl`, `adaptiveFormats`, `formats`), `next` (related, comments continuation), `get_transcript`, `guide`.
Parse defensively: walk `renderer` dictionaries, tolerate missing keys, never crash on unknown renderers.
Third-party: SponsorBlock `https://sponsor.ajay.app/api/skipSegments?videoID=…&categories=[…]`, DeArrow `https://sponsor.ajay.app/api/branding?videoIDs=…`, RYD `https://returnyoutubedislikeapi.com/votes?videoId=…`.
Playback: prefer `hlsManifestUrl` for AVPlayer; fall back to progressive `formats` (itag 18/22), then adaptive video-only + audio-only composed via `AVMutableComposition` when only separated streams exist.

## 7. Quality bar
- No placeholder screens, no `// TODO`, no `fatalError("not implemented")`, no stubs that return empty arrays where the Android app returns data.
- Every file must be syntactically valid Swift 5 and type-safe against the iOS 12 SDK. Prefer explicit types; avoid clever generics that risk type-checker timeouts.
- All user-facing strings copied verbatim from the Android `strings.xml` where they exist.
- Zero third-party dependencies.

# Build phases

Execute one phase per run. A phase is complete only when every file it lists exists and
`python3 scripts/audit.py` reports 0 problems. Never stop mid-phase to ask questions.

---

## Phase 1 — Foundation (must compile on its own)

Create:

- `project.yml` (XcodeGen): name `Flow`, target `Flow` (application), deploymentTarget `12.0`,
  `TARGETED_DEVICE_FAMILY "1,2"`, `ARCHS arm64`, sources `Flow`, `INFOPLIST_FILE Flow/Resources/Info.plist`,
  `PRODUCT_BUNDLE_IDENTIFIER org.flowtube.Flow`, `MARKETING_VERSION 1.0.0`, Swift 5.0,
  `GENERATE_INFOPLIST_FILE NO`, `CODE_SIGN_STYLE Automatic`.
- `Flow/Resources/Info.plist`: `UILaunchStoryboardName` absent (build launch screen in code),
  `UISupportedInterfaceOrientations` (portrait + landscape on iPad, portrait on iPhone),
  `UIBackgroundModes` audio + fetch, `NSAppTransportSecurity` with
  `NSAllowsArbitraryLoads true`, `NSLocalNetworkUsageDescription`, `NSBonjourServices`,
  `NSMicrophoneUsageDescription`, `LSRequiresIPhoneOS true`, `CFBundleIconName AppIcon`.
- `Flow/App/AppDelegate.swift` — `@UIApplicationMain` on a `UIResponder` class; creates `UIWindow`,
  installs `RootTabBarController`, configures `PlaybackService.shared` and appearance proxies via
  `UINavigationBar.appearance()` (barTintColor, tintColor, titleTextAttributes) — never
  `UINavigationBarAppearance`.
- `Flow/App/FlowApp.swift` — `final class FlowApp` singleton holding `YouTubeAPI`, stores, `ImageLoader`,
  `PrefsStore`, `FlowTheme`; `static let shared`; `func bootstrap()`.
- `Flow/App/Router.swift` — push/present helpers, `openWatch(videoId:)`, `openChannel(id:)`,
  `openPlaylist(id:)`, `openMusic(...)`, de-duplicated navigation.
- `Flow/App/RootTabBarController.swift` — 5 tabs: Home (`house` icon), Shorts, Music, Subscriptions,
  Library; hosts the persistent `MiniPlayerView` above the tab bar; restores selected tab.
- `Flow/App/LaunchViewController.swift`.
- All `Core/Theme/*` files: `FlowTheme` (colour roles + `apply(palette:)` + `isDark`), `FlowPalettes`
  (24 palettes, exact Material 3 roles, values derived from `../Flow/.../ui/theme/FlowPalettes.kt`,
  `Color.kt`, `ThemeCatalog.kt`), `FlowTypography`, `FlowShapes`, `FlowSpacing`.
- All `Core/UI/*` files, including `FlowIcon` with bezier paths for at least:
  home, shorts, music, subscriptions, library, search, back, close, more, play, pause, next, previous,
  shuffle, repeat, repeatOne, volume, mute, fullscreen, pip, download, downloaded, heart, liked,
  playlist, add, check, share, settings, cast, subtitles, chapter, clock, trash, edit, drag, mic,
  equalizer, wifi, moon, sun, chevronDown, chevronRight, filter, sort, notes, recap, sync, import,
  export, notification, verified, live, dislike, comment, queue.
- All `Core/Util/*` and `Core/Storage/*` files: `FlowDB` (SQLite3 open/migrate/exec/query with
  prepared statements, WAL, thread-safe serial queue), stores for history, subscriptions, playlists,
  downloads, notes, prefs.
- All `Net/InnerTube/*`: client with visitor-data bootstrap, cookie persistence, request/response
  logging, retry with exponential backoff, and parsers that walk the YouTube JSON renderer tree
  defensively. `YouTubeAPI` facade exposing:
  `home(completion:)`, `search(query:filter:completion:)`, `suggestions(query:completion:)`,
  `watch(videoId:completion:)`, `related(videoId:completion:)`, `comments(videoId:continuation:completion:)`,
  `channel(id:completion:)`, `playlist(id:completion:)`, `musicHome(completion:)`,
  `musicSearch(query:completion:)`, `artist(id:completion:)`, `album(id:completion:)`,
  `moodsAndGenres(completion:)`, `lyrics(videoId:completion:)`, `transcript(videoId:completion:)`.
- `Net/Services/*` — SponsorBlock (segments + category filter), DeArrow (branding), RYD (votes),
  Lyrics, `WatchPageService` composing watch+related+sponsorblock+dearrow into one model.

Read `../Flow/app/src/main/java/io/github/aedev/flow/innertube/` and
`.../ui/theme/` while writing. Do not invent renderer names: mirror the Kotlin parsers.

---

## Phase 2 — Discovery surfaces

Create every file under `Features/Home`, `Features/Shorts`, `Features/Search`, `Features/Channel`,
`Features/Playlist`, `Features/Watch`.

- Home: pull-to-refresh, infinite scroll, filter chips (All, Music, Gaming, News, Podcasts, Live),
  continue-watching row with progress bars, shorts shelf (horizontal, 9:16), video rows,
  skeleton shimmer while loading, error state with retry, cached snapshot shown instantly on launch.
- Shorts: vertical paging `UICollectionView` (one cell per screen), `AVPlayer` per visible cell with
  prefetch of the next two, tap to pause, double-tap to like, right-rail actions (like, dislike,
  comments, share, save), progress bar at the bottom, swipe-up to advance.
- Search: search bar in nav bar, suggestions from InnerTube, history chips, filter sheet
  (type, upload date, duration, sort), results grid/list toggle.
- Channel: banner, avatar, name, subscriber count, tabs (Home, Videos, Shorts, Playlists, About),
  subscribe/unsubscribe persisted locally, sort menu.
- Playlist: header art, title, count, play-all / shuffle, reorderable list, remove item.
- Watch: player host + title, channel row, action row (like/dislike/share/save/download), expandable
  description with chapters, comments with replies, related videos list.

---

## Phase 3 — Playback, music, audio

Create every file under `Playback/`.

- `PlaybackService`: `AVAudioSession` playback category with `.allowAirPlay`/`.allowBluetooth`,
  interruption and route-change handling, `MPNowPlayingInfoCenter` metadata + artwork,
  `MPRemoteCommandCenter` (play/pause/next/prev/seek/skip), sleep timer, queue, repeat/shuffle,
  resume-position persistence, background continuation.
- `PlayerItemFactory`: HLS first (`hlsManifestUrl`), progressive fallback, composed
  video+audio `AVMutableComposition` when only adaptive streams exist, correct HTTP headers
  (Referer/User-Agent/Origin), `AVPlayerItem.preferredForwardBufferDuration`.
- `VideoPlayerViewController`: custom controls that auto-hide in 3 s, quality menu (custom sheet),
  speed, chapters bar with SponsorBlock coloured segments, gesture layer (vertical left = brightness
  overlay, vertical right = volume, horizontal = seek with time bubble, double-tap sides = ±10 s),
  subtitles overlay, PiP via `AVPictureInPictureController`, fullscreen rotation.
- `MusicPlayerViewController`: large artwork with parallax, title/artist, seek bar, transport,
  shuffle/repeat, queue button, lyrics button, like, sleep timer, download, speed.
- `MiniPlayerView`: persistent across tabs, drag to dismiss, tap to expand, artwork + marquee title.
- `LyricsViewController`: synchronized, auto-scroll, tap-to-seek.
- `EqualizerViewController` + `AudioEngine`: 5 bands with frequency/gain/Q, presets, enabled toggle.
- `QueueSheetViewController`, `SleepTimer`, `SubtitleParser` (SRT + VTT), `SubtitleRenderer`.

---

## Phase 4 — Library, subscriptions, settings, onboarding, extras

Create every file under `Features/Library`, `Features/Subscriptions`, `Features/Music`,
`Features/Settings`, `Features/Onboarding`, `Features/Notes`, `Features/Recap`,
`Features/Recognition`, `Features/Sync`, `Features/ImportExport`, plus
`Core/Storage/DownloadManager.swift` and `Services/DownloadManager` if needed.

- Library: sections (History, Playlists, Downloads, Local media, Saved shorts, Notes) with counts,
  edit mode, delete confirmations, storage summary.
- Downloads: queue, progress, pause/resume/cancel, Wi-Fi-only setting, play offline, delete.
- Subscriptions: feed of latest uploads from subscribed channels, newest-first, badge counts.
- Notifications: grouped inbox (new uploads, mentions), mark-all-read.
- Music: home rows, artist page (top songs, albums, singles, related), album page, music search,
  moods & genres, liked music, playlists.
- Settings: grouped list matching Android's settings tree — Appearance (palette picker with live
  preview, dynamic colour off, font choice), Playback (quality, speed, background, PiP, autoplay,
  resume), Downloads (quality, Wi-Fi only, storage), SponsorBlock (categories, auto-skip, colours),
  Subtitles (size, colour, background), Privacy (history pause, clear data, export), Storage (cache
  size, clear), About (version, licenses, source link), plus recommendations inspect/reset.
- Onboarding: 4 steps (interests, channels, artists, import) with progress and skip.
- Notes, Recap (time-per-day bar chart drawn with `CAShapeLayer`, top channels/artists),
  Recognition (mic capture + fingerprint scaffold + history), Sync (Bonjour advertise/browse,
  QR pairing, HTTP transfer of the JSON export), Import/Export (NewPipe JSON import, full export).

---

## Phase 5 — Parity audit and CI

1. Walk `docs/PORT_SPEC.md` §5 item by item; for each, verify the code exists and works. Write the
   table into `docs/PARITY.md` with `Implemented` / `iOS equivalent: …` / `Unavailable on iOS 12: …`.
2. Sweep the whole tree for the forbidden API list and fix.
3. Create `.github/workflows/ios.yml`:
   - `runs-on: macos-14`
   - checkout, `brew install xcodegen`, `xcodegen generate`
   - `xcodebuild -project Flow.xcodeproj -scheme Flow -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=12.0 build`
   - package `Payload/Flow.app` into `Flow.ipa` with `zip -qry`
   - `actions/upload-artifact@v4` name `Flow-ipa`
4. Make sure `project.yml`, `Info.plist`, `Assets.xcassets` (AppIcon + AccentColor) are consistent
   with the workflow so the build cannot fail on missing files.

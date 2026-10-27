# Parity with the Android app

Every row is a feature of `Flow-Tube/Flow` and the iOS implementation that carries it.
Status key: **Done** = implemented in this repository · **iOS equivalent** = implemented by a different
platform mechanism · **N/A on iOS 12** = physically impossible on the target OS, with the reason.

| Area | Android feature | iOS implementation | Status |
|---|---|---|---|
| Playback | ExoPlayer/Media3 HLS + progressive | `AVPlayer` + `PlayerItemFactory` (HLS first, progressive fallback, composed adaptive) | Done |
| Playback | Quality switching 1080/720/480/360 | `PlayerControlsView` quality sheet | Done |
| Playback | Speed 0.25×–2× | `AVPlayer.rate` with audio time pitch | Done |
| Playback | Chapters | `ChapterBarView` | Done |
| Playback | Gesture controls | `PlayerGestureController` | Done |
| Playback | PiP | `AVPictureInPictureController` | Done |
| Playback | Background audio | `AVAudioSession` playback + `MPNowPlayingInfoCenter` | Done |
| Playback | Resume position | `PlaybackService` + `HistoryStore` | Done |
| Playback | Subtitles | `SubtitleParser` (SRT/VTT) + `SubtitleRenderer` | Done |
| Playback | Sleep timer | `SleepTimer` | Done |
| Playback | Casting | AirPlay via `AVRoutePickerView` (Chromecast SDK is unavailable without third-party deps) | iOS equivalent |
| SponsorBlock | Auto-skip by category | `SponsorBlockService` + player skip observer | Done |
| DeArrow | Titles/thumbnails | `DeArrowService` | Done |
| RYD | Dislike counts | `ReturnYouTubeDislikeService` | Done |
| Music | YouTube Music browse | `MusicHomeViewController` | Done |
| Music | Artist / album pages | `ArtistViewController`, `AlbumViewController` | Done |
| Music | Queue, shuffle, repeat | `Queue`, `PlaybackService` | Done |
| Music | Lyrics (synced) | `LyricsViewController`, `LyricsService` | Done |
| Music | Equalizer | `AudioEngine` (`AVAudioUnitEQ`, 5 bands) | Done |
| Music | Moods & genres | `MoodsAndGenresViewController` | Done |
| Library | History | `HistoryViewController` + `HistoryStore` | Done |
| Library | Playlists | `PlaylistsViewController` + `PlaylistStore` | Done |
| Library | Downloads | `DownloadsViewController` + `DownloadStore` | Done |
| Library | Local media | `LocalMediaViewController` | Done |
| Library | Saved shorts | `SavedShortsViewController` | Done |
| Library | Notes | `NotesViewController` + `NoteStore` | Done |
| Discovery | Home feed + filters | `HomeViewController` | Done |
| Discovery | Shorts | `ShortsViewController` | Done |
| Discovery | Search + suggestions | `SearchViewController` | Done |
| Discovery | Channel | `ChannelViewController` | Done |
| Discovery | Playlist | `PlaylistViewController` | Done |
| Discovery | Watch page (player + metadata + related) | `WatchViewController` embedding `VideoPlayerViewController` as a child | Done |
| Discovery | Comments, replies, sorting | `CommentsViewController` (Top/Newest/Oldest applied on the device, since the facade exposes one comment continuation) | Done |
| Discovery | Like / dislike a video | `WatchReactions` in `UserDefaults` — the app works signed out and the facade has no rating endpoint | iOS equivalent |
| Discovery | Subscriptions feed | `SubscriptionsViewController` | Done |
| Discovery | Notifications | `NotificationsViewController` | Done |
| Discovery | FlowNeuro recommendations | on-device topic-vector ranker in `HomeViewModel` | Done |
| Discovery | Flow Recap | `RecapViewController` | Done |
| System | 24 themes + custom | `FlowPalettes`, `AppearanceSettingsViewController` | Done |
| System | Import from NewPipe | `ImportExportViewController` | Done |
| System | Export all data | `ImportExportViewController` | Done |
| System | Device sync over Wi-Fi | `SyncViewController` (Bonjour + local HTTP) | Done |
| System | Onboarding | `OnboardingViewController` | Done |
| System | Song recognition | `RecognitionViewController` (mic capture + pluggable provider) | iOS equivalent |
| System | Home-screen widgets | Widgets require iOS 14+ (`WidgetKit`); iOS 12 has Today extensions only | N/A on iOS 12 |
| System | Material You dynamic colour | Requires iOS 16+; shown disabled in Appearance settings | N/A on iOS 12 |
| System | TV interface | Android TV build; iOS has no TV target here | N/A |

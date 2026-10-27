# Flow for iOS

A native iOS port of [Flow](https://github.com/Flow-Tube/Flow) — the open-source, privacy-respecting
YouTube and YouTube Music client with the on-device FlowNeuro recommendation engine.

This repository is the iOS 12.5.8 build: deployment target iOS 12.0, arm64, UIKit, no third-party
dependencies, no analytics, no account.

## What it is

Flow plays YouTube and YouTube Music without an account or tracking. The recommendation engine runs
entirely on the device: it reads your local watch history, builds a topic vector, and never sends
anything anywhere. You can inspect what it knows and wipe it from Settings.

Features carried over from the Android app:

- **Video** — HLS playback, quality switching, playback speed, chapters, gesture controls
  (brightness / volume / seek), picture-in-picture, background audio, resume position, subtitles.
- **SponsorBlock** — automatic skipping of sponsors, intros, outros, self-promos, filler, with
  per-category toggles and the coloured chapter bar.
- **DeArrow** and **Return YouTube Dislike**.
- **Music** — YouTube Music browse, artist and album pages, queue with reorder, shuffle and repeat,
  synchronized lyrics, persistent mini player, parametric equalizer, sleep timer.
- **Library** — history, playlists, downloads (offline playback), local media, saved shorts, notes.
- **Discovery** — home feed, shorts, subscriptions feed, notifications, Flow Recap, moods and genres.
- **Look and feel** — 24 themes (Catppuccin, Dracula, Nord, Gruvbox, Tokyo Night, Solarized,
  Everforest, Kanagawa, Monochrome, Lavender, Tako, Tide, Caffeine, Claude, Cyberpunk, Gunmetal,
  Espresso and more) plus a custom palette editor.

## Requirements

- A device on **iOS 12.0 – 12.5.8** (iPhone 5s / 6 / 6 Plus / iPad Air / iPad mini 2–3) or anything newer.
- Because the build is unsigned, install it with **Sideloadly** or **AltStore** on Windows/macOS, or
  **AltStore PAL** on a modern device. Sideloadly re-signs the app with your own Apple ID.

## Build

The `.ipa` is built by GitHub Actions — push to `main` or run the workflow manually:

```
Actions → iOS build (.ipa) → Run workflow
```

The artifact `Flow-ipa` contains `Flow.ipa`.

Locally, on macOS with Xcode 15 and XcodeGen:

```sh
brew install xcodegen
xcodegen generate
open Flow.xcodeproj
```

## Install the .ipa

1. Download `Flow.ipa` from the workflow artifact (unzip it first).
2. Open Sideloadly, drag `Flow.ipa` in, enter your Apple ID, start.
3. On the device: Settings → General → Profiles → trust your developer certificate.
4. Launch Flow. A free Apple ID signature lasts 7 days; AltStore refreshes it automatically.

## Why the port is a rewrite rather than a copy

Flow for Android is Kotlin with Jetpack Compose, Media3 and Hilt. None of that exists on iOS 12 —
there is no SwiftUI before iOS 13 and no Compose runtime at all. The port therefore reimplements every
screen in UIKit with the same information architecture, the same strings, and the same Material 3
design tokens, and reimplements the data layer against the same InnerTube endpoints.

`docs/PARITY.md` lists every Android feature and exactly how it is realised on iOS, including the two
places where the platform forces a different mechanism (AirPlay instead of Chromecast; no home-screen
widgets before iOS 14).

## Licence

GPL-3.0, inherited from the upstream project. See `LICENSE`.

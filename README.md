# Cratedigger

Cratedigger is a cross-platform desktop and mobile client for browsing, previewing,
and downloading from the Beatport catalogue. It signs in with a Beatport account,
searches the catalogue, plays track previews, and exports purchased or available
tracks with configurable audio quality and file organisation.

The app is built with Flutter and targets Windows, Linux, macOS, Android, and iOS
from a single Dart codebase.

## Features

- **Account sign-in** using a Beatport username and password. Only the resulting
  OAuth token is cached; the password is never stored. On desktop and mobile the
  token is kept in the platform keychain via `flutter_secure_storage`.
- **Search** the catalogue by track, artist, label, genre, and release date range.
- **Harmonic browsing** with a Camelot key wheel for building harmonically
  compatible selections.
- **Link import** to resolve a pasted Beatport URL (track, release, chart, or
  library) directly into a track list.
- **Preview playback** of track snippets, powered by `media_kit`.
- **Downloads** with a managed queue, configurable parallelism, selectable audio
  quality, and templated folder and file naming.
- **Download history** and status colouring so already-exported tracks are easy to
  spot.

## Project layout

```
lib/
  engine/    Catalogue client, authentication, tokens, HLS handling, downloads
  state/     App state (session, download queue, preview player) via provider
  ui/        Screens and widgets (browse, downloads, settings, harmonic, login)
  main.dart  App entry point and theme
test/        Unit and integration tests for the engine and UI
android/ ios/ linux/ macos/ windows/   Platform runners
```

## Requirements

- Flutter 3.41 or newer (Dart 3.11+).
- A valid Beatport account to sign in.
- Platform toolchains as required by Flutter for the target you build (for
  example Visual Studio with the C++ workload for Windows desktop).

## Getting started

```bash
flutter pub get
flutter run -d windows   # or: linux, macos, chrome, or a connected device
```

## Building a release

```bash
flutter build windows --release
```

The packaged application is written to
`build/windows/x64/runner/Release/`. A prebuilt Windows release is attached to the
tagged releases of this repository.

## Testing

```bash
flutter test
```

Tests tagged `live` reach the real Beatport API and are excluded from the default
run; see `dart_test.yaml`.

## Configuration

Audio quality, download parallelism, download location, preview length, and the
folder and file naming templates are all configured from the in-app Settings
screen. Settings and download history persist between runs.

## Notes

This project is for personal use with a legitimate Beatport account and is subject
to Beatport's terms of service. It is not affiliated with or endorsed by Beatport.

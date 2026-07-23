# Building BeatPort Digger for iPad / iPhone

iOS and iPadOS builds can only be produced on **macOS with Xcode**. They cannot be
built, signed, or transferred from Windows or Linux. This guide assumes you are on
a Mac.

## Prerequisites

- macOS with a recent **Xcode** installed (from the App Store), opened once to
  accept its licence and install components.
- **Flutter 3.41+** on the Mac (`flutter doctor` should show no iOS issues).
- **CocoaPods**: `sudo gem install cocoapods` (or via Homebrew).
- An **Apple ID**. A free one is enough to run on your own iPad; a paid Apple
  Developer account ($99/yr) is needed for TestFlight or longer-lived installs.

The project is already configured for iOS:

- Bundle identifier: `com.r00tme.beatportdigger`
- Display name: `BeatPort Digger`
- Universal app (iPad orientations enabled)
- File sharing enabled, so downloaded tracks appear in the Files app under
  *On My iPad -> BeatPort Digger* and can be imported by other apps.

## First-time setup on the Mac

```bash
git clone https://github.com/r00tmebaby/beatport_digger.git
cd beatport_digger
flutter pub get
cd ios && pod install && cd ..
```

## Signing

1. Open the iOS project in Xcode:

   ```bash
   open ios/Runner.xcworkspace
   ```

2. Select the **Runner** target -> **Signing & Capabilities**.
3. Tick **Automatically manage signing** and choose your **Team** (your Apple ID).
4. If the bundle id `com.r00tme.beatportdigger` is taken on Apple's side, change it to
   something unique (for example add your initials) here and in
   `ios/Runner/Info.plist` is not needed - Xcode's field is enough.

## Install on your iPad

### Option A - free Apple ID (simplest, expires after 7 days)

1. Connect the iPad by cable and trust the Mac.
2. In Xcode, pick the iPad as the run destination and press **Run** (Cmd+R), or:

   ```bash
   flutter devices          # find the iPad's id
   flutter run --release -d <ipad-device-id>
   ```

3. On the iPad, go to **Settings -> General -> VPN & Device Management** and trust
   your developer certificate.
4. The app stops working after 7 days on a free account - re-run from Xcode to
   renew it.

### Option B - TestFlight (paid account, best for regular use)

```bash
flutter build ipa --release
```

The signed archive is written to `build/ios/archive/`. Open it in Xcode's
**Organizer**, distribute to **App Store Connect**, then install it on the iPad
through the **TestFlight** app. Builds stay valid for 90 days.

## Notes and limitations on iPad

- The in-app player streams Beatport **preview snippets**, not full tracks. This is
  a catalogue browser, preview and downloader - not a DJ performance app, and it
  does not drive a controller. Use it to fill your crate, then load the downloaded
  files into your DJ software.
- Downloaded files are **not remuxed** on iOS (no ffmpeg on device); tracks are
  saved in their delivered AAC form.
- Downloads land in the app's Documents folder, exposed through the Files app by
  the file-sharing settings above.

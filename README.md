# HandTrack

HandTrack is an MVP for tracking hand symptoms and keyboard activity across an iPhone and a Mac without cloud storage.

## MVP

- iOS app: hourly reminders and current-hour pain/use/journal logging.
- macOS app: keystroke timestamp capture while the app is open.
- Mac storage: local JSON files in Application Support.
- Local sync: the Mac exposes a Wi-Fi endpoint and the iPhone can send saved hourly logs.

## Build

Generate the Xcode project:

```sh
xcodegen generate
```

Then open `HandTrack.xcodeproj` and run either `HandTrackiOS` or `HandTrackMac`.

The macOS target needs Input Monitoring permission for global keystroke capture.

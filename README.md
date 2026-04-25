# HandTrack

HandTrack is an MVP for tracking hand symptoms and keyboard activity across an iPhone and a Mac without cloud storage.

## MVP

- iOS app: hourly reminders and current-hour pain/use/journal logging.
- macOS app: keystroke timestamp capture while the app is open.
- Mac storage: local SQLite database in Application Support.
- Local sync: the Mac exposes a Wi-Fi endpoint and the iPhone can send saved hourly logs.
- Data export: the Mac app can export pandas-friendly CSV files.

## Build

Generate the Xcode project:

```sh
xcodegen generate
```

Then open `HandTrack.xcodeproj` and run either `HandTrackiOS` or `HandTrackMac`.

The macOS target needs Input Monitoring permission for global keystroke capture.

## Data Policy

- Hourly iPhone logs are kept indefinitely.
- Raw keystroke timestamps are kept for one year.
- Keystrokes older than one year are compacted into hourly summaries.
- CSV export writes `hourly_logs.csv`, `keystroke_events.csv`, and `keystroke_hourly_summaries.csv`.

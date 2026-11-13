# V27 PULSE — Combined Batch 1 + Batch 2 patch report

This archive combines the completed Batch 1 localization/intro changes with the Batch 2 permission/deletion verification, Library swipe responsiveness, and Now Playing track actions/control redesign.

## Batch 1

- Nine app locales: English, Arabic, French, Spanish, German, neutral Portuguese, Turkish, Japanese, and Moroccan Darija (`ar_MA`, Arabic script).
- Completed app-owned localization wiring across Library, playlists, Settings, Now Playing, mini-player, Lyrics, Equalizer, sleep timer, menus, dialogs, snackbars, empty/error/loading states, and related labels.
- Arabic and Moroccan Darija use Arabic locale directionality (RTL).
- Extended the opening split-logo animation to 2.6 seconds.
- Added localization/animation contract coverage.

See `V27_PULSE_BATCH1_REPORT.md` for the full details.

## Batch 2

- Tuned Library tab swipe physics for shorter, lighter horizontal gestures.
- Added the Now Playing three-dot menu and wired Set as, Share, Delete, Track details, Add to playlist, Album, and Artist.
- Standardized the same seven actions in the Library Tracks and dashboard menus, in the approved order.
- Restyled Lyrics and What's Next controls while retaining the existing inline lyrics and active logical playback queue.
- Retained the existing early audio/notification permission requests and the Android system-confirmed MediaStore delete flow; no all-files permission is used.
- Added Batch 2 contract coverage.

See `V27_PULSE_BATCH2_REPORT.md` for the full details and the Android 11+ deletion limitation.

## Validation status

Static source checks passed, including localization key coverage, menu order, delimiter balance, whitespace, and scoped-permission checks. Flutter `analyze` and `test` were not run because the Flutter/Dart SDK is unavailable in this patch environment. Run the contract tests and full validation inside the Ubuntu proot before producing an APK.

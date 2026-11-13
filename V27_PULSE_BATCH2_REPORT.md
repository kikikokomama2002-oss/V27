# V27 PULSE — Batch 2 change report

## Implemented in this batch

- Added a responsive `PageScrollPhysics` configuration to the Library `TabBarView`, with a shorter drag-start threshold and lower fling distance/velocity so a light horizontal swipe is more likely to switch tabs on the first attempt.
- Added the Now Playing three-dot track menu and wired all seven actions to the same app behaviors: Set as, Share, Delete, Track details, Add to playlist, Album, and Artist.
- Standardized the order of the track context menu in Now Playing, the Library Tracks list, and the Library dashboard to the approved order: Set as → Share → Delete → Track details → Add to playlist → Album → Artist.
- Restyled the Lyrics and What's Next controls as coordinated teal-aware tonal buttons with a clear selected state. The existing inline lyrics and active-queue behavior remains the source of data; no second queue was introduced.
- Added a Batch 2 contract test for menu order/action wiring, responsive tab physics, early permission requests, and scoped MediaStore deletion.

## Existing Android permission/deletion path retained and checked

- The source archive already contained the startup audio permission request and the optional notification permission request; both are retained before the initial library scan.
- Android permissions include `READ_MEDIA_AUDIO`, legacy `READ_EXTERNAL_STORAGE` (capped at API 32), and `POST_NOTIFICATIONS`.
- Track deletion uses a Dart confirmation followed by Android's `MediaStore.createDeleteRequest` system confirmation. The app only passes a MediaStore content URI and does not request `MANAGE_EXTERNAL_STORAGE` / all-files access.
- After Android confirms deletion, the library is rescanned. Cancelling the Android confirmation leaves the audio file untouched.

## Platform limitation

- The existing native delete handler requires Android 11 (API 30) or newer because `MediaStore.createDeleteRequest` was introduced in API 30. On Android 10 and older, the current handler returns an explicit unsupported-version error instead of attempting an unsafe direct deletion. The user's Galaxy S20 FE on Android 13 is within the supported path.

## Validation

- Static checks passed for the seven-action menu order across all three UI locations.
- Verified the required action/localization keys are present in all nine locales.
- Verified balanced delimiters and no trailing whitespace across the modified Dart/test files.
- Verified the Android manifest has the scoped audio permission and no `MANAGE_EXTERNAL_STORAGE` permission.
- Flutter/Dart executables are not available in this patch environment. `flutter analyze` and `flutter test` were **not run**; run them inside the Ubuntu proot before building the APK.

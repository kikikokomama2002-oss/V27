# V27 PULSE — Next Update Patch Report

## Implemented in this patch
- Removed the currently used split-logo opening overlay. A future opening animation is postponed; no replacement intro is included.
- Added a user-initiated Android 12+ Media management access entry in Settings > App Permissions. Track deletion remains MediaStore-only and still uses `MediaStore.createDeleteRequest`; `MANAGE_EXTERNAL_STORAGE` is not declared.
- Added a pointer-based fallback for horizontal tab swipes on non-Home library tabs while preserving the native TabBarView gesture path. Home is excluded so its horizontal shelves remain usable.
- Added staged fade/slide reveal transitions to the Library dashboard sections.
- Added a native Media3 PCM stereo panning processor with persistent enabled/intensity/speed settings and controls on the Equalizer screen. It is an 8D-style stereo pan effect, not true HRTF surround.
- Added translations for all new labels in the nine supported locales.
- Updated source-contract tests for the removed intro, optional media-management access, swipe fallback, 8D processor wiring, and dashboard reveal behavior.

## Important limitations / verification required
- This runtime has no Flutter/Dart SDK, Android SDK, or Gradle installation. `flutter analyze`, `flutter test`, and Android compilation were therefore not run here. The included tests are new/updated contract tests only; run the full suite in the project's Ubuntu proot before using the APK.
- `MANAGE_MEDIA` is a special Android setting, not a normal runtime dialog. The user must opt in. Android's current guidance says an app targeting Android 12+ that declares both `MANAGE_MEDIA` and `READ_EXTERNAL_STORAGE` can use `createDeleteRequest` without a separate confirmation for every file after the user grants this special access. Android 11 and older still use per-delete confirmation. The actual Settings grant and delete flow still needs verification on the Galaxy S20 FE. If the user declines, the original safe per-delete confirmation remains. See: https://developer.android.com/training/data-storage/shared/media#media-management-permission
- The custom audio processor handles decoded stereo PCM 16-bit/float. Non-stereo or encoded passthrough/offload paths are not spatialized. The project is on Media3 1.6.1, so the sink uses the 1.6.1 `setAudioTrackPlaybackParams` API; PCM processing is not applied to passthrough/offload. Test battery, Bluetooth, speaker output, and format compatibility on-device. See: https://developer.android.com/reference/androidx/media3/exoplayer/audio/DefaultAudioSink.Builder#setAudioProcessors(androidx.media3.common.audio.AudioProcessor[])
- 8D remains off by default. Intensity and speed are persisted in native SharedPreferences and applied to the shared playback processor across track changes and app restarts.
- Library swipe behavior and the scroll transitions require actual phone interaction/FPS testing. Dashboard Home is intentionally excluded from the swipe fallback to protect horizontally scrolling shelves.

## Not changed
- No commit, push, APK build, or device test was performed.
- No `MANAGE_EXTERNAL_STORAGE` permission was added.

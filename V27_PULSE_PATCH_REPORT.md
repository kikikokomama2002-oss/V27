# V27 PULSE integration patch report — v3

## Based on
The user's latest uploaded source archive `V27_latest_for_patch.zip`. This patch is designed to overlay that exact source snapshot while leaving unrelated project files untouched.

## Included in this integration
- Seven persisted accent choices, with coordinated dark/light accent values.
- ThemeData caching by accent color to avoid rebuilding the complete theme tree for repeated selections.
- Accent-aware hero gradients in Settings, Equalizer, and the full-screen Lyrics header; standard Material controls use the selected ColorScheme.
- Nine selectable locale choices: English, Arabic, French, Spanish, German, neutral Portuguese, Turkish, Japanese, and Moroccan Darija in Arabic script (`ar_MA`).
- App localization delegate and translations for language/accent controls, Now Playing controls, inline lyrics states, and both Settings/Now Playing sleep-timer flows.
- Now Playing inline Lyrics and What's Next views, with compact current-track header and return-to-cover interaction.
- LRC active-line highlighting and fixed-height lyric rows for predictable auto-follow scrolling.
- Upcoming tracks resolved from the active logical `QueueSpec`, bounded to 40 items, with tap-to-play routed back through that same queue and stable MediaStore identity.
- Now Playing sleep-timer button sits beside the transport controls. Its sheet reads, updates, and cancels the same native deadline already used by Settings. The existing Settings timer UI also uses that deadline; no second timer is created.
- Sleep-timer labels, custom duration dialog, and completion/error messages are translated in all nine locale dictionaries.
- Contract tests covering accent persistence/theme wiring, locale options, inline panels, shared timer integration, and QueueSpec preview/tap-to-play wiring.

## Limitations that must remain explicit
- Localization is **not yet complete across every existing screen**. The nine language choices are available and the newly added settings/Now Playing/timer flows have translations, but many pre-existing Library, playlist-management, Equalizer, full-screen Lyrics, and miscellaneous Settings strings remain English. Full nine-language coverage is still a remaining task.
- Inline Lyrics uses the repository's embedded/cached `ensureLyrics` flow and LRC parser. If lyrics require the full-screen SAF folder-permission recovery flow, the inline panel offers the existing Lyrics tools screen as fallback; that recovery is not reproduced inline.
- Queue preview uses the active logical QueueSpec and stable MediaStore identities. This uploaded source snapshot does not expose a shuffle-order state in PlaybackState, so no shuffle behavior is fabricated. If a playlist contains the same track more than once, current-position resolution may select the first matching occurrence; duplicate-occurrence behavior needs device verification.
- Native sleep-timer methods already exist in the uploaded source and are reused. Flutter-side integration still needs runtime testing on the user's device.
- Flutter/Dart SDK is not available in the patch-generation environment. `flutter analyze` and `flutter test` have **not** been run here. They must be run inside the user's Ubuntu proot before APK build or commit.

## Files in this patch
- `pubspec.yaml`
- `lib/main.dart`
- `lib/core/theme.dart`
- `lib/core/accent_color_provider.dart` (new)
- `lib/core/localization.dart` (new)
- `lib/core/widgets/sleep_timer_sheet.dart` (new)
- `lib/features/settings/settings_screen.dart`
- `lib/features/equalizer/equalizer_screen.dart`
- `lib/features/lyrics/lyrics_screen.dart`
- `lib/features/player/now_playing_screen.dart`
- `lib/playback/playback_controller.dart`
- `test/v27_pulse_shared_features_contract_test.dart` (new)

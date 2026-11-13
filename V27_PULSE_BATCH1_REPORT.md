# V27 PULSE — Batch 1 change report

## Implemented in this patch

- Wired the nine requested locales into the app: English, Arabic, French, Spanish, German, neutral Portuguese, Turkish, Japanese, and Moroccan Darija (`ar_MA`, Arabic script).
- Kept the existing saved-language preference (`v27_language_code_v1`) and immediate `MaterialApp.locale` update.
- Expanded the translation catalogue to 292 shared keys across all nine locales, covering Library navigation/dashboard/search, playlist management and details, Settings, permission statuses, Now Playing, mini-player, Lyrics, Equalizer and its common presets, sleep timer, track context actions/details, accent names, and the associated dialogs, snackbars, empty/loading/error states.
- Localized Library tab labels and dashboard shortcuts, playlist counts/actions, track details labels, accent-color names, Equalizer preset names, and common time/count suffixes.
- Arabic and Moroccan Darija use Arabic locales. Flutter's Material/Widgets localization delegates provide RTL directionality for those locales.
- Extended the split-logo opening animation from 1.15 seconds to 2.6 seconds.
- Added `test/batch1_localization_animation_contract_test.dart` to guard locale coverage and the main localized surfaces.

## Static validation performed here

- Confirmed all nine locale maps have the same 292-key catalogue when the base and screen dictionaries are combined.
- Confirmed all literal localization keys referenced from app source resolve to a key in that catalogue; dynamic accent and Equalizer preset keys were checked separately.
- Checked both translation maps for duplicate keys, checked edited files for trailing whitespace, and ran a delimiter-balance scan on the edited Dart and test files. These checks passed.

## Runtime validation still required

`flutter analyze` and `flutter test` were **not run** in this editing environment because Flutter/Dart executables are unavailable here. The new contract test and full project analyze/test cycle must still be run inside the existing Ubuntu proot before building an APK. This patch should not be treated as build-verified yet.

## Scope

This patch covers Batch 1 localization and the intro animation only. Batch 2 remains untouched: Android permission/deletion flow, Library swipe responsiveness, and the Now Playing Lyrics/Queue controls and three-dot menu redesign.

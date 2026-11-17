# V27 PULSE — Analyzer and dashboard contract-test corrections

This patch addresses the analyzer errors reported after applying the Batch 1 + Batch 2 archive:

- Corrected Dart OR-pattern syntax in the Equalizer preset switch.
- Removed invalid `const` contexts around dashboard widgets that call localization methods.
- Added the Flutter gestures import required by `DragStartBehavior`.
- Replaced an out-of-scope `strings` reference in the library-unavailable retry button with `V27Strings.of(context)`.
- Used the language tuple's actual `name` field in the language dropdown instead of a nonexistent `id` field.
- Updated the dashboard redesign contract test to assert the localized keys rather than pre-localization hard-coded English labels.

Runtime validation has not been run in this patch environment. Run `flutter analyze` and the dashboard contract test in Ubuntu proot after applying this patch.

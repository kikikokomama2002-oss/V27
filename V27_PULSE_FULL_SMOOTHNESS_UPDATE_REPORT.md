# V27 PULSE — Full-app Smoothness Update

## Scope
This update targets the two requested goals only: smoother app-wide interaction and better page/tab transitions. It does not add product features or change the app's visual identity.

## Changes

### App-wide navigation
- Added a shared lightweight slide/fade page transition builder to both light and dark themes.
- Applied it to Android, iOS, Linux, macOS, Windows, and Fuchsia page routes so `MaterialPageRoute` navigation uses one consistent transition.
- The transition uses compositor-driven `SlideTransition` and `FadeTransition` rather than animating layout, and returns the page without decorative motion when the system requests reduced animations.

### Library and scrolling
- Kept the native `TabBarView`/`PageView` gesture handling; removed the old delayed manual swipe fallback.
- Kept tab changes at 280 ms with `easeOutCubic` and avoided rebuilding the whole library for every `TabController` animation tick.
- Kept lazy dashboard section reveal animations at 360 ms with short stagger and reduced-motion support.

### Artwork and frame workload
- Bounded decoded album-art image dimensions to each widget's requested `artSize` using `cacheWidth` and `cacheHeight`.
- Added `gaplessPlayback` to avoid blank flashes when artwork updates.
- Isolated artwork painting with `RepaintBoundary` to reduce unrelated repaint work during list scrolling.

## Validation status
- Added source-contract tests for the shared route transition, bounded artwork decoding, and existing library swipe behavior.
- `git diff --check`/archive structure checks were run during packaging.
- Flutter analyze/tests and Android compilation were not run in this environment because the Flutter/Android SDK toolchain is not available here.
- Actual FPS/frame-time performance must still be measured in a profile/release build on the target Galaxy S20 FE. This update is an evidence-based optimization pass, not a claim that a specific FPS has already been measured or that all possible bottlenecks are eliminated.

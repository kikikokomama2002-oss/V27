# V27 PULSE — Smoothness & Page Swipe Update

Scope: only two requested goals were changed.

## 1. Smoother library/page transitions
- Removed the manual pointer-based swipe fallback that waited 340 ms before changing tabs.
- Let `TabBarView`'s native `PageView` gesture handling coordinate horizontal page swipes with vertical lists and horizontal shelves.
- Used `PageScrollPhysics` with a bouncing parent for natural page settling.
- Set tab transitions to 280 ms with `Curves.easeOutCubic`.
- Prevented the `LibraryScreen` from calling `setState` for every `TabController` animation tick; it now rebuilds only when the selected tab index changes.

## 2. Smoother scroll-reveal animation
- Shortened section reveal animation from 480 ms to 360 ms.
- Reduced the vertical travel distance to 3.5% and stagger spacing to 55 ms.
- Kept the reveal tied to lazy Sliver child creation, so sections animate as they approach the viewport.
- Respects Android/Flutter's reduced-motion preference (`MediaQuery.disableAnimations`).

## Validation
- Updated the swipe/animation contract tests to cover the new behavior.
- This ZIP was edited without a local Flutter SDK or Android SDK. `flutter analyze`, `flutter test`, Android compilation, and on-device FPS/gesture testing remain pending and must be run in the user's existing Termux Ubuntu proot / GitHub Actions workflow.
- No feature additions, audio changes, permission changes, or visual redesigns were made.

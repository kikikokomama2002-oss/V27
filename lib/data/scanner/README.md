Native scanning lives in the Kotlin MediaStoreScanner
(android/app/.../scanner/MediaStoreScanner.kt) and is invoked from
lib/data/repositories/library_repository.dart via the PlayerChannel
MethodChannel. This folder is reserved for any future Dart-side scan
utilities (e.g. embedded ID3 tag parsing for artwork).

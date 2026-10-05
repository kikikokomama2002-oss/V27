# ---------------------------------------------------------------------
# Media3 / ExoPlayer
# R8 aggressively strips unused code in release builds; ExoPlayer uses
# reflection to instantiate format-specific extractors/decoders that R8
# can't see are referenced, so they must be kept explicitly or gapless
# playback / certain formats (FLAC, etc.) silently break in release-only
# builds (a classic "works in debug, broken in release" bug).
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**
-keep interface androidx.media3.** { *; }

# ExoPlayer's MediaSession / MediaSessionService callback classes are
# also invoked reflectively by the system media framework.
-keep class * extends androidx.media3.session.MediaSessionService { *; }
-keep class * extends androidx.media3.session.MediaSession$Callback { *; }

# ---------------------------------------------------------------------
# Isar
# Isar generates schema/adapter code that must not be renamed or
# stripped, or the release build will fail to open the database (or
# silently read/write wrong fields).
-keep class isar.** { *; }
-keep class **.*Schema { *; }
-keepclassmembers class * {
    @isar.annotation.* <fields>;
}

# ---------------------------------------------------------------------
# Kotlin coroutines
-dontwarn kotlinx.coroutines.**
-keepclassmembernames class kotlinx.** {
    volatile <fields>;
}

# ---------------------------------------------------------------------
# App's own platform-channel classes: referenced by name from the
# Flutter engine / Android media framework, not just from Kotlin code
# R8 can trace, so keep them intact.
-keep class com.example.musicplayer.** { *; }

# ---------------------------------------------------------------------
# AdMob / Play Billing (in_app_purchase) rules removed along with the
# dependencies for the pure offline MVP release — see
# lib/ads_iap/README.md to reintroduce alongside the deps.

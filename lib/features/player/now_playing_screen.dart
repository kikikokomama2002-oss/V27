import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets/track_artwork.dart';
import '../equalizer/equalizer_screen.dart';
import '../lyrics/lyrics_screen.dart';

/// Full-screen V27 PULSE playback experience.
class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  String _fmt(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0
        ? '${hours.toString().padLeft(2, '0')}:$minutes:$seconds'
        : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final playback = ref.watch(playbackControllerProvider);
    final controller = ref.read(playbackControllerProvider.notifier);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'NOW PLAYING',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.8,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'V27 PULSE',
              style: theme.textTheme.labelSmall?.copyWith(
                color: V27Palette.violet,
                letterSpacing: 2.2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.equalizer_rounded),
            tooltip: 'Equalizer',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EqualizerScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.lyrics_rounded),
            tooltip: 'Lyrics',
            onPressed: track == null
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LyricsScreen(track: track),
                      ),
                    ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity < -350) {
            controller.next();
          } else if (velocity > 350) {
            controller.previous();
          }
        },
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) > 350) {
            Navigator.of(context).maybePop();
          }
        },
        child: track == null
            ? const _NothingPlayingState()
            : LayoutBuilder(
                builder: (context, constraints) {
                  final artworkSize = math.min(
                    constraints.maxWidth - 48,
                    constraints.maxHeight * 0.43,
                  ).clamp(150.0, 360.0).toDouble();
                  final durationMs = playback.duration.inMilliseconds;
                  final maxMs = durationMs > 0 ? durationMs.toDouble() : 1.0;
                  final positionMs = playback.position.inMilliseconds
                      .clamp(0, durationMs > 0 ? durationMs : 0)
                      .toDouble();

                  return Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 18),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        const SizedBox(height: 2),
                        Container(
                          width: artworkSize,
                          height: artworkSize,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                            boxShadow: [
                              BoxShadow(
                                color: V27Palette.violet.withValues(
                                  alpha: isDark ? 0.24 : 0.13,
                                ),
                                blurRadius: 38,
                                spreadRadius: 2,
                                offset: const Offset(0, 14),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(28),
                            child: TrackArtwork(
                              contentUri: track.contentUri,
                              version: Object.hash(
                                track.derivedCacheEpoch,
                                track.mediaStoreGenerationModified ??
                                    track.dateModified,
                                track.dateModified,
                                track.contentUri,
                                track.relativePath,
                                track.displayName,
                                track.durationMs,
                                track.title,
                                track.artist,
                                track.album,
                                track.folder,
                              ),
                              size: artworkSize,
                              artSize: 512,
                              borderRadius: BorderRadius.circular(28),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Column(
                          children: [
                            Text(
                              track.title,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                                height: 1.15,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              track.artist,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (track.album.trim().isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                track.album,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.72),
                                ),
                              ),
                            ],
                          ],
                        ),
                        Column(
                          children: [
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 4,
                                activeTrackColor: V27Palette.violet,
                                inactiveTrackColor: isDark
                                    ? V27Palette.darkBorder
                                    : V27Palette.lightBorder,
                                thumbColor: V27Palette.cyan,
                                overlayColor:
                                    V27Palette.violet.withValues(alpha: 0.12),
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 16,
                                ),
                              ),
                              child: Slider(
                                min: 0,
                                max: maxMs,
                                value: positionMs,
                                onChanged: (value) => controller.seek(
                                  Duration(milliseconds: value.toInt()),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _fmt(playback.position),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  Text(
                                    _fmt(playback.duration),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              tooltip: 'Previous track',
                              onPressed: controller.previous,
                              icon: const Icon(Icons.skip_previous_rounded),
                              iconSize: 38,
                              color: theme.colorScheme.onSurface,
                            ),
                            const SizedBox(width: 30),
                            Container(
                              width: 76,
                              height: 76,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    V27Palette.violet,
                                    Color(0xFF6841D9),
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: V27Palette.violet.withValues(
                                      alpha: 0.32,
                                    ),
                                    blurRadius: 22,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Material(
                                color: Colors.transparent,
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: controller.togglePlayPause,
                                  child: Icon(
                                    playback.isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    size: 43,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 30),
                            IconButton(
                              tooltip: 'Next track',
                              onPressed: controller.next,
                              icon: const Icon(Icons.skip_next_rounded),
                              iconSize: 38,
                              color: theme.colorScheme.onSurface,
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _NothingPlayingState extends StatelessWidget {
  const _NothingPlayingState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    V27Palette.violet.withValues(alpha: 0.2),
                    V27Palette.cyan.withValues(alpha: 0.08),
                  ],
                ),
              ),
              child: const Icon(
                Icons.music_off_rounded,
                size: 48,
                color: V27Palette.violet,
              ),
            ),
            const SizedBox(height: 22),
            Text(
              'Nothing playing',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Choose a track from your library and let the music take over.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

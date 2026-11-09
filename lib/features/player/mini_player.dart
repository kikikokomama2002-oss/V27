import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets/track_artwork.dart';
import 'now_playing_screen.dart';

/// Persistent V27 PULSE playback bar.
/// Track metadata is isolated from the 500ms playback-state stream.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    if (track == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const NowPlayingScreen()),
        ),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? V27Palette.darkSurface : theme.colorScheme.surface,
            border: Border(
              top: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.7),
                width: 0.8,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(V27Radius.md),
                      child: TrackArtwork(
                        contentUri: track.contentUri,
                        version: Object.hash(
                          track.derivedCacheEpoch,
                          track.mediaStoreGenerationModified ?? track.dateModified,
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
                        size: 46,
                        artSize: 128,
                        borderRadius: BorderRadius.circular(V27Radius.md),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.1,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Previous',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
                      onPressed: ref.read(playbackControllerProvider.notifier).previous,
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    const _MiniPlayerPlayButton(),
                    IconButton(
                      tooltip: 'Next',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
                      onPressed: ref.read(playbackControllerProvider.notifier).next,
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                  ],
                ),
              ),
              const _MiniPlayerProgress(),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniPlayerPlayButton extends ConsumerWidget {
  const _MiniPlayerPlayButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(
      playbackControllerProvider.select((state) => state.isPlaying),
    );
    final controller = ref.read(playbackControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return IconButton(
      tooltip: isPlaying ? 'Pause' : 'Play',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      onPressed: controller.togglePlayPause,
      style: IconButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
      ),
      icon: Icon(
        isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        size: 25,
      ),
    );
  }
}

class _MiniPlayerProgress extends ConsumerWidget {
  const _MiniPlayerProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(
      playbackControllerProvider.select(
        (state) => (state.position, state.duration),
      ),
    );
    final durationMs = playback.$2.inMilliseconds;
    final progress = durationMs <= 0
        ? 0.0
        : (playback.$1.inMilliseconds / durationMs).clamp(0.0, 1.0).toDouble();
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 7),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 2.5,
          backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.08),
          valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
        ),
      ),
    );
  }
}

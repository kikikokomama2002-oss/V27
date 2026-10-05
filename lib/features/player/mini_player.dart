import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../../core/widgets/track_artwork.dart';
import 'now_playing_screen.dart';

/// Persistent bottom bar showing the current track with play/pause and
/// skip controls. Tapping it opens the full Now Playing screen.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final playback = ref.watch(playbackControllerProvider);
    final controller = ref.read(playbackControllerProvider.notifier);

    if (track == null) return const SizedBox.shrink();

    final progress = playback.duration.inMilliseconds == 0
        ? 0.0
        : playback.position.inMilliseconds / playback.duration.inMilliseconds;

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const NowPlayingScreen()),
      ),
      child: Material(
        color: Theme.of(context).cardColor,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0).toDouble(),
              minHeight: 2,
              backgroundColor: Colors.transparent,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: Colors.transparent,
                    child: TrackArtwork(
                      contentUri: track.contentUri,
                      version: Object.hash(
          track.derivedCacheEpoch,
          track.mediaStoreGenerationModified ?? track.dateModified,
          track.dateModified, track.contentUri, track.relativePath,
          track.displayName, track.durationMs, track.title, track.artist,
          track.album, track.folder,
        ),
                      size: 40,
                      artSize: 120,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text(track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.color
                                    ?.withOpacity(0.7))),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    onPressed: controller.previous,
                  ),
                  IconButton(
                    icon: Icon(playback.isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled),
                    iconSize: 36,
                    onPressed: controller.togglePlayPause,
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: controller.next,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

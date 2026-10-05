import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../../core/widgets/track_artwork.dart';
import '../equalizer/equalizer_screen.dart';
import '../lyrics/lyrics_screen.dart';

/// Full-screen now-playing view: large artwork placeholder, seek bar,
/// and primary transport controls.
class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '${h.toString().padLeft(2, '0')}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final playback = ref.watch(playbackControllerProvider);
    final controller = ref.read(playbackControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Now Playing'),
        actions: [
          IconButton(
            icon: const Icon(Icons.equalizer),
            tooltip: 'Equalizer',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EqualizerScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.lyrics_outlined),
            tooltip: 'Lyrics',
            onPressed: track == null
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LyricsScreen(track: track),
                      ),
                    ),
          ),
        ],
      ),
      body: track == null
          ? const Center(child: Text('Nothing playing'))
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Spacer(),
                  AspectRatio(
                    aspectRatio: 1,
                    child: TrackArtwork(
                      contentUri: track.contentUri,
                      version: Object.hash(
          track.derivedCacheEpoch,
          track.mediaStoreGenerationModified ?? track.dateModified,
          track.dateModified, track.contentUri, track.relativePath,
          track.displayName, track.durationMs, track.title, track.artist,
          track.album, track.folder,
        ),
                      artSize: 512,
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(track.title,
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text(track.artist,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context)
                              .textTheme
                              .bodyLarge
                              ?.color
                              ?.withOpacity(0.7)),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  Slider(
                    min: 0,
                    max: playback.duration.inMilliseconds > 0
                        ? playback.duration.inMilliseconds.toDouble()
                        : 1,
                    value: playback.position.inMilliseconds
                        .clamp(0, playback.duration.inMilliseconds).toInt()
                        .toDouble(),
                    onChanged: (v) =>
                        controller.seek(Duration(milliseconds: v.toInt())),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmt(playback.position)),
                        Text(_fmt(playback.duration)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        iconSize: 40,
                        icon: const Icon(Icons.skip_previous),
                        onPressed: controller.previous,
                      ),
                      IconButton(
                        iconSize: 72,
                        icon: Icon(playback.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled),
                        onPressed: controller.togglePlayPause,
                      ),
                      IconButton(
                        iconSize: 40,
                        icon: const Icon(Icons.skip_next),
                        onPressed: controller.next,
                      ),
                    ],
                  ),
                  const Spacer(),
                ],
              ),
            ),
    );
  }
}

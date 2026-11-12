import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets/track_artwork.dart';
import '../../core/widgets/sleep_timer_sheet.dart';
import '../../core/localization.dart';
import '../equalizer/equalizer_screen.dart';
import '../lyrics/lrc_parser.dart';
import '../lyrics/lyrics_screen.dart';
import '../../data/db/track.dart';

/// Full-screen V27 PULSE playback experience.
enum _NowPlayingView { cover, lyrics, queue }

class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});
  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  _NowPlayingView _view = _NowPlayingView.cover;

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final strings = V27Strings.of(context);
    final track = ref.watch(currentTrackProvider);
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
              strings.text('now_playing'),
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.8,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'V27 PULSE',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                letterSpacing: 2.2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.equalizer_rounded),
            tooltip: V27Strings.of(context).text('equalizer'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EqualizerScreen()),
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

                  return Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 18),
                    child: Column(
                      mainAxisAlignment: _view == _NowPlayingView.cover ? MainAxisAlignment.spaceEvenly : MainAxisAlignment.start,
                      children: _view == _NowPlayingView.cover ? [
                        const SizedBox(height: 2),
                        Container(
                          width: artworkSize,
                          height: artworkSize,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: isDark ? 0.22 : 0.09,
                                ),
                                blurRadius: 18,
                                offset: const Offset(0, 8),
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
                        const _NowPlayingProgress(),
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
                            const SizedBox(width: 24),
                            const _NowPlayingPlayButton(),
                            const SizedBox(width: 24),
                            IconButton(
                              tooltip: 'Next track',
                              onPressed: controller.next,
                              icon: const Icon(Icons.skip_next_rounded),
                              iconSize: 38,
                              color: theme.colorScheme.onSurface,
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              tooltip: strings.text('sleep_timer'),
                              onPressed: () => showSleepTimerSheet(context),
                              icon: const Icon(Icons.bedtime_outlined),
                              color: theme.colorScheme.primary,
                            ),
                          ],
                        ),
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          IconButton(tooltip: strings.text('lyrics'), onPressed: () => setState(() => _view = _NowPlayingView.lyrics), icon: const Icon(Icons.lyrics_rounded)),
                          IconButton(tooltip: strings.text('whats_next'), onPressed: () => setState(() => _view = _NowPlayingView.queue), icon: const Icon(Icons.queue_music_rounded)),
                        ]),
                        const SizedBox(height: 2),
                      ] : [
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () => setState(() => _view = _NowPlayingView.cover),
                          child: Row(children: [
                            ClipRRect(borderRadius: BorderRadius.circular(12), child: TrackArtwork(contentUri: track.contentUri, version: Object.hash(track.contentUri, track.dateModified, track.title, track.artist), size: 64, artSize: 128)),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                              Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                            ])),
                            IconButton(onPressed: () => setState(() => _view = _NowPlayingView.cover), icon: const Icon(Icons.close_rounded)),
                          ]),
                        ),
                        const SizedBox(height: 8),
                        Expanded(child: _view == _NowPlayingView.lyrics ? _InlineLyricsPanel(track: track) : _UpcomingQueuePanel()),
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          IconButton(onPressed: controller.previous, icon: const Icon(Icons.skip_previous_rounded), iconSize: 30),
                          const _NowPlayingPlayButton(),
                          IconButton(onPressed: controller.next, icon: const Icon(Icons.skip_next_rounded), iconSize: 30),
                          IconButton(tooltip: strings.text('sleep_timer'), onPressed: () => showSleepTimerSheet(context), icon: const Icon(Icons.bedtime_outlined)),
                        ]),
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          IconButton(tooltip: strings.text('lyrics'), onPressed: () => setState(() => _view = _view == _NowPlayingView.lyrics ? _NowPlayingView.cover : _NowPlayingView.lyrics), icon: const Icon(Icons.lyrics_rounded)),
                          IconButton(tooltip: strings.text('whats_next'), onPressed: () => setState(() => _view = _view == _NowPlayingView.queue ? _NowPlayingView.cover : _NowPlayingView.queue), icon: const Icon(Icons.queue_music_rounded)),
                        ]),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}


class _InlineLyricsPanel extends ConsumerStatefulWidget {
  const _InlineLyricsPanel({required this.track});
  final Track track;
  @override
  ConsumerState<_InlineLyricsPanel> createState() => _InlineLyricsPanelState();
}

class _InlineLyricsPanelState extends ConsumerState<_InlineLyricsPanel> {
  late Future<String?> _lyrics;
  final ScrollController _scroll = ScrollController();
  int _lastIndex = -1;
  @override
  void initState() { super.initState(); _lyrics = _load(); }
  Future<String?> _load() async {
    final repo = ref.read(libraryRepositoryProvider);
    return repo?.ensureLyrics(widget.track);
  }
  @override
  void didUpdateWidget(covariant _InlineLyricsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.contentUri != widget.track.contentUri) {
      _lastIndex = -1;
      _lyrics = _load();
    }
  }
  @override
  void dispose() { _scroll.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final position = ref.watch(playbackControllerProvider.select((s) => s.position));
    return FutureBuilder<String?>(future: _lyrics, builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
      if (snapshot.hasError) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text(V27Strings.of(context).text('could_not_load_lyrics')), TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LyricsScreen(track: widget.track))), child: Text(V27Strings.of(context).text('open_lyrics_tools')))]));
      final raw = snapshot.data?.trim() ?? '';
      if (raw.isEmpty) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text(V27Strings.of(context).text('no_lyrics_found'), style: Theme.of(context).textTheme.bodyLarge), TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LyricsScreen(track: widget.track))), child: Text(V27Strings.of(context).text('open_lyrics_tools')))]));
      final lines = LrcParser.parse(raw);
      if (lines.isEmpty) return SingleChildScrollView(padding: const EdgeInsets.all(16), child: Text(raw, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium?.copyWith(height: 1.7)));
      final active = LrcParser.activeLineIndex(lines, position);
      if (active != _lastIndex) {
        _lastIndex = active;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scroll.hasClients || !mounted) return;
          final target = (active * 58.0).clamp(0.0, _scroll.position.maxScrollExtent).toDouble();
          _scroll.animateTo(target, duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
        });
      }
      return ListView.builder(
        controller: _scroll,
        itemCount: lines.length,
        itemExtent: 58,
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemBuilder: (context, index) {
          final selected = index == active;
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                lines[index].text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: selected ? 20 : 15,
                  height: 1.25,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: .65),
                ),
              ),
            ),
          );
        },
      );
    });
  }
}

class _UpcomingQueuePanel extends ConsumerWidget {
  const _UpcomingQueuePanel();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(playbackControllerProvider.select((s) => (s.currentTrackId, s.currentTrackVolume)));
    return FutureBuilder<List<Track>>(
      key: ValueKey(identity),
      future: ref.read(playbackControllerProvider.notifier).loadUpcomingQueueTracks(limit: 40),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final tracks = snapshot.data ?? const <Track>[];
        if (tracks.isEmpty) return Center(child: Text(V27Strings.of(context).text('no_upcoming_tracks'), style: Theme.of(context).textTheme.bodyLarge));
        return ListView.builder(itemCount: tracks.length, itemBuilder: (context, index) {
          final track = tracks[index];
          return ListTile(
            dense: true,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: TrackArtwork(
                contentUri: track.contentUri,
                version: Object.hash(track.contentUri, track.dateModified, track.title, track.artist),
                size: 44,
                artSize: 96,
              ),
            ),
            title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => ref.read(playbackControllerProvider.notifier)
                .playTrackFromActiveQueue(track),
          );
        });
      },
    );
  }
}

class _NowPlayingProgress extends ConsumerWidget {
  const _NowPlayingProgress();

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
    final playback = ref.watch(
      playbackControllerProvider.select(
        (state) => (state.position, state.duration),
      ),
    );
    final controller = ref.read(playbackControllerProvider.notifier);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final durationMs = playback.$2.inMilliseconds;
    final maxMs = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final positionMs = playback.$1.inMilliseconds
        .clamp(0, durationMs > 0 ? durationMs : 0)
        .toDouble();

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: theme.colorScheme.primary,
            inactiveTrackColor: isDark
                ? V27Palette.darkBorder
                : V27Palette.lightBorder,
            thumbColor: theme.colorScheme.primary,
            overlayColor: theme.colorScheme.primary.withValues(alpha: 0.12),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _fmt(playback.$1),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                _fmt(playback.$2),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NowPlayingPlayButton extends ConsumerWidget {
  const _NowPlayingPlayButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(
      playbackControllerProvider.select((state) => state.isPlaying),
    );
    final controller = ref.read(playbackControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.primary,
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.16),
            blurRadius: 12,
            offset: const Offset(0, 4),
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
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 43,
            color: scheme.onPrimary,
          ),
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
                    theme.colorScheme.primary.withValues(alpha: 0.18),
                    theme.colorScheme.secondary.withValues(alpha: 0.08),
                  ],
                ),
              ),
              child: Icon(
                Icons.music_off_rounded,
                size: 48,
                color: theme.colorScheme.primary,
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

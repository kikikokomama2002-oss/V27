import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers.dart';
import '../../core/library_navigation.dart';
import '../../core/library_tab_settings.dart';
import '../../core/widgets/v27_bottom_navigation.dart';
import '../../core/playlist_store.dart';
import '../../core/widgets/playlist_name_dialog.dart';
import '../../core/theme.dart';
import '../../core/widgets/track_artwork.dart';
import '../../core/widgets/sleep_timer_sheet.dart';
import '../../core/localization.dart';
import '../equalizer/equalizer_screen.dart';
import '../lyrics/lrc_parser.dart';
import '../lyrics/lyrics_screen.dart';
import '../../data/db/track.dart';
import '../../data/repositories/library_repository.dart';
import '../../playback/player_channel.dart';
import '../../playback/queue_spec.dart';

/// Full-screen V27 PULSE playback experience.
enum _NowPlayingView { cover, lyrics, queue }

class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});
  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  static const _speedPreferenceKey = 'v27_playback_speed_v1';
  static const _speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  _NowPlayingView _view = _NowPlayingView.cover;
  bool _repeatCurrent = false;
  bool _repeatLoaded = false;
  bool _repeatSaving = false;
  double _speed = 1.0;
  bool _speedLoaded = false;
  bool _speedSaving = false;

  @override
  void initState() {
    super.initState();
    _loadPlaybackOptions();
  }

  Future<void> _loadPlaybackOptions() async {
    try {
      final values = await Future.wait<Object>([
        PlayerChannel.instance.getRepeatCurrentTrackEnabled(),
        SharedPreferences.getInstance(),
      ]);
      final prefs = values[1] as SharedPreferences;
      final savedSpeed = prefs.getDouble(_speedPreferenceKey) ?? 1.0;
      final selectedSpeed = _speeds.reduce(
        (a, b) => (a - savedSpeed).abs() <= (b - savedSpeed).abs() ? a : b,
      );
      try {
        await PlayerChannel.instance.setPlaybackSpeed(selectedSpeed);
      } catch (_) {
        // Keep the stored choice visible; the settings surface reports
        // playback-speed failures when the user changes it manually.
      }
      if (!mounted) return;
      setState(() {
        _repeatCurrent = values[0] as bool;
        _repeatLoaded = true;
        _speed = selectedSpeed;
        _speedLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _repeatLoaded = true;
        _speedLoaded = true;
      });
    }
  }

  Future<void> _toggleRepeat(bool enabled) async {
    if (_repeatSaving || !_repeatLoaded) return;
    final previous = _repeatCurrent;
    setState(() {
      _repeatCurrent = enabled;
      _repeatSaving = true;
    });
    try {
      await PlayerChannel.instance.setRepeatCurrentTrackEnabled(enabled);
    } catch (_) {
      if (!mounted) return;
      setState(() => _repeatCurrent = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(V27Strings.of(context).text('could_not_update_repeat'))),
      );
    } finally {
      if (mounted) setState(() => _repeatSaving = false);
    }
  }

  Future<void> _changeSpeed(double speed) async {
    if (_speedSaving || !_speedLoaded || speed == _speed) return;
    final previous = _speed;
    setState(() {
      _speed = speed;
      _speedSaving = true;
    });
    try {
      await PlayerChannel.instance.setPlaybackSpeed(speed);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_speedPreferenceKey, speed);
    } catch (_) {
      if (!mounted) return;
      setState(() => _speed = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(V27Strings.of(context).text('could_not_change_speed'))),
      );
    } finally {
      if (mounted) setState(() => _speedSaving = false);
    }
  }

  void _onBottomDestination(int index) {
    switch (index) {
      case 0:
        ref.read(libraryTabSelectionProvider.notifier).state = LibraryTab.home;
        Navigator.of(context).popUntil((route) => route.isFirst);
        break;
      case 1:
        ref.read(libraryTabSelectionProvider.notifier).state = LibraryTab.tracks;
        Navigator.of(context).popUntil((route) => route.isFirst);
        break;
      case 2:
        break;
      case 3:
        Navigator.of(context).pushNamed('/settings').then((_) {
          if (mounted) _loadPlaybackOptions();
        });
        break;
    }
  }

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
          if (track != null)
            PopupMenuButton<String>(
              tooltip: strings.text('track_options'),
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (action) => _handleNowPlayingTrackAction(context, ref, track, action),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'set_as', child: _NowPlayingMenuLabel(icon: Icons.notifications_active_outlined, label: strings.text('set_as'))),
                PopupMenuItem(value: 'share', child: _NowPlayingMenuLabel(icon: Icons.share_outlined, label: strings.text('share'))),
                PopupMenuItem(value: 'delete', child: _NowPlayingMenuLabel(icon: Icons.delete_outline_rounded, label: strings.text('delete'))),
                PopupMenuItem(value: 'details', child: _NowPlayingMenuLabel(icon: Icons.info_outline_rounded, label: strings.text('track_details'))),
                PopupMenuItem(value: 'add_to_playlist', child: _NowPlayingMenuLabel(icon: Icons.playlist_add_rounded, label: strings.text('add_to_playlist'))),
                PopupMenuItem(value: 'album', enabled: track.album.trim().isNotEmpty, child: _NowPlayingMenuLabel(icon: Icons.album_outlined, label: strings.text('album'))),
                PopupMenuItem(value: 'artist', enabled: track.artist.trim().isNotEmpty, child: _NowPlayingMenuLabel(icon: Icons.person_outline_rounded, label: strings.text('artist'))),
              ],
            ),
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
                    constraints.maxHeight * 0.31,
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
                            border: Border.all(
                              color: theme.colorScheme.primary.withValues(alpha: 0.20),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: isDark ? 0.12 : 0.07,
                                ),
                                blurRadius: 30,
                                spreadRadius: 1,
                              ),
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
                        TextButton.icon(
                          onPressed: () => _handleNowPlayingTrackAction(
                            context,
                            ref,
                            track,
                            'add_to_playlist',
                          ),
                          icon: const Icon(Icons.playlist_add_rounded, size: 18),
                          label: Text(strings.text('add_to_playlist')),
                        ),
                        const _NowPlayingProgress(),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              tooltip: strings.text('previous_track'),
                              onPressed: controller.previous,
                              icon: const Icon(Icons.skip_previous_rounded),
                              iconSize: 38,
                              color: theme.colorScheme.onSurface,
                            ),
                            const SizedBox(width: 24),
                            const _NowPlayingPlayButton(),
                            const SizedBox(width: 24),
                            IconButton(
                              tooltip: strings.text('next_track'),
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
                        _PlaybackUtilityRow(
                          repeatCurrent: _repeatCurrent,
                          repeatLoaded: _repeatLoaded && !_repeatSaving,
                          speed: _speed,
                          speedLoaded: _speedLoaded && !_speedSaving,
                          onRepeatChanged: _toggleRepeat,
                          onSpeedSelected: _changeSpeed,
                          onEqualizer: () => Navigator.of(context).pushNamed('/equalizer'),
                        ),
                        _NowPlayingPanelControls(
                          view: _view,
                          onSong: () => setState(() => _view = _NowPlayingView.cover),
                          onLyrics: () => setState(() => _view = _NowPlayingView.lyrics),
                          onQueue: () => setState(() => _view = _NowPlayingView.queue),
                        ),
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
                        _PlaybackUtilityRow(
                          repeatCurrent: _repeatCurrent,
                          repeatLoaded: _repeatLoaded && !_repeatSaving,
                          speed: _speed,
                          speedLoaded: _speedLoaded && !_speedSaving,
                          onRepeatChanged: _toggleRepeat,
                          onSpeedSelected: _changeSpeed,
                          onEqualizer: () => Navigator.of(context).pushNamed('/equalizer'),
                        ),
                        _NowPlayingPanelControls(
                          view: _view,
                          onSong: () => setState(() => _view = _NowPlayingView.cover),
                          onLyrics: () => setState(() => _view = _view == _NowPlayingView.lyrics ? _NowPlayingView.cover : _NowPlayingView.lyrics),
                          onQueue: () => setState(() => _view = _view == _NowPlayingView.queue ? _NowPlayingView.cover : _NowPlayingView.queue),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: V27BottomNavigation(
          selectedIndex: 2,
          onDestinationSelected: _onBottomDestination,
        ),
      ),
    );
  }
}


class _PlaybackUtilityRow extends StatelessWidget {
  const _PlaybackUtilityRow({
    required this.repeatCurrent,
    required this.repeatLoaded,
    required this.speed,
    required this.speedLoaded,
    required this.onRepeatChanged,
    required this.onSpeedSelected,
    required this.onEqualizer,
  });

  final bool repeatCurrent;
  final bool repeatLoaded;
  final double speed;
  final bool speedLoaded;
  final ValueChanged<bool> onRepeatChanged;
  final ValueChanged<double> onSpeedSelected;
  final VoidCallback onEqualizer;

  static const _speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  @override
  Widget build(BuildContext context) {
    final strings = V27Strings.of(context);
    final theme = Theme.of(context);
    final selectedColor = theme.colorScheme.primary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: _UtilityAction(
            icon: Icons.repeat_one_rounded,
            label: strings.text('repeat_current'),
            selected: repeatCurrent,
            enabled: repeatLoaded,
            onTap: () => onRepeatChanged(!repeatCurrent),
          ),
        ),
        Expanded(
          child: PopupMenuButton<double>(
            enabled: speedLoaded,
            tooltip: strings.text('play_speed'),
            onSelected: onSpeedSelected,
            itemBuilder: (context) => _speeds.map((value) => PopupMenuItem<double>(
              value: value,
              child: Row(
                children: [
                  SizedBox(width: 54, child: Text('${value.toString()}x')),
                  if (value == speed) Icon(Icons.check_rounded, color: selectedColor, size: 18),
                ],
              ),
            )).toList(growable: false),
            child: _UtilityActionContent(
              icon: Icons.speed_rounded,
              label: strings.text('play_speed'),
              value: speedLoaded ? '${speed.toString()}x' : strings.text('loading'),
              selected: false,
            ),
          ),
        ),
        Expanded(
          child: _UtilityAction(
            icon: Icons.equalizer_rounded,
            label: strings.text('equalizer'),
            selected: false,
            enabled: true,
            onTap: onEqualizer,
          ),
        ),
      ],
    );
  }
}

class _UtilityAction extends StatelessWidget {
  const _UtilityAction({
    required this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(14),
      child: _UtilityActionContent(icon: icon, label: label, selected: selected),
    ),
  );
}

class _UtilityActionContent extends StatelessWidget {
  const _UtilityActionContent({
    required this.icon,
    required this.label,
    this.value,
    required this.selected,
  });

  final IconData icon;
  final String label;
  final String? value;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 21, color: color),
          const SizedBox(height: 4),
          Text(
            value ?? label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
          if (value != null) Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall?.copyWith(fontSize: 9, color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _NowPlayingMenuLabel extends StatelessWidget {
  const _NowPlayingMenuLabel({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(icon, size: 20),
    const SizedBox(width: 10),
    Text(label),
  ]);
}

class _NowPlayingPanelControls extends StatelessWidget {
  const _NowPlayingPanelControls({
    required this.view,
    required this.onSong,
    required this.onLyrics,
    required this.onQueue,
  });

  final _NowPlayingView view;
  final VoidCallback onSong;
  final VoidCallback onLyrics;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget control({
      required IconData icon,
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: FilledButton.tonalIcon(
            onPressed: onTap,
            icon: Icon(icon, size: 17),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            style: FilledButton.styleFrom(
              backgroundColor: selected
                  ? theme.colorScheme.primary.withValues(alpha: .18)
                  : theme.colorScheme.surfaceContainerHighest.withValues(alpha: .55),
              foregroundColor: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 10),
              textStyle: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
                side: BorderSide(
                  color: selected
                      ? theme.colorScheme.primary.withValues(alpha: .38)
                      : theme.colorScheme.outlineVariant.withValues(alpha: .45),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        control(
          icon: Icons.album_rounded,
          label: V27Strings.of(context).text('song'),
          selected: view == _NowPlayingView.cover,
          onTap: onSong,
        ),
        control(
          icon: Icons.lyrics_rounded,
          label: V27Strings.of(context).text('lyrics'),
          selected: view == _NowPlayingView.lyrics,
          onTap: onLyrics,
        ),
        control(
          icon: Icons.queue_music_rounded,
          label: V27Strings.of(context).text('whats_next'),
          selected: view == _NowPlayingView.queue,
          onTap: onQueue,
        ),
      ],
    );
  }
}

Future<void> _handleNowPlayingTrackAction(BuildContext context, WidgetRef ref, Track track, String action) async {
  switch (action) {
    case 'set_as':
      await _nowPlayingSetAs(context, track);
      break;
    case 'share':
      try {
        await PlayerChannel.instance.shareTrackFile(contentUri: track.contentUri, title: track.title);
      } on PlatformException {
        if (context.mounted) _nowPlayingMessage(context, V27Strings.of(context).text('could_not_share'));
      }
      break;
    case 'delete':
      await _nowPlayingDelete(context, ref, track);
      break;
    case 'details':
      await _nowPlayingDetails(context, track);
      break;
    case 'add_to_playlist':
      await _nowPlayingAddToPlaylist(context, ref, track);
      break;
    case 'album':
      await _openNowPlayingGroup(context, track, GroupField.album);
      break;
    case 'artist':
      await _openNowPlayingGroup(context, track, GroupField.artist);
      break;
  }
}

void _nowPlayingMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

Future<void> _nowPlayingDelete(BuildContext context, WidgetRef ref, Track track) async {
  final strings = V27Strings.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(strings.text('delete_track')),
      content: Text(strings.text('track_delete_confirm')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(strings.text('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(strings.text('delete'))),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    final deleted = await PlayerChannel.instance.deleteMediaStoreTrack(track.contentUri);
    if (!context.mounted) return;
    if (!deleted) {
      _nowPlayingMessage(context, strings.text('deletion_cancelled'));
      return;
    }
    final repo = ref.read(libraryRepositoryProvider);
    if (repo != null) await repo.scanAndPersist();
    if (context.mounted) _nowPlayingMessage(context, strings.text('track_deleted'));
  } on PlatformException {
    if (context.mounted) _nowPlayingMessage(context, strings.text('could_not_delete_track'));
  } catch (_) {
    if (context.mounted) _nowPlayingMessage(context, strings.text('track_deleted_refresh_error'));
  }
}

Future<void> _nowPlayingDetails(BuildContext context, Track track) async {
  final duration = Duration(milliseconds: track.durationMs);
  final h = duration.inHours;
  final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final sec = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final durationText = h > 0 ? '${h.toString().padLeft(2, '0')}:$m:$sec' : '$m:$sec';
  final strings = V27Strings.of(context);
  final details = <(String, String)>[
    (strings.text('detail_title'), track.title),
    (strings.text('artist'), track.artist),
    (strings.text('album'), track.album),
    (strings.text('duration'), durationText),
    (strings.text('file_name'), track.displayName),
    (strings.text('folder'), track.relativePath?.trim().isNotEmpty == true ? track.relativePath! : track.folder),
    (strings.text('storage_volume'), track.mediaStoreVolume),
    (strings.text('media_store_id'), track.mediaStoreId.toString()),
  ];
  await showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (sheetContext) => SafeArea(
    child: Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), child: SingleChildScrollView(child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
      children: [Text(track.title, style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)), const SizedBox(height: 12),
        for (final item in details) Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 112, child: Text(item.$1, style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(color: Theme.of(sheetContext).colorScheme.onSurfaceVariant))),
          Expanded(child: Text(item.$2)),
        ])),
      ],
    ))),
  ));
}

Future<void> _nowPlayingSetAs(BuildContext context, Track track) async {
  final strings = V27Strings.of(context);
  final selected = await showModalBottomSheet<String>(context: context, showDragHandle: true, builder: (sheetContext) => SafeArea(child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ListTile(title: Text(strings.text('set_track_as'))),
      ListTile(leading: const Icon(Icons.phone_android_rounded), title: Text(strings.text('ringtone')), onTap: () => Navigator.pop(sheetContext, 'ringtone')),
      ListTile(leading: const Icon(Icons.notifications_active_outlined), title: Text(strings.text('notification_sound')), onTap: () => Navigator.pop(sheetContext, 'notification')),
      ListTile(leading: const Icon(Icons.alarm_rounded), title: Text(strings.text('alarm_sound')), onTap: () => Navigator.pop(sheetContext, 'alarm')),
    ],
  )));
  if (selected == null || !context.mounted) return;
  try {
    final updated = await PlayerChannel.instance.setTrackAsDefaultSound(contentUri: track.contentUri, type: selected);
    if (context.mounted) _nowPlayingMessage(context, updated ? strings.text('default_sound_updated') : strings.text('system_settings_permission_needed'));
  } on PlatformException {
    if (context.mounted) _nowPlayingMessage(context, strings.text('could_not_update_setting'));
  }
}

Future<void> _nowPlayingAddToPlaylist(BuildContext context, WidgetRef ref, Track track) async {
  final store = ref.read(playlistStoreProvider.notifier);
  await store.ready;
  if (!context.mounted) return;
  final state = ref.read(playlistStoreProvider);
  const createAction = '__create_playlist__';
  final strings = V27Strings.of(context);
  final selectedId = await showModalBottomSheet<String>(context: context, builder: (sheetContext) => SafeArea(child: ListView(
    shrinkWrap: true,
    children: [
      ListTile(title: Text(strings.text('add_song_playlist'))),
      ...state.playlists.map((playlist) => ListTile(leading: const Icon(Icons.queue_music), title: Text(playlist.name), subtitle: Text('${playlist.songs.length} ${strings.text('songs')}'), onTap: () => Navigator.pop(sheetContext, playlist.id))),
      ListTile(leading: const Icon(Icons.add), title: Text('${strings.text('create_playlist')}…'), onTap: () => Navigator.pop(sheetContext, createAction)),
    ],
  )));
  if (selectedId == null || !context.mounted) return;
  var playlistId = selectedId;
  if (selectedId == createAction) {
    final name = await showDialog<String>(context: context, builder: (_) => PlaylistNameDialog(title: strings.text('create_playlist'), submitLabel: strings.text('create')));
    if (name == null || !context.mounted) return;
    final created = await store.createPlaylist(name);
    if (created == null) { _nowPlayingMessage(context, strings.text('playlist_name_invalid')); return; }
    playlistId = created.id;
  }
  final added = await store.addTrack(playlistId, track);
  if (context.mounted) _nowPlayingMessage(context, added ? strings.text('added_to_playlist').replaceAll('{title}', track.title) : strings.text('already_in_playlist'));
}

Future<void> _openNowPlayingGroup(BuildContext context, Track track, GroupField field) async {
  final name = (field == GroupField.album ? track.album : track.artist).trim();
  if (name.isEmpty) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _NowPlayingGroupPage(field: field, name: name)));
}

class _NowPlayingGroupPage extends ConsumerWidget {
  const _NowPlayingGroupPage({required this.field, required this.name});
  final GroupField field;
  final String name;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = GroupKey(field, name);
    final notifier = ref.read(groupTracksPagingProvider(key).notifier);
    notifier.ensureCountLoaded();
    final paging = ref.watch(groupTracksPagingProvider(key));
    final count = paging.totalCount;
    return Scaffold(
      appBar: AppBar(title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: count == null ? const Center(child: CircularProgressIndicator()) : count == 0 ? Center(child: Text(V27Strings.of(context).text('no_tracks_found'))) : ListView.builder(
        itemCount: count, itemExtent: 72,
        itemBuilder: (context, index) {
          final track = notifier.itemAt(index);
          if (track == null) return const ListTile(title: LinearProgressIndicator());
          return ListTile(
            leading: TrackArtwork(contentUri: track.contentUri, version: Object.hash(track.contentUri, track.dateModified), size: 48, artSize: 96),
            title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => ref.read(playbackControllerProvider.notifier).playQueue(GroupQueueSpec(field, name), startIndex: index, startVolume: track.mediaStoreVolume, startMediaStoreId: track.mediaStoreId),
          );
        },
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
              V27Strings.of(context).text('nothing_playing'),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              V27Strings.of(context).text('choose_track'),
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

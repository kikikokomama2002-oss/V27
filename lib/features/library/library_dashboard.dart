import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/playlist_store.dart';
import '../../core/localization.dart';
import '../../core/providers.dart';
import '../../core/widgets/playlist_name_dialog.dart';
import '../../core/widgets/track_artwork.dart';
import '../../data/db/track.dart';
import '../../data/repositories/library_repository.dart';
import '../../playback/queue_spec.dart';
import '../player/mini_player.dart';
import '../../core/library_tab_settings.dart';

/// Resolves only the first available local track for a playlist cover. This
/// is kept separate from playback queue paging and skips stale/deleted
/// MediaStore identities in bounded chunks.
final playlistPreviewTrackProvider =
    FutureProvider.autoDispose.family<Track?, String>((ref, playlistId) async {
  ref.watch(libraryChangesProvider);
  final playlistState = ref.watch(playlistStoreProvider);
  UserPlaylist? playlist;
  for (final item in playlistState.playlists) {
    if (item.id == playlistId) {
      playlist = item;
      break;
    }
  }
  final repo = ref.watch(libraryRepositoryProvider);
  if (playlist == null || repo == null) return null;

  const chunkSize = 80;
  for (var attempt = 0; attempt < 3; attempt++) {
    final generation = await repo.waitForStableSnapshot();
    Track? preview;
    for (var offset = 0; offset < playlist.songs.length; offset += chunkSize) {
      final end = math.min(offset + chunkSize, playlist.songs.length).toInt();
      final resolved = await repo.tracksForMediaStoreIdentities(
        playlist.songs
            .sublist(offset, end)
            .map((song) => (volume: song.volume, id: song.mediaStoreId))
            .toList(growable: false),
      );
      if (resolved.isNotEmpty) {
        preview = resolved.first;
        break;
      }
    }
    if (generation == repo.libraryGeneration && !repo.scanInProgress) {
      return preview;
    }
  }
  throw const LibrarySnapshotUnstableException();
});

/// Resolves one playlist row at a time. The detail page uses a lazy ListView,
/// so a very large playlist does not materialize every Track in memory.
final playlistTrackAtProvider = FutureProvider.autoDispose.family<Track?, ({
  String playlistId,
  int index,
})>((ref, key) async {
  ref.watch(libraryChangesProvider);
  final state = ref.watch(playlistStoreProvider);
  UserPlaylist? playlist;
  for (final item in state.playlists) {
    if (item.id == key.playlistId) {
      playlist = item;
      break;
    }
  }
  if (playlist == null || key.index < 0 || key.index >= playlist.songs.length) {
    return null;
  }
  final repo = ref.watch(libraryRepositoryProvider);
  if (repo == null) return null;
  final identity = playlist.songs[key.index];
  for (var attempt = 0; attempt < 3; attempt++) {
    final generation = await repo.waitForStableSnapshot();
    final tracks = await repo.tracksForMediaStoreIdentities([
      (volume: identity.volume, id: identity.mediaStoreId),
    ]);
    if (generation == repo.libraryGeneration && !repo.scanInProgress) {
      return tracks.isEmpty ? null : tracks.first;
    }
  }
  throw const LibrarySnapshotUnstableException();
});

/// Offline-first dashboard inspired by music-library home screens. Every
/// section is populated from the local Isar library or local playlists; no
/// remote recommendations or community content is implied.
class LibraryDashboard extends ConsumerWidget {
  const LibraryDashboard({
    super.key,
    required this.onSelectTab,
    required this.onTrackAction,
  });

  final ValueChanged<LibraryTab> onSelectTab;
  final void Function(BuildContext context, Track track, String action) onTrackAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackCount = ref.watch(libraryTrackCountProvider).valueOrNull;

    final albumsNotifier = ref.read(groupsPagingProvider(GroupField.album).notifier);
    albumsNotifier.ensureCountLoaded();
    final albumsState = ref.watch(groupsPagingProvider(GroupField.album));

    final artistsNotifier = ref.read(groupsPagingProvider(GroupField.artist).notifier);
    artistsNotifier.ensureCountLoaded();
    final artistsState = ref.watch(groupsPagingProvider(GroupField.artist));

    final foldersNotifier = ref.read(groupsPagingProvider(GroupField.folder).notifier);
    foldersNotifier.ensureCountLoaded();
    final foldersState = ref.watch(groupsPagingProvider(GroupField.folder));

    final playlistState = ref.watch(playlistStoreProvider);

    return CustomScrollView(
      key: const PageStorageKey<String>('v27-library-home'),
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: _SpeedDialSection(
            trackCount: trackCount,
            albumCount: albumsState.totalCount,
            artistCount: artistsState.totalCount,
            playlistCount: playlistState.playlists.length,
            onSelectTab: onSelectTab,
          ),
        ),
        SliverToBoxAdapter(
          child: _QuickPicksSection(
            onSelectAll: () => onSelectTab(LibraryTab.tracks),
            onTrackAction: onTrackAction,
          ),
        ),
        SliverToBoxAdapter(
          child: _DashboardGroupShelf(
            title: V27Strings.of(context).text('albums_in_library'),
            field: GroupField.album,
            notifier: albumsNotifier,
            totalCount: albumsState.totalCount,
            countError: albumsState.countError,
            onSeeAll: () => onSelectTab(LibraryTab.albums),
          ),
        ),
        SliverToBoxAdapter(
          child: _DashboardGroupShelf(
            title: V27Strings.of(context).text('explore_artists'),
            field: GroupField.artist,
            notifier: artistsNotifier,
            totalCount: artistsState.totalCount,
            countError: artistsState.countError,
            onSeeAll: () => onSelectTab(LibraryTab.artists),
          ),
        ),
        SliverToBoxAdapter(
          child: _DashboardPlaylistsShelf(
            playlistState: playlistState,
            onSeeAll: () => onSelectTab(LibraryTab.playlists),
          ),
        ),
        SliverToBoxAdapter(
          child: _DashboardGroupShelf(
            title: V27Strings.of(context).text('browse_folders'),
            field: GroupField.folder,
            notifier: foldersNotifier,
            totalCount: foldersState.totalCount,
            countError: foldersState.countError,
            onSeeAll: () => onSelectTab(LibraryTab.folders),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 22)),
      ],
    );
  }
}

class _SpeedDialSection extends StatelessWidget {
  const _SpeedDialSection({
    required this.trackCount,
    required this.albumCount,
    required this.artistCount,
    required this.playlistCount,
    required this.onSelectTab,
  });

  final int? trackCount;
  final int? albumCount;
  final int? artistCount;
  final int playlistCount;
  final ValueChanged<LibraryTab> onSelectTab;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shortcuts = <_LibraryShortcutData>[
      _LibraryShortcutData(
        title: V27Strings.of(context).text('all_tracks'),
        subtitle: _countLabel(context, trackCount, 'song'),
        icon: Icons.music_note_rounded,
        tab: LibraryTab.tracks,
      ),
      _LibraryShortcutData(
        title: V27Strings.of(context).text('playlists'),
        subtitle: _countLabel(context, playlistCount, 'playlist'),
        icon: Icons.queue_music_rounded,
        tab: LibraryTab.playlists,
      ),
      _LibraryShortcutData(
        title: V27Strings.of(context).text('albums'),
        subtitle: _countLabel(context, albumCount, 'album'),
        icon: Icons.album_rounded,
        tab: LibraryTab.albums,
      ),
      _LibraryShortcutData(
        title: V27Strings.of(context).text('artists'),
        subtitle: _countLabel(context, artistCount, 'artist'),
        icon: Icons.mic_rounded,
        tab: LibraryTab.artists,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 15, 0, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                V27Strings.of(context).text('speed_dial'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.45,
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(right: 18),
                child: Text(
                  V27Strings.of(context).text('quick_access'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          SizedBox(
            height: 112,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 18),
              itemCount: shortcuts.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) => _ShortcutCard(
                data: shortcuts[index],
                onTap: () => onSelectTab(shortcuts[index].tab),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _countLabel(BuildContext context, int? count, String noun) {
    final strings = V27Strings.of(context);
    if (count == null) return strings.text('loading');
    return '$count ${strings.text(count == 1 ? noun : '${noun}s')}';
  }
}

class _LibraryShortcutData {
  const _LibraryShortcutData({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.tab,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final LibraryTab tab;
}

class _ShortcutCard extends StatelessWidget {
  const _ShortcutCard({required this.data, required this.onTap});

  final _LibraryShortcutData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 142,
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(17),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: SizedBox(
                    width: 34,
                    height: 34,
                    child: Icon(data.icon, color: theme.colorScheme.primary, size: 19),
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      data.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickPicksSection extends ConsumerWidget {
  const _QuickPicksSection({required this.onSelectAll, required this.onTrackAction});

  final VoidCallback onSelectAll;
  final void Function(BuildContext context, Track track, String action) onTrackAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final picks = ref.watch(dashboardQuickPicksProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 19, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DashboardSectionHeading(
            title: V27Strings.of(context).text('quick_picks'),
            actionLabel: V27Strings.of(context).text('see_all'),
            onAction: onSelectAll,
          ),
          const SizedBox(height: 6),
          picks.when(
            loading: () => const Column(
              children: [
                _QuickPickLoadingRow(),
                _QuickPickLoadingRow(),
                _QuickPickLoadingRow(),
              ],
            ),
            error: (_, __) => Row(
              children: [
                Expanded(child: Text(V27Strings.of(context).text('quick_picks_error'))),
                TextButton(
                  onPressed: () => ref.invalidate(dashboardQuickPicksProvider),
                  child: Text(V27Strings.of(context).text('retry')),
                ),
              ],
            ),
            data: (picks) => picks.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    child: Text(
                      V27Strings.of(context).text('scanned_songs_appear'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : Column(
                    children: [
                      for (var index = 0; index < picks.length; index++)
                        _QuickPickRow(pick: picks[index], onTrackAction: onTrackAction),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _DashboardTrackMenuLabel extends StatelessWidget {
  const _DashboardTrackMenuLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Text(label),
        ],
      );
}

class _QuickPickLoadingRow extends StatelessWidget {
  const _QuickPickLoadingRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(11),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(height: 12, width: 125, color: theme.colorScheme.surfaceContainerHighest),
                const SizedBox(height: 8),
                Container(height: 10, width: 84, color: theme.colorScheme.surfaceContainerHighest),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickPickRow extends ConsumerWidget {
  const _QuickPickRow({required this.pick, required this.onTrackAction});

  final DashboardQuickPick pick;
  final void Function(BuildContext context, Track track, String action) onTrackAction;

  Track get track => pick.track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final version = _artVersion(track);
    final currentIdentity = ref.watch(
      playbackControllerProvider.select(
        (state) => (state.currentTrackVolume, state.currentTrackId),
      ),
    );
    final isCurrent = currentIdentity.$2 == track.mediaStoreId &&
        currentIdentity.$1 == track.mediaStoreVolume;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: SizedBox(
        height: 67,
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(11),
                onTap: () => ref.read(playbackControllerProvider.notifier).playQueue(
                  const AllTracksQueueSpec(),
                  startIndex: pick.queueIndex,
                  startVolume: track.mediaStoreVolume,
                  startMediaStoreId: track.mediaStoreId,
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: TrackArtwork(
                        contentUri: track.contentUri,
                        version: version,
                        size: 50,
                        artSize: 128,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: isCurrent ? theme.colorScheme.primary : null,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: V27Strings.of(context).text('track_options'),
              icon: Icon(Icons.more_vert_rounded, color: theme.colorScheme.onSurfaceVariant),
              onSelected: (value) => onTrackAction(context, track, value),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'set_as',
                  child: _DashboardTrackMenuLabel(icon: Icons.notifications_active_outlined, label: V27Strings.of(context).text('set_as')),
                ),
                PopupMenuItem(
                  value: 'share',
                  child: _DashboardTrackMenuLabel(icon: Icons.share_outlined, label: V27Strings.of(context).text('share')),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: _DashboardTrackMenuLabel(icon: Icons.delete_outline_rounded, label: V27Strings.of(context).text('delete')),
                ),
                PopupMenuItem(
                  value: 'details',
                  child: _DashboardTrackMenuLabel(icon: Icons.info_outline_rounded, label: V27Strings.of(context).text('track_details')),
                ),
                PopupMenuItem(
                  value: 'add_to_playlist',
                  child: _DashboardTrackMenuLabel(icon: Icons.playlist_add_rounded, label: V27Strings.of(context).text('add_to_playlist')),
                ),
                PopupMenuItem(
                  value: 'album',
                  enabled: track.album.trim().isNotEmpty,
                  child: _DashboardTrackMenuLabel(icon: Icons.album_outlined, label: V27Strings.of(context).text('album')),
                ),
                PopupMenuItem(
                  value: 'artist',
                  enabled: track.artist.trim().isNotEmpty,
                  child: _DashboardTrackMenuLabel(icon: Icons.person_outline_rounded, label: V27Strings.of(context).text('artist')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardGroupShelf extends ConsumerWidget {
  const _DashboardGroupShelf({
    required this.title,
    required this.field,
    required this.notifier,
    required this.totalCount,
    required this.countError,
    required this.onSeeAll,
  });

  final String title;
  final GroupField field;
  final GroupsPagingNotifier notifier;
  final int? totalCount;
  final Object? countError;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (totalCount == 0) return const SizedBox.shrink();
    final count = totalCount == null ? 4 : math.min(totalCount!, 8).toInt();

    return Padding(
      padding: const EdgeInsets.only(top: 17, bottom: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _DashboardSectionHeading(
              title: title,
              actionLabel: countError == null ? V27Strings.of(context).text('see_all') : V27Strings.of(context).text('retry'),
              onAction: countError == null ? onSeeAll : notifier.retryCount,
            ),
          ),
          const SizedBox(height: 11),
          if (countError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Text(V27Strings.of(context).text('library_unavailable')),
            )
          else
            SizedBox(
              height: 216,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                itemCount: count,
                itemBuilder: (context, index) {
                  final group = totalCount == null ? null : notifier.itemAt(index);
                  return Padding(
                    padding: const EdgeInsets.only(right: 13),
                    child: group == null
                        ? const _GroupCardLoading()
                        : _DashboardGroupCard(field: field, group: group),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _GroupCardLoading extends StatelessWidget {
  const _GroupCardLoading();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 146,
            height: 146,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(15),
            ),
          ),
          const SizedBox(height: 9),
          Container(height: 12, width: 105, color: theme.colorScheme.surfaceContainerHighest),
          const SizedBox(height: 6),
          Container(height: 10, width: 64, color: theme.colorScheme.surfaceContainerHighest),
        ],
      ),
    );
  }
}

class _DashboardGroupCard extends ConsumerWidget {
  const _DashboardGroupCard({required this.field, required this.group});

  final GroupField field;
  final GroupSummary group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final preview = ref.watch(groupPreviewTrackProvider(GroupKey(field, group.name))).valueOrNull;
    final icon = switch (field) {
      GroupField.album => Icons.album_rounded,
      GroupField.artist => Icons.person_rounded,
      GroupField.folder => Icons.folder_rounded,
    };

    return SizedBox(
      width: 150,
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: preview == null
            ? null
            : () => ref.read(playbackControllerProvider.notifier).playQueue(
                  GroupQueueSpec(field, group.name),
                  startIndex: 0,
                  startVolume: preview.mediaStoreVolume,
                  startMediaStoreId: preview.mediaStoreId,
                ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: preview == null
                  ? Container(
                      width: 146,
                      height: 146,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Icon(icon, size: 45, color: theme.colorScheme.primary),
                    )
                  : TrackArtwork(
                      contentUri: preview.contentUri,
                      version: _artVersion(preview),
                      size: 146,
                      artSize: 256,
                      borderRadius: BorderRadius.circular(15),
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              group.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              '${group.trackCount} ${V27Strings.of(context).text(group.trackCount == 1 ? 'song' : 'songs')}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardPlaylistsShelf extends StatelessWidget {
  const _DashboardPlaylistsShelf({required this.playlistState, required this.onSeeAll});

  final PlaylistStoreState playlistState;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (playlistState.isLoading) return const SizedBox.shrink();
    if (playlistState.playlists.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 17, 18, 8),
        child: Material(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => onSeeAll(),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.queue_music_rounded, color: theme.colorScheme.primary, size: 30),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(V27Strings.of(context).text('create_playlist'), style: const TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 3),
                        Text(V27Strings.of(context).text('create_playlist_prompt')),
                      ],
                    ),
                  ),
                  Icon(Icons.arrow_forward_ios_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 17, bottom: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _DashboardSectionHeading(
              title: V27Strings.of(context).text('your_playlists'),
              actionLabel: V27Strings.of(context).text('see_all'),
              onAction: onSeeAll,
            ),
          ),
          const SizedBox(height: 11),
          SizedBox(
            height: 194,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              itemCount: math.min(playlistState.playlists.length, 8).toInt(),
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(right: 13),
                child: _DashboardPlaylistCard(playlist: playlistState.playlists[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardPlaylistCard extends ConsumerWidget {
  const _DashboardPlaylistCard({required this.playlist});

  final UserPlaylist playlist;

  static const _gradients = <List<Color>>[
    [Color(0xFF168F91), Color(0xFF164B58)],
    [Color(0xFFE07852), Color(0xFF783D45)],
    [Color(0xFF4779C7), Color(0xFF263B70)],
    [Color(0xFF668B62), Color(0xFF294D43)],
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = _gradients[playlist.id.hashCode.remainder(_gradients.length).abs().toInt()];
    final preview = ref.watch(playlistPreviewTrackProvider(playlist.id)).valueOrNull;
    return SizedBox(
      width: 150,
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: () => _openPlaylistDetail(context, playlist),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 146,
              height: 146,
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
                borderRadius: BorderRadius.circular(15),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (preview == null)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
                      ),
                      child: const Center(
                        child: Icon(Icons.queue_music_rounded, color: Colors.white, size: 42),
                      ),
                    )
                  else
                    TrackArtwork(
                      contentUri: preview.contentUri,
                      version: _artVersion(preview),
                      artSize: 256,
                      borderRadius: BorderRadius.zero,
                    ),
                  Positioned(
                    right: -9,
                    bottom: -12,
                    child: Icon(Icons.graphic_eq_rounded, size: 90, color: Colors.white.withValues(alpha: 0.14)),
                  ),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.36),
                      shape: const CircleBorder(),
                      child: PopupMenuButton<String>(
                        tooltip: V27Strings.of(context).text('playlist_options'),
                        icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
                        onSelected: (value) => _handlePlaylistAction(context, ref, playlist, value),
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'rename', child: Text(V27Strings.of(context).text('rename'))),
                          PopupMenuItem(value: 'delete', child: Text(V27Strings.of(context).text('delete'))),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
            Text('${playlist.songs.length} ${V27Strings.of(context).text(playlist.songs.length == 1 ? 'song' : 'songs')}', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class LibraryPlaylistDetailPage extends ConsumerWidget {
  const LibraryPlaylistDetailPage({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playlistStoreProvider);
    UserPlaylist? playlist;
    for (final item in state.playlists) {
      if (item.id == playlistId) {
        playlist = item;
        break;
      }
    }
    final theme = Theme.of(context);
    if (state.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (playlist == null) {
      return Scaffold(
        appBar: AppBar(title: Text(V27Strings.of(context).text('playlist'))),
        body: Center(child: Text(V27Strings.of(context).text('playlist_unavailable'))),
      );
    }

    final currentPlaylist = playlist;
    final preview = ref.watch(playlistPreviewTrackProvider(currentPlaylist.id)).valueOrNull;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 18, 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: V27Strings.of(context).text('back'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      V27Strings.of(context).text('your_playlist'),
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: V27Strings.of(context).text('playlist_options'),
                    onSelected: (value) async {
                      await _handlePlaylistAction(context, ref, currentPlaylist, value);
                      final stillExists = ref.read(playlistStoreProvider).playlists
                          .any((item) => item.id == currentPlaylist.id);
                      if (!stillExists && context.mounted) {
                        Navigator.of(context).maybePop();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'rename', child: Text(V27Strings.of(context).text('rename'))),
                      PopupMenuItem(value: 'delete', child: Text(V27Strings.of(context).text('delete'))),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 124,
                    height: 124,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(17),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: preview == null
                        ? Icon(Icons.queue_music_rounded, size: 46, color: theme.colorScheme.primary)
                        : TrackArtwork(
                            contentUri: preview.contentUri,
                            version: _artVersion(preview),
                            artSize: 256,
                            borderRadius: BorderRadius.zero,
                          ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          currentPlaylist.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          V27Strings.of(context).text('playlist_intro'),
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${currentPlaylist.songs.length} ${V27Strings.of(context).text(currentPlaylist.songs.length == 1 ? 'song' : 'songs')}',
                          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: currentPlaylist.songs.isEmpty
                          ? null
                          : () => _playPlaylistFromUi(context, ref, currentPlaylist),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(V27Strings.of(context).text('play_playlist')),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.5)),
            Expanded(
              child: currentPlaylist.songs.isEmpty
                  ? Center(
                      child: Text(
                        V27Strings.of(context).text('add_tracks_prompt'),
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      physics: const BouncingScrollPhysics(),
                      itemCount: currentPlaylist.songs.length,
                      itemExtent: 72,
                      itemBuilder: (context, index) => _PlaylistDetailTrackRow(
                        playlist: currentPlaylist,
                        index: index,
                      ),
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}

class _PlaylistDetailTrackRow extends ConsumerWidget {
  const _PlaylistDetailTrackRow({required this.playlist, required this.index});

  final UserPlaylist playlist;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final result = ref.watch(playlistTrackAtProvider((playlistId: playlist.id, index: index)));
    return result.when(
      loading: () => const _QuickPickLoadingRow(),
      error: (_, __) => ListTile(
        leading: const Icon(Icons.error_outline_rounded),
        title: Text(V27Strings.of(context).text('could_not_load_track')),
      ),
      data: (track) {
        if (track == null) {
          return ListTile(
            leading: Icon(Icons.music_off_rounded, color: theme.colorScheme.onSurfaceVariant),
            title: Text(V27Strings.of(context).text('track_unavailable'), style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
            subtitle: Text(V27Strings.of(context).text('file_removed')),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: Material(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _playPlaylistFromUi(
                context,
                ref,
                playlist,
                startIndex: index,
                startTrack: track,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: TrackArtwork(
                        contentUri: track.contentUri,
                        version: _artVersion(track),
                        size: 48,
                        artSize: 128,
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 3),
                          Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(_durationLabel(track.durationMs), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

String _durationLabel(int durationMs) {
  final duration = Duration(milliseconds: durationMs);
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '${hours.toString().padLeft(2, '0')}:$minutes:$seconds' : '$minutes:$seconds';
}

class LibraryPlaylistsTab extends ConsumerWidget {
  const LibraryPlaylistsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playlistStoreProvider);
    final theme = Theme.of(context);

    if (state.isLoading) return const Center(child: CircularProgressIndicator());
    if (state.playlists.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.queue_music_rounded, size: 58, color: theme.colorScheme.primary),
              const SizedBox(height: 14),
              Text(V27Strings.of(context).text('no_playlists'), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 7),
              Text(V27Strings.of(context).text('create_playlist_prompt'), textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 17),
              FilledButton.icon(
                onPressed: () => _createPlaylist(context, ref),
                icon: const Icon(Icons.add_rounded),
                label: Text(V27Strings.of(context).text('create_playlist')),
              ),
            ],
          ),
        ),
      );
    }

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${state.playlists.length} ${V27Strings.of(context).text(state.playlists.length == 1 ? 'playlist' : 'playlists')}',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _createPlaylist(context, ref),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(V27Strings.of(context).text('create_playlist')),
                ),
              ],
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _PlaylistListRow(playlist: state.playlists[index]),
            childCount: state.playlists.length,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 18)),
      ],
    );
  }
}

class _PlaylistListRow extends ConsumerWidget {
  const _PlaylistListRow({required this.playlist});

  final UserPlaylist playlist;

  static const _gradients = _DashboardPlaylistCard._gradients;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = _gradients[playlist.id.hashCode.remainder(_gradients.length).abs().toInt()];
    final preview = ref.watch(playlistPreviewTrackProvider(playlist.id)).valueOrNull;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          borderRadius: BorderRadius.circular(17),
          onTap: () => _openPlaylistDetail(context, playlist),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: colors),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: preview == null
                      ? const Icon(Icons.queue_music_rounded, color: Colors.white, size: 29)
                      : TrackArtwork(
                          contentUri: preview.contentUri,
                          version: _artVersion(preview),
                          artSize: 128,
                          borderRadius: BorderRadius.zero,
                        ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text('${playlist.songs.length} ${V27Strings.of(context).text(playlist.songs.length == 1 ? 'song' : 'songs')}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: V27Strings.of(context).text('playlist_options'),
                  onSelected: (value) => _handlePlaylistAction(context, ref, playlist, value),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'rename', child: Text(V27Strings.of(context).text('rename'))),
                    PopupMenuItem(value: 'delete', child: Text(V27Strings.of(context).text('delete'))),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashboardSectionHeading extends StatelessWidget {
  const _DashboardSectionHeading({required this.title, this.actionLabel, this.onAction});

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4),
          ),
        ),
        if (actionLabel != null && onAction != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    );
  }
}

Future<void> _createPlaylist(BuildContext context, WidgetRef ref) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => const PlaylistNameDialog(),
  );
  if (name == null || !context.mounted) return;
  final created = await ref.read(playlistStoreProvider.notifier).createPlaylist(name);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(created == null ? V27Strings.of(context).text('playlist_name_invalid') : V27Strings.of(context).text('playlist_created'))),
  );
}

Future<void> _handlePlaylistAction(
  BuildContext context,
  WidgetRef ref,
  UserPlaylist playlist,
  String action,
) async {
  final store = ref.read(playlistStoreProvider.notifier);
  if (action == 'rename') {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => PlaylistNameDialog(
        title: V27Strings.of(context).text('rename_playlist'),
        initialValue: playlist.name,
        submitLabel: 'Save',
      ),
    );
    if (name == null || !context.mounted) return;
    final renamed = await store.renamePlaylist(playlist.id, name);
    if (!context.mounted) return;
    if (!renamed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(V27Strings.of(context).text('playlist_name_invalid'))),
      );
    }
    return;
  }

  if (action == 'delete') {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(V27Strings.of(context).text('delete_playlist_question')),
        content: Text(V27Strings.of(context).text('delete_playlist_confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(V27Strings.of(context).text('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(V27Strings.of(context).text('delete'))),
        ],
      ),
    );
    if (confirmed == true) await store.deletePlaylist(playlist.id);
  }
}

void _openPlaylistDetail(BuildContext context, UserPlaylist playlist) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LibraryPlaylistDetailPage(playlistId: playlist.id),
    ),
  );
}

Future<void> _playPlaylistFromUi(
  BuildContext context,
  WidgetRef ref,
  UserPlaylist playlist, {
  int startIndex = 0,
  Track? startTrack,
}) async {
  final repo = ref.read(libraryRepositoryProvider);
  final playback = ref.read(playbackControllerProvider.notifier);
  if (repo == null) return;

  const chunkSize = 120;
  for (var attempt = 0; attempt < 3; attempt++) {
    final generation = await repo.waitForStableSnapshot();
    Track? firstAvailable;
    if (startTrack != null) {
      final resolved = await repo.tracksForMediaStoreIdentities([
        (volume: startTrack.mediaStoreVolume, id: startTrack.mediaStoreId),
      ]);
      firstAvailable = resolved.isEmpty ? null : resolved.first;
    }

    for (var offset = startTrack == null ? 0 : playlist.songs.length;
        offset < playlist.songs.length;
        offset += chunkSize) {
      final end = math.min(offset + chunkSize, playlist.songs.length).toInt();
      final chunk = playlist.songs.sublist(offset, end);
      final resolved = await repo.tracksForMediaStoreIdentities(
        chunk.map((song) => (volume: song.volume, id: song.mediaStoreId)).toList(growable: false),
      );
      if (resolved.isNotEmpty) {
        firstAvailable = resolved.first;
        break;
      }
    }

    if (generation != repo.libraryGeneration || repo.scanInProgress) continue;
    if (firstAvailable == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(V27Strings.of(context).text('playlist_no_tracks'))),
        );
      }
      return;
    }

    await playback.playQueue(
      PlaylistQueueSpec(playlist.id),
      startIndex: startIndex,
      startVolume: firstAvailable.mediaStoreVolume,
      startMediaStoreId: firstAvailable.mediaStoreId,
    );
    return;
  }

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(V27Strings.of(context).text('library_updating'))),
    );
  }
}

Future<void> _addTrackToPlaylist(BuildContext context, WidgetRef ref, Track track) async {
  final store = ref.read(playlistStoreProvider.notifier);
  await store.ready;
  if (!context.mounted) return;
  final state = ref.read(playlistStoreProvider);
  const createAction = '__create_playlist__';
  final selectedId = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(title: Text(V27Strings.of(context).text('add_song_playlist'))),
          ...state.playlists.map((playlist) => ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: Text(playlist.name),
                subtitle: Text('${playlist.songs.length} ${V27Strings.of(context).text('songs')}'),
                onTap: () => Navigator.pop(sheetContext, playlist.id),
              )),
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: Text('${V27Strings.of(context).text('create_playlist')}…'),
            onTap: () => Navigator.pop(sheetContext, createAction),
          ),
        ],
      ),
    ),
  );
  if (selectedId == null || !context.mounted) return;
  var playlistId = selectedId;
  if (selectedId == createAction) {
    final name = await showDialog<String>(context: context, builder: (_) => const PlaylistNameDialog());
    if (name == null || !context.mounted) return;
    final created = await store.createPlaylist(name);
    if (created == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(V27Strings.of(context).text('playlist_name_invalid'))),
      );
      return;
    }
    playlistId = created.id;
  }
  final added = await store.addTrack(playlistId, track);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(added ? V27Strings.of(context).text('added_to_playlist').replaceAll('{title}', track.title) : V27Strings.of(context).text('already_in_playlist'))),
  );
}

int _artVersion(Track track) => Object.hash(
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
    );

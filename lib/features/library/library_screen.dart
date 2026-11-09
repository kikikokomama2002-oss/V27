import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/playlist_store.dart';
import '../../core/widgets/playlist_name_dialog.dart';
import '../../core/debouncer.dart';
import '../../core/library_tab_settings.dart';

import '../../core/widgets/track_artwork.dart';
import '../../data/db/track.dart';
import '../../data/repositories/library_repository.dart';
import '../../playback/queue_spec.dart';
import '../player/mini_player.dart';
import '../settings/settings_screen.dart';

/// Root library screen: Tracks / Albums / Artists / Folders tabs with a
/// search field, minimal-tap access to the whole library. A persistent
/// [MiniPlayer] sits above the tab content whenever something is loaded.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final List<LibraryTab> _visibleTabs = List<LibraryTab>.unmodifiable(LibraryTab.values);
  late final Debouncer _searchDebounce;
  late final FocusNode _searchFocusNode;

  @override
  void initState() {
    super.initState();
    _searchFocusNode = FocusNode();
    _tabController = TabController(length: _visibleTabs.length, vsync: this)
      ..addListener(_handleTabChange);
    _searchDebounce = Debouncer(const Duration(milliseconds: 250));
  }

  void _handleTabChange() {
    if (_visibleTabs[_tabController.index] != LibraryTab.tracks) {
      _searchFocusNode.unfocus();
    }
    if (mounted) setState(() {});
  }

  Future<void> _manualRescan() async {
    final repo = ref.read(libraryRepositoryProvider);
    if (repo == null) return;
    try {
      await repo.scanAndPersist(reconcileDeletions: true);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Library scan completed.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Library scan failed: $e')));
    }
  }

  @override
  void dispose() {
    _searchDebounce.dispose();
    _searchFocusNode.dispose();
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              theme.colorScheme.primary,
                              theme.colorScheme.secondary,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Icon(
                          Icons.graphic_eq_rounded,
                          color: theme.colorScheme.onPrimary,
                          size: 21,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'V27 PULSE',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2.1,
                        ),
                      ),
                      const Spacer(),
                      IconButton.filledTonal(
                        tooltip: 'Rescan library',
                        visualDensity: VisualDensity.compact,
                        onPressed: _manualRescan,
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                      ),
                      const SizedBox(width: 7),
                      IconButton.filledTonal(
                        tooltip: 'Settings',
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const SettingsScreen(),
                            ),
                          );
                        },
                        icon: const Icon(Icons.tune_rounded, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 19),
                  Text(
                    'Your Library',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.8,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Your music, all in one place.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: isDark
                      ? V27Palette.darkSurface
                      : theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(17),
                  border: Border.all(
                    color: theme.dividerColor.withValues(alpha: 0.65),
                  ),
                ),
                child: TabBar(
                  controller: _tabController,
                  isScrollable: false,
                  dividerColor: Colors.transparent,
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicatorPadding: const EdgeInsets.all(4),
                  indicator: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(
                      alpha: isDark ? 0.22 : 0.12,
                    ),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  labelColor: theme.colorScheme.primary,
                  unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
                  labelStyle: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                  tabs: _visibleTabs
                      .map(
                        (tab) => Tab(
                          height: 58,
                          icon: Icon(tab.icon, size: 19),
                          text: tab.label,
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
            ),
            if (_visibleTabs[_tabController.index] == LibraryTab.tracks)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
                child: TextField(
                  focusNode: _searchFocusNode,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _searchFocusNode.unfocus(),
                  onTapOutside: (_) => _searchFocusNode.unfocus(),
                  maxLength: QueueSpec.maxQueryLength,
                  maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  decoration: InputDecoration(
                    hintText: 'Search your tracks…',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: const Icon(
                      Icons.tune_rounded,
                      size: 19,
                    ),
                    counterText: '',
                    filled: true,
                    fillColor: isDark
                        ? V27Palette.darkSurface
                        : theme.colorScheme.surface,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 15,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(17),
                      borderSide: BorderSide(
                        color: theme.dividerColor.withValues(alpha: 0.7),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(17),
                      borderSide: BorderSide(
                        color: theme.dividerColor.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                  onChanged: (v) {
                    _searchDebounce.call(() {
                      if (!mounted) return;
                      ref.read(searchQueryProvider.notifier).state = v;
                    });
                  },
                ),
              ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: _visibleTabs.map(_pageForTab).toList(growable: false),
              ),
            ),
            const MiniPlayer(),
          ],
        ),
      ),
    );
  }

  Widget _pageForTab(LibraryTab tab) {
    return switch (tab) {
      LibraryTab.tracks => const _TracksTab(),
      LibraryTab.albums => const _GroupedTab(
        groupBy: GroupField.album,
        icon: Icons.album_outlined,
      ),
      LibraryTab.artists => const _GroupedTab(
        groupBy: GroupField.artist,
        icon: Icons.person_outline,
      ),
      LibraryTab.folders => const _GroupedTab(
        groupBy: GroupField.folder,
        icon: Icons.folder_outlined,
      ),
    };
  }
}

/// Flat "Tracks" tab, backed by [tracksPagingProvider] (FIX #1: a
/// bounded-memory windowed pager — see `WindowedPagingNotifier`).
/// `ListView.builder`'s `itemCount` is the query's real total count, so
/// the scrollbar/scroll position stays correct and stable across the
/// whole logical list even though only a bounded window of [Track]
/// objects is ever resident; `itemAt` transparently fetches whatever
/// page a given row's index falls in (in either scroll direction) and
/// returns null for a not-yet-loaded row, which renders a lightweight
/// loading placeholder instead of blocking the frame.
class _TracksTab extends ConsumerStatefulWidget {
  const _TracksTab();

  @override
  ConsumerState<_TracksTab> createState() => _TracksTabState();
}

class _TracksTabState extends ConsumerState<_TracksTab> {
  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(tracksPagingProvider.notifier);
    notifier.ensureCountLoaded();
    final paging = ref.watch(tracksPagingProvider);
    final totalCount = paging.totalCount;

    if (paging.countError != null) {
      return _PagingCountError(onRetry: notifier.retryCount);
    }
    if (totalCount == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final query = ref.watch(searchQueryProvider).trim();
    if (totalCount == 0) {
      return query.isEmpty
          ? const _EmptyLibraryState()
          : _EmptySearchState(query: query);
    }
    final QueueSpec spec = query.isEmpty
        ? const AllTracksQueueSpec()
        : SearchQueueSpec(query);

    return ListView.builder(
      itemCount: totalCount,
      itemBuilder: (context, index) {
        final track = notifier.itemAt(index);
        if (track == null) {
          final error = notifier.pageErrorAt(index);
          if (error != null) {
            return _PagingPageError(
              onRetry: () => notifier.retryPage(index ~/ notifier.pageSize),
            );
          }
          return const _LoadingRow();
        }
        return _TrackTile(
          track: track,
          // FIX #2: the queue this hands off to native describes the
          // COMPLETE logical query (all tracks / this search) plus a
          // logical start index — not just whatever page happens to be
          // loaded in `notifier` right now. Next/Previous work across
          // the full result set; see PlaybackController.playQueue.
          onTap: () => ref
              .read(playbackControllerProvider.notifier)
              .playQueue(
                spec,
                startIndex: index,
                startVolume: track.mediaStoreVolume,
                startMediaStoreId: track.mediaStoreId,
              ),
        );
      },
    );
  }
}

/// Albums / Artists / Folders tab, backed by [groupsPagingProvider]
/// (same bounded-window mechanism as [_TracksTab]): renders group
/// names + track counts. Each group's own tracks are only fetched once
/// the user actually expands it (see [_GroupTile]).
class _GroupedTab extends ConsumerStatefulWidget {
  const _GroupedTab({required this.groupBy, required this.icon});
  final GroupField groupBy;
  final IconData icon;

  @override
  ConsumerState<_GroupedTab> createState() => _GroupedTabState();
}

class _GroupedTabState extends ConsumerState<_GroupedTab> {
  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(groupsPagingProvider(widget.groupBy).notifier);
    notifier.ensureCountLoaded();
    final paging = ref.watch(groupsPagingProvider(widget.groupBy));
    final totalCount = paging.totalCount;

    if (paging.countError != null) {
      return _PagingCountError(onRetry: notifier.retryCount);
    }
    if (totalCount == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (totalCount == 0) {
      return const _EmptyLibraryState();
    }

    return ListView.builder(
      itemCount: totalCount,
      itemBuilder: (context, index) {
        final group = notifier.itemAt(index);
        if (group == null) {
          final error = notifier.pageErrorAt(index);
          if (error != null) {
            return _PagingPageError(
              onRetry: () => notifier.retryPage(index ~/ notifier.pageSize),
            );
          }
          return const _LoadingRow();
        }
        return _GroupTile(
          key: ValueKey('${widget.groupBy.name}:${group.name}'),
          field: widget.groupBy,
          group: group,
          icon: widget.icon,
        );
      },
    );
  }
}

/// One collapsible group row. Its tracks are only requested from Isar
/// (via [groupTracksPagingProvider]) once expanded, and released again
/// once collapsed — see the `autoDispose` note on that provider.
class _GroupTile extends StatefulWidget {
  const _GroupTile({
    super.key,
    required this.field,
    required this.group,
    required this.icon,
  });
  final GroupField field;
  final GroupSummary group;
  final IconData icon;

  @override
  State<_GroupTile> createState() => _GroupTileState();
}

class _GroupTileState extends State<_GroupTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Material(
        color: isDark
            ? V27Palette.darkSurface
            : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(19),
        clipBehavior: Clip.antiAlias,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(19),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.55),
              width: 0.75,
            ),
          ),
          child: Column(
            children: [
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 13,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 49,
                        height: 49,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              theme.colorScheme.primary.withValues(alpha: 0.95),
                              theme.colorScheme.secondary.withValues(alpha: 0.75),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: Icon(
                          widget.icon,
                          color: theme.colorScheme.onPrimary,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.group.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.1,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              widget.group.trackCount == 1
                                  ? '1 track'
                                  : '${widget.group.trackCount} tracks',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: isDark ? 0.18 : 0.09,
                          ),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Text(
                          '${widget.group.trackCount}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 220),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
                          size: 23,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeInOut,
                alignment: Alignment.topCenter,
                child: _expanded
                    ? Column(
                        children: [
                          Divider(
                            height: 1,
                            indent: 14,
                            endIndent: 14,
                            color: theme.dividerColor.withValues(alpha: 0.6),
                          ),
                          _GroupTracksList(
                            groupKey: GroupKey(
                              widget.field,
                              widget.group.name,
                            ),
                            trackCount: widget.group.trackCount,
                          ),
                        ],
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders one expanded group's tracks. Its `itemCount` comes straight
/// from the group's own track count (already known from the parent
/// [_GroupTile]'s [GroupSummary], so no extra count query is needed
/// here), rows are fetched window-by-window the same way as the flat
/// Tracks tab — including for a folder/album with thousands of tracks,
/// which previously would have kept accumulating into one `List<Track>`
/// as it loaded.
class _GroupTracksList extends ConsumerWidget {
  const _GroupTracksList({required this.groupKey, required this.trackCount});
  final GroupKey groupKey;
  final int trackCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(groupTracksPagingProvider(groupKey).notifier);
    ref.watch(groupTracksPagingProvider(groupKey));

    if (trackCount == 0) return const SizedBox.shrink();

    // A nested lazy list is deliberately bounded in height so the parent
    // ExpansionTile never has to build/measure every track in a huge group.
    // Scrolling inside the expanded group remains virtualized and therefore
    // only asks the windowed pager for the rows currently near the viewport.
    final listHeight = (trackCount * 72.0).clamp(72.0, 600.0).toDouble();
    return SizedBox(
      height: listHeight,
      child: ListView.builder(
        primary: false,
        itemCount: trackCount,
        itemExtent: 72,
        itemBuilder: (context, i) {
          final track = notifier.itemAt(i);
          if (track == null) {
            final error = notifier.pageErrorAt(i);
            if (error != null) {
              return _PagingPageError(
                compact: true,
                onRetry: () => notifier.retryPage(i ~/ notifier.pageSize),
              );
            }
            return const _LoadingRow(compact: true);
          }
          return _TrackTile(
            track: track,
            // FIX #2: queue context is this whole group (e.g. the
            // full album), not just the tracks currently resident in
            // `notifier` — Next/Previous walk the complete group.
            onTap: () => ref
                .read(playbackControllerProvider.notifier)
                .playQueue(
                  GroupQueueSpec(groupKey.field, groupKey.name),
                  startIndex: i,
                  startVolume: track.mediaStoreVolume,
                  startMediaStoreId: track.mediaStoreId,
                ),
          );
        },
      ),
    );
  }
}

class _PagingCountError extends StatelessWidget {
  const _PagingCountError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.55),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.cloud_off_rounded,
                  color: theme.colorScheme.primary,
                  size: 27,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Library unavailable',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                'We couldn’t load your library information. Check your storage access and try again.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PagingPageError extends StatelessWidget {
  const _PagingPageError({required this.onRetry, this.compact = false});

  final VoidCallback onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: compact ? 6 : 12,
        horizontal: 12,
      ),
      child: Center(
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 16,
            vertical: compact ? 5 : 9,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.5),
            ),
          ),
          child: TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: const Text('Couldn’t load more · Retry'),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.primary,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingRow extends StatelessWidget {
  const _LoadingRow({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 8 : 20),
      child: Center(
        child: SizedBox(
          width: compact ? 18 : 22,
          height: compact ? 18 : 22,
          child: CircularProgressIndicator(
            strokeWidth: 2.2,
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _TrackTile extends ConsumerWidget {
  const _TrackTile({required this.track, required this.onTap});

  final Track track;
  final VoidCallback onTap;

  String _fmtDuration(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '${h.toString().padLeft(2, '0')}:$m:$sec' : '$m:$sec';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final playback = ref.watch(playbackControllerProvider);
    final isCurrent = playback.currentTrackId == track.mediaStoreId &&
        playback.currentTrackVolume == track.mediaStoreVolume;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: isCurrent
            ? theme.colorScheme.primary.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.13 : 0.07,
              )
            : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(17),
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 9, 5, 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17),
              border: Border.all(
                color: isCurrent
                    ? theme.colorScheme.primary.withValues(alpha: 0.42)
                    : theme.dividerColor.withValues(alpha: 0.45),
                width: isCurrent ? 1.1 : 0.65,
              ),
            ),
            child: Row(
              children: [
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
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
                        size: 52,
                        artSize: 128,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    if (isCurrent)
                      Positioned(
                        right: 3,
                        bottom: 3,
                        child: Container(
                          width: 19,
                          height: 19,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: theme.colorScheme.surface,
                              width: 1.5,
                            ),
                          ),
                          child: Icon(
                            playback.isPlaying
                                ? Icons.graphic_eq_rounded
                                : Icons.pause_rounded,
                            color: theme.colorScheme.onPrimary,
                            size: 12,
                          ),
                        ),
                      ),
                  ],
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
                          color: isCurrent
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${track.artist} • ${track.album}',
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
                const SizedBox(width: 6),
                Text(
                  _fmtDuration(track.durationMs),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFeatures: const [],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Track options',
                  icon: Icon(
                    Icons.more_vert_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  onSelected: (action) {
                    if (action == 'add_to_playlist') {
                      _addTrackToPlaylist(context, ref, track);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'add_to_playlist',
                      child: Row(
                        children: [
                          Icon(Icons.playlist_add_rounded, size: 20),
                          SizedBox(width: 10),
                          Text('Add to playlist'),
                        ],
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

Future<String?> _playlistNamePrompt(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const PlaylistNameDialog(
      title: 'Create playlist',
      submitLabel: 'Create',
    ),
  );
}

Future<void> _addTrackToPlaylist(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
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
          const ListTile(title: Text('Add song to playlist')),
          ...state.playlists.map((playlist) => ListTile(
            leading: const Icon(Icons.queue_music),
            title: Text(playlist.name),
            subtitle: Text('${playlist.songs.length} songs'),
            onTap: () => Navigator.pop(sheetContext, playlist.id),
          )),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Create playlist…'),
            onTap: () => Navigator.pop(sheetContext, createAction),
          ),
        ],
      ),
    ),
  );
  if (selectedId == null || !context.mounted) return;
  var playlistId = selectedId;
  if (selectedId == createAction) {
    final name = await _playlistNamePrompt(context);
    if (name == null || !context.mounted) return;
    final created = await store.createPlaylist(name);
    if (created == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Playlist name is empty or already used.')),
      );
      return;
    }
    playlistId = created.id;
  }
  final added = await store.addTrack(playlistId, track);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(added
          ? 'Added “${track.title}” to playlist.'
          : 'This song is already in that playlist.'),
    ),
  );
}

class _EmptyLibraryState extends StatelessWidget {
  const _EmptyLibraryState();

  @override
  Widget build(BuildContext context) {
    return const _EmptyStateMessage(
      icon: Icons.library_music_rounded,
      title: 'Your library is waiting',
      message:
          'No music found yet. Tap the refresh icon to scan your device, or check your storage permissions.',
    );
  }
}

class _EmptySearchState extends StatelessWidget {
  const _EmptySearchState({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return _EmptyStateMessage(
      icon: Icons.search_off_rounded,
      title: 'No matches found',
      message: 'We couldn’t find anything for “$query”. Try another title, artist, or album.',
    );
  }
}

class _EmptyStateMessage extends StatelessWidget {
  const _EmptyStateMessage({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (constraints.maxHeight - 48).clamp(0.0, double.infinity),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 116,
                    height: 116,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          theme.colorScheme.primary.withValues(alpha: 0.22),
                          theme.colorScheme.secondary.withValues(alpha: 0.10),
                        ],
                      ),
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Icon(
                      icon,
                      size: 52,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 25),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 9),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 290),
                    child: Text(
                      message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.55,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    width: 38,
                    height: 3,
                    decoration: BoxDecoration(
                      color: isDark
                          ? V27Palette.darkBorder
                          : V27Palette.lightBorder,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../../core/debouncer.dart';
import '../../core/widgets/track_artwork.dart';
import '../../data/db/track.dart';
import '../../data/repositories/library_repository.dart';
import '../../playback/queue_spec.dart';
import '../player/mini_player.dart';

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
  late final TabController _tabController;
  late final Debouncer _searchDebounce;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _searchDebounce = Debouncer(const Duration(milliseconds: 250));
  }

  Future<void> _manualRescan() async {
    final repo = ref.read(libraryRepositoryProvider);
    if (repo == null) return;
    try {
      await repo.scanAndPersist(reconcileDeletions: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Library scan completed.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Library scan failed: $e')),
      );
    }
  }

  @override
  void dispose() {
    _searchDebounce.dispose();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rescan library',
            onPressed: _manualRescan,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: false,
          tabs: const [
            Tab(text: 'Tracks'),
            Tab(text: 'Albums'),
            Tab(text: 'Artists'),
            Tab(text: 'Folders'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: TextField(
              maxLength: QueueSpec.maxQueryLength,
              maxLengthEnforcement: MaxLengthEnforcement.enforced,
              decoration: InputDecoration(
                hintText: 'Search tracks…',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
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
              children: const [
                _TracksTab(),
                _GroupedTab(groupBy: GroupField.album, icon: Icons.album_outlined),
                _GroupedTab(groupBy: GroupField.artist, icon: Icons.person_outline),
                _GroupedTab(groupBy: GroupField.folder, icon: Icons.folder_outlined),
              ],
            ),
          ),
          const MiniPlayer(),
        ],
      ),
    );
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
      return _PagingCountError(
        onRetry: notifier.retryCount,
      );
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
    final QueueSpec spec =
        query.isEmpty ? const AllTracksQueueSpec() : SearchQueueSpec(query);

    return ListView.builder(
      itemCount: totalCount,
      itemBuilder: (context, index) {
        final track = notifier.itemAt(index);
        if (track == null) {
          final error = notifier.pageErrorAt(index);
          if (error != null) {
            return _PagingPageError(onRetry: () => notifier.retryPage(index ~/ notifier.pageSize));
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
              .playQueue(spec, startIndex: index, startVolume: track.mediaStoreVolume, startMediaStoreId: track.mediaStoreId),
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
      return _PagingCountError(
        onRetry: notifier.retryCount,
      );
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
            return _PagingPageError(onRetry: () => notifier.retryPage(index ~/ notifier.pageSize));
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
  const _GroupTile({required this.field, required this.group, required this.icon});
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
    return ExpansionTile(
      leading: Icon(widget.icon),
      title: Text(widget.group.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${widget.group.trackCount} tracks'),
      onExpansionChanged: (open) => setState(() => _expanded = open),
      children: _expanded
          ? [
              _GroupTracksList(
                groupKey: GroupKey(widget.field, widget.group.name),
                trackCount: widget.group.trackCount,
              )
            ]
          : const [],
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
                .playQueue(GroupQueueSpec(groupKey.field, groupKey.name),
                    startIndex: i,
                    startVolume: track.mediaStoreVolume,
                    startMediaStoreId: track.mediaStoreId),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Could not load the library count.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
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
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 6 : 12, horizontal: 12),
      child: Center(
        child: TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Retry'),
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
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 8 : 20),
      child: const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return ListTile(
      leading: TrackArtwork(
        contentUri: track.contentUri,
        version: Object.hash(
          track.derivedCacheEpoch,
          track.mediaStoreGenerationModified ?? track.dateModified,
          track.dateModified, track.contentUri, track.relativePath,
          track.displayName, track.durationMs, track.title, track.artist,
          track.album, track.folder,
        ),
        size: 44,
        // Small list-row thumbnails: request a small decode size too, so
        // this doesn't fetch/cache a full-resolution bitmap per row —
        // see TrackArtwork's artSize doc.
        artSize: 128,
        borderRadius: BorderRadius.circular(8),
      ),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${track.artist} • ${track.album}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(_fmtDuration(track.durationMs)),
      onTap: onTap,
    );
  }
}

class _EmptyLibraryState extends StatelessWidget {
  const _EmptyLibraryState();

  @override
  Widget build(BuildContext context) {
    return const _EmptyStateMessage(
      icon: Icons.library_music_outlined,
      message: 'No music found yet.\nTap the refresh icon to scan your device, or check storage permissions.',
    );
  }
}

class _EmptySearchState extends StatelessWidget {
  const _EmptySearchState({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return _EmptyStateMessage(
      icon: Icons.search_off_outlined,
      message: 'No results for “$query”.',
    );
  }
}

class _EmptyStateMessage extends StatelessWidget {
  const _EmptyStateMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 64,
                color: Theme.of(context).colorScheme.primary.withOpacity(0.4)),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

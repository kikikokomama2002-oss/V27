import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar_community.dart';
import 'package:path_provider/path_provider.dart';
import '../data/db/track.dart';
import '../data/repositories/library_repository.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_state.dart';
import '../playback/player_channel.dart';
import 'paging/windowed_paging.dart';

class LibrarySnapshotUnstableException implements Exception {
  const LibrarySnapshotUnstableException();

  @override
  String toString() => 'Library snapshot remained unstable after bounded retries';
}

/// Opens (or reuses) the single Isar instance for the app's local DB.
const _isarDatabaseName = 'offline_music_player';

final isarProvider = FutureProvider<Isar>((ref) async {
  final dir = await getApplicationDocumentsDirectory();
  // Never grab an arbitrary existing Isar instance: another feature/plugin
  // can legally open its own database first. Bind this app to one explicit
  // name so schema/database identity cannot be mixed accidentally.
  final existing = Isar.getInstance(_isarDatabaseName);
  if (existing != null) return existing;
  return Isar.open(
    [TrackSchema],
    directory: dir.path,
    name: _isarDatabaseName,
    inspector: false,
  );
});

final libraryRepositoryProvider = Provider<LibraryRepository?>((ref) {
  final isar = ref.watch(isarProvider).valueOrNull;
  if (isar == null) return null;
  final repo = LibraryRepository(isar);
  ref.onDispose(repo.dispose);
  return repo;
});

final libraryChangesProvider = StreamProvider.autoDispose<void>((ref) {
  final repo = ref.watch(libraryRepositoryProvider);
  if (repo == null) return const Stream<void>.empty();
  return repo.watchTracksChanged();
});

final searchQueryProvider = StateProvider<String>((ref) => '');

/// Page size shared by all paging notifiers below. Small enough that a
/// page fetch (an indexed `offset().limit()` query) stays fast on a
/// low-end device, large enough that scrolling doesn't trigger a fetch
/// every couple of rows.
const _pageSize = 60;

/// Hard cap on resident pages per feed — see
/// `WindowedPagingNotifier`/FIX #1. `_pageSize * _maxPagesInMemory`
/// (360 tracks / group summaries) is the actual memory ceiling for
/// each of these feeds, however large the underlying library is or
/// however far the user scrolls.
const _maxPagesInMemory = 6;

/// FIX #1 — BOUNDED MEMORY FOR INFINITE SCROLL.
///
/// Drives the flat "Tracks" tab and the search field: loads the
/// library (or the current search's matches) as a bounded-memory
/// window of pages via [LibraryRepository.tracksPage] /
/// [LibraryRepository.searchPage] — never accumulating previously
/// loaded pages into one ever-growing `List<Track>` the way
/// `items: [...state.items, ...page]` used to. At most
/// `_pageSize * _maxPagesInMemory` [Track] objects are ever resident,
/// regardless of library size or how deep the user has scrolled — see
/// `WindowedPagingNotifier._evict`.
///
/// Resets (drops every loaded page, re-fetches the total count) when
/// the search query changes or the DB changes underneath it (e.g.
/// after a rescan) — the previous "how far has the user loaded"
/// bookkeeping doesn't necessarily still make sense against a
/// different query or a changed row count.
class TracksPagingNotifier extends WindowedPagingNotifier<Track> {
  TracksPagingNotifier(this._ref)
      : super(pageSize: _pageSize, maxPagesInMemory: _maxPagesInMemory) {
    _ref.listen<String>(
      searchQueryProvider,
      (_, next) => _onQueryChanged(next.trim()),
    );
    // libraryRepositoryProvider depends on isarProvider's async open, so
    // it's null on the very first build — watch for it becoming
    // available (rather than reading it once) so the first page still
    // loads once the DB finishes opening.
    _ref.listen<LibraryRepository?>(
      libraryRepositoryProvider,
      _onRepoAvailable,
      fireImmediately: true,
    );
  }

  final Ref _ref;
  String _query = '';
  StreamSubscription<void>? _dbSub;

  LibraryRepository? get _repo => _ref.read(libraryRepositoryProvider);


  @override
  int? get currentSnapshotGeneration => _repo?.libraryGeneration;

  void _onRepoAvailable(LibraryRepository? previous, LibraryRepository? next) {
    if (next == null || previous != null) return;
    _dbSub = next.watchTracksChanged().listen((_) => _onDbChanged());
    ensureCountLoaded();
  }

  void _onQueryChanged(String query) {
    if (query == _query) return;
    _query = query;
    reset();
    ensureCountLoaded();
  }

  void _onDbChanged() {
    reset();
    ensureCountLoaded();
  }

  @override
  Future<List<Track>> fetchPage({required int offset, required int limit}) async {
    final repo = _repo;
    if (repo == null) return const [];
    for (var attempt = 0; attempt < 3; attempt++) {
      final generation = await repo.waitForStableSnapshot();
      final page = _query.isEmpty
          ? await repo.tracksPage(offset: offset, limit: limit)
          : await repo.searchPage(_query, offset: offset, limit: limit);
      if (generation == repo.libraryGeneration && !repo.scanInProgress) {
        return page;
      }
    }
    throw const LibrarySnapshotUnstableException();
  }

  @override
  Future<int> fetchCount() async {
    final repo = _repo;
    if (repo == null) return 0;
    for (var attempt = 0; attempt < 3; attempt++) {
      final generation = await repo.waitForStableSnapshot();
      final count = _query.isEmpty ? await repo.tracksCount() : await repo.searchCount(_query);
      if (generation == repo.libraryGeneration && !repo.scanInProgress) {
        return count;
      }
    }
    throw const LibrarySnapshotUnstableException();
  }

  @override
  void dispose() {
    _dbSub?.cancel();
    super.dispose();
  }
}

final tracksPagingProvider =
    StateNotifierProvider<TracksPagingNotifier, WindowedPagingState<Track>>(
  (ref) => TracksPagingNotifier(ref),
);

/// Drives each of the Albums/Artists/Folders tabs.
///
/// FIX #5 — BOUNDED MEMORY FOR GROUP NAME PAGING.
///
/// Previously this cached the FULL distinct name list for [field] in a
/// single `List<String>? _allNames` field the first time any page was
/// requested, and every subsequent page was just a Dart-side
/// `sublist()` of that one cached list. That list was never re-queried
/// per page, so for a library with an unusually large number of
/// distinct albums/artists/folders, `_allNames` itself became an
/// unbounded-with-library-size cache — exactly the same class of
/// problem [TracksPagingNotifier] already solves for [Track] rows, just
/// left unsolved for group names.
///
/// Now every page is fetched straight from Isar via
/// [LibraryRepository.distinctGroupNamesPage] (an indexed, offset/limit
/// sorted-distinct query — see that method's docs) and the total count
/// via [LibraryRepository.distinctGroupNamesCount] (an indexed
/// `count()`), the same way [TracksPagingNotifier] fetches [Track]
/// pages. There is no per-notifier "all names" cache of any kind: the
/// only names ever resident are whatever pages
/// `WindowedPagingNotifier`'s own bounded-window/eviction logic (see
/// `core/paging/windowed_paging.dart`) is currently holding — at most
/// `_pageSize * _maxPagesInMemory` names, regardless of how many
/// distinct groups the library actually has. Scrolling back to an
/// evicted page simply re-queries Isar for that page, exactly like
/// scrolling back in the flat Tracks tab already does.
class GroupsPagingNotifier extends WindowedPagingNotifier<GroupSummary> {
  GroupsPagingNotifier(this._ref, this.field)
      : super(pageSize: _pageSize, maxPagesInMemory: _maxPagesInMemory) {
    // Same "wait for the DB to actually be open" reasoning as
    // TracksPagingNotifier above.
    _ref.listen<LibraryRepository?>(
      libraryRepositoryProvider,
      _onRepoAvailable,
      fireImmediately: true,
    );
  }

  final Ref _ref;
  final GroupField field;
  StreamSubscription<void>? _dbSub;

  LibraryRepository? get _repo => _ref.read(libraryRepositoryProvider);

  @override
  int? get currentSnapshotGeneration => _repo?.libraryGeneration;

  void _onRepoAvailable(LibraryRepository? previous, LibraryRepository? next) {
    if (next == null || previous != null) return;
    _dbSub = next.watchTracksChanged().listen((_) => _onDbChanged());
    ensureCountLoaded();
  }

  void _onDbChanged() {
    reset();
    ensureCountLoaded();
  }

  @override
  Future<int> fetchCount() async {
    final repo = _repo;
    if (repo == null) return 0;
    for (var attempt = 0; attempt < 3; attempt++) {
      final generation = await repo.waitForStableSnapshot();
      final count = await repo.distinctGroupNamesCount(field);
      if (generation == repo.libraryGeneration && !repo.scanInProgress) {
        return count;
      }
    }
    throw const LibrarySnapshotUnstableException();
  }

  @override
  Future<List<GroupSummary>> fetchPage({
    required int offset,
    required int limit,
  }) async {
    final repo = _repo;
    if (repo == null) return const [];
    // Queried page-by-page straight from Isar — no cached "all names"
    // list backs this call (see class doc above).
    // Names and counts are separate Isar queries. Under active library
    // mutation, an item can disappear or move between pages between those
    // reads. Retry until the ordered name span and its counts are stable;
    // otherwise return only after the final bounded attempt rather than
    // presenting a known name/count mismatch.
    for (var attempt = 0; attempt < 3; attempt++) {
      final snapshotGeneration = await repo.waitForStableSnapshot();
      final pageNames = await repo.distinctGroupNamesPage(
        field,
        offset: offset,
        limit: limit,
      );
      if (pageNames.isEmpty) {
        // Empty is still a query result and must cross the same snapshot gate
        // as a non-empty page. A scan can start after the empty query returns
        // but before the notifier publishes it; never let that stale empty
        // page clear a newer generation.
        if (snapshotGeneration == repo.libraryGeneration && !repo.scanInProgress) {
          return const [];
        }
        continue;
      }
      final counts = await repo.countsForGroups(field, pageNames);
      final verifyNames = await repo.distinctGroupNamesPage(
        field,
        offset: offset,
        limit: limit,
      );
      final namesStable = pageNames.length == verifyNames.length &&
          pageNames.asMap().entries.every(
            (entry) => entry.value == verifyNames[entry.key],
          );
      if (!namesStable && attempt < 2) continue;

      final verifyCounts = await repo.countsForGroups(field, verifyNames);
      final countsStable = counts.length == verifyCounts.length &&
          counts.keys.every((name) => counts[name] == verifyCounts[name]);
      // A bounded retry is a correctness gate, not permission to publish a
      // best-effort mixture. If the final verification is still unstable,
      // fail the page fetch so WindowedPagingNotifier can surface/retry the
      // transient error instead of presenting names from one snapshot with
      // counts from another.
      if (!namesStable || !countsStable ||
          snapshotGeneration != repo.libraryGeneration ||
          repo.scanInProgress) {
        continue;
      }

      return [
        for (final name in pageNames)
          GroupSummary(
            name,
            counts[name] ?? 0,
            displayName: field == GroupField.folder ? _folderDisplayName(name) : name,
          ),
      ];
    }
    throw StateError('GROUP_PAGE_UNSTABLE');
  }

  @override
  void dispose() {
    _dbSub?.cancel();
    super.dispose();
  }
}

String _folderDisplayName(String key) {
  final separator = key.indexOf('::');
  return separator >= 0 ? key.substring(separator + 2) : key;
}

final groupsPagingProvider = StateNotifierProvider.family<GroupsPagingNotifier,
    WindowedPagingState<GroupSummary>, GroupField>(
  (ref, field) => GroupsPagingNotifier(ref, field),
);

/// Identifies one expanded group's track list, e.g. (album, "Abbey Road").
class GroupKey {
  const GroupKey(this.field, this.name);
  final GroupField field;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is GroupKey && other.field == field && other.name == name;

  @override
  int get hashCode => Object.hash(field, name);
}

/// Drives one expanded group's track list. `autoDispose` so collapsing
/// the tile (which unmounts its child list widget) frees every loaded
/// page immediately instead of keeping every group a user has ever
/// expanded resident in memory for the lifetime of the app — on top of
/// the bounded-window cap this already gets from
/// [WindowedPagingNotifier] while the tile is expanded.
class GroupTracksPagingNotifier extends WindowedPagingNotifier<Track> {
  GroupTracksPagingNotifier(this._ref, this.key)
      : super(pageSize: _pageSize, maxPagesInMemory: _maxPagesInMemory) {
    _ref.listen<LibraryRepository?>(
      libraryRepositoryProvider,
      (previous, next) {
        if (next == null || previous != null) return;
        _dbChangesSub?.cancel();
        _dbChangesSub = next.watchTracksChanged().listen((_) {
          reset();
          ensureCountLoaded();
        });
        ensureCountLoaded();
      },
      fireImmediately: true,
    );
  }

  final Ref _ref;
  final GroupKey key;
  StreamSubscription<void>? _dbChangesSub;

  LibraryRepository? get _repo => _ref.read(libraryRepositoryProvider);


  @override
  int? get currentSnapshotGeneration => _repo?.libraryGeneration;

  @override
  Future<int> fetchCount() async {
    final repo = _repo;
    if (repo == null) return 0;
    for (var attempt = 0; attempt < 3; attempt++) {
      final generation = await repo.waitForStableSnapshot();
      final count = await repo.countForGroup(key.field, key.name);
      if (generation == repo.libraryGeneration && !repo.scanInProgress) {
        return count;
      }
    }
    throw const LibrarySnapshotUnstableException();
  }

  @override
  Future<List<Track>> fetchPage({required int offset, required int limit}) async {
    final repo = _repo;
    if (repo == null) return const [];
    for (var attempt = 0; attempt < 3; attempt++) {
      final generation = await repo.waitForStableSnapshot();
      final page = await repo.tracksForGroupPage(
        key.field,
        key.name,
        offset: offset,
        limit: limit,
      );
      if (generation == repo.libraryGeneration && !repo.scanInProgress) {
        return page;
      }
    }
    throw const LibrarySnapshotUnstableException();
  }

  @override
  void dispose() {
    _dbChangesSub?.cancel();
    super.dispose();
  }
}

final groupTracksPagingProvider = StateNotifierProvider.autoDispose
    .family<GroupTracksPagingNotifier, WindowedPagingState<Track>, GroupKey>(
  (ref, key) => GroupTracksPagingNotifier(ref, key),
);

/// Drives the mini-player / now-playing screen: current queue, current
/// track, and live playback state from the native side.
final playbackControllerProvider =
    StateNotifierProvider<PlaybackController, PlaybackState>((ref) {
  return PlaybackController(ref);
});

/// The [Track] object currently loaded in the player, resolved from the
/// id the native side reports via a single indexed point lookup
/// (`LibraryRepository.trackByMediaStoreId`) — not by scanning an
/// in-memory list of every track for a match, which no longer exists
/// now that the library is paginated.
final _currentTrackFutureProvider = FutureProvider.autoDispose<Track?>((ref) async {
  // Metadata/artwork for the same MediaStore identity can change without the
  // identity itself changing. Subscribe to the DB invalidation stream so the
  // current-track object is re-read after a scan.
  ref.watch(libraryChangesProvider);
  final identity = ref.watch(
    playbackControllerProvider.select(
      (state) => (state.currentTrackVolume, state.currentTrackId),
    ),
  );
  final volume = identity.$1;
  final trackId = identity.$2;
  if (volume == null || trackId == null) return null;
  final repo = ref.watch(libraryRepositoryProvider);
  if (repo == null) return null;
  return repo.trackByMediaStoreIdentity(volume, trackId);
});

final currentTrackProvider = Provider.autoDispose<Track?>((ref) {
  return ref.watch(_currentTrackFutureProvider).valueOrNull;
});

/// Embedded album artwork for a track, fetched via the native thumbnail
/// pipeline. Null means "no embedded artwork" — callers show a
/// placeholder in that case, not a broken image.
///
/// `.autoDispose`: on a large library, `ListView.builder` constantly
/// mounts/unmounts `TrackArtwork` widgets as the user scrolls, each
/// watching this family keyed by (contentUri, size). Without
/// `autoDispose`, Riverpod keeps every distinct key's decoded bytes
/// cached for the lifetime of the app — for a multi-thousand-track
/// library that's an unbounded, ever-growing in-memory image cache.
/// `autoDispose` releases a track's cached artwork as soon as nothing
/// is watching it (i.e. its row scrolls out of view and is disposed),
/// keeping memory bounded to roughly what's currently on screen instead
/// of the whole library. `TrackArtwork.dispose()` additionally tells
/// the native side to cancel the in-flight request outright (FIX #4)
/// rather than just letting the eventual result be discarded.
final albumArtProvider = FutureProvider.autoDispose
    .family<Uint8List?, ({String contentUri, int size, int version})>((ref, key) {
  final channel = PlayerChannel.instance;
  final requestId = channel.newAlbumArtRequestId();

  // The request id identifies this exact Riverpod consumer. Disposing this
  // provider releases only this consumer's interest; native deduplication
  // keeps the shared operation alive for any other active consumers.
  var disposed = false;
  ref.onDispose(() {
    disposed = true;
    channel.cancelAlbumArt(
      key.contentUri,
      size: key.size,
      requestId: requestId,
      version: key.version,
    );
  });

  Future<Uint8List?> loadWithAdmissionRetry() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      if (disposed) return null;
      try {
        return await channel.getAlbumArt(
          key.contentUri,
          size: key.size,
          requestId: requestId,
          version: key.version,
        );
      } on PlatformException catch (e) {
        if (e.code != 'ARTWORK_RESOURCE_BUSY' &&
            e.code != 'ARTWORK_PROVIDER_UNAVAILABLE') {
          rethrow;
        }
        if (attempt == 3) rethrow;
        if (disposed) return null;
        await Future<void>.delayed(Duration(milliseconds: e.code == 'ARTWORK_RESOURCE_BUSY' ? 75 : 150));
        if (disposed) return null;
      }
    }
    return null;
  }

  return loadWithAdmissionRetry();
});


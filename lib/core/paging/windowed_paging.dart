import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// FIX #1 — BOUNDED MEMORY FOR INFINITE SCROLL.
///
/// Immutable snapshot of a [WindowedPagingNotifier]'s state: which
/// pages of [T] are currently resident in memory, the full logical
/// item count (needed for `ListView.builder`'s `itemCount` and stable
/// scrollbar behavior), and which pages are mid-fetch.
///
/// [pages] deliberately never grows without bound — see
/// [WindowedPagingNotifier._evictIfNeeded]. This replaces the previous
/// pattern of `items: [...state.items, ...page]`, which kept every
/// previously loaded [T] resident for the lifetime of the provider.
class WindowedPagingState<T> {
  const WindowedPagingState({
    this.pages = const {},
    this.totalCount,
    this.loadingPages = const {},
    this.pageErrors = const {},
    this.countError,
    this.snapshotGeneration,
  });

  /// pageIndex -> loaded items for that page. Bounded to at most
  /// `maxPagesInMemory` entries by the owning notifier.
  final Map<int, List<T>> pages;

  /// Total logical item count for the current query, or null until the
  /// first count query resolves.
  final int? totalCount;

  final Set<int> loadingPages;

  /// Page-indexed fetch failures. A failed page is not automatically retried
  /// from every rebuild; callers can explicitly retry the affected page.
  final Map<int, Object> pageErrors;

  /// Non-null when the total-count query failed. Keeping this separate
  /// from [totalCount] lets the UI offer an explicit retry instead of
  /// remaining on an indefinite spinner.
  final Object? countError;

  /// Repository generation shared by all currently published count/page
  /// results. A change here invalidates the whole paging state instead of
  /// allowing count and pages from different library snapshots to coexist.
  final int? snapshotGeneration;

  /// Approximate current memory footprint, in resident items — for
  /// diagnostics/tests, not used by the UI.
  int get residentItemCount =>
      pages.values.fold(0, (sum, page) => sum + page.length);

  WindowedPagingState<T> copyWith({
    Map<int, List<T>>? pages,
    int? totalCount,
    bool clearTotalCount = false,
    Set<int>? loadingPages,
    Map<int, Object>? pageErrors,
    Object? countError,
    bool clearCountError = false,
    int? snapshotGeneration,
    bool clearSnapshotGeneration = false,
  }) {
    return WindowedPagingState<T>(
      pages: pages ?? this.pages,
      totalCount: clearTotalCount ? null : (totalCount ?? this.totalCount),
      loadingPages: loadingPages ?? this.loadingPages,
      pageErrors: pageErrors ?? this.pageErrors,
      countError: clearCountError ? null : (countError ?? this.countError),
      snapshotGeneration: clearSnapshotGeneration
          ? null
          : (snapshotGeneration ?? this.snapshotGeneration),
    );
  }
}

/// Drives a single "give me item N of a big logical list" feed with a
/// genuinely bounded memory footprint: at most `maxPagesInMemory *
/// pageSize` items of [T] are ever resident at once, regardless of how
/// far the user scrolls (or how large the underlying query is — a
/// 10,000-track library costs the same RAM here as a 100-track one).
///
/// Backs the flat Tracks tab, search results, group (album/artist/
/// folder) name lists, and an individual expanded group's tracks (see
/// `core/providers.dart`) — anywhere the old code accumulated pages
/// into one ever-growing `List<T>`.
///
/// USAGE: a `ListView.builder` sets `itemCount: notifier.state.totalCount
/// ?? 0` and, in `itemBuilder`, calls `itemAt(index)` — which returns
/// the item if its page is already loaded, or schedules a fetch for
/// that page (and returns null, so the caller shows a loading
/// placeholder for that row) if not. This works for scrolling in
/// EITHER direction: an index whose page was evicted after the user
/// scrolled far past it is simply re-fetched if they scroll back.
abstract class WindowedPagingNotifier<T> extends StateNotifier<WindowedPagingState<T>> {
  WindowedPagingNotifier({
    this.pageSize = 60,
    this.maxPagesInMemory = 6,
  }) : super(WindowedPagingState<T>());

  /// Fetches one page of [T] — an indexed `offset().limit()` DB query,
  /// implemented by the subclass for whatever query this feed
  /// represents (all tracks, a search, one group's tracks, ...).
  Future<List<T>> fetchPage({required int offset, required int limit});

  /// Fetches the total logical item count for the current query.
  Future<int> fetchCount();

  /// Concrete repositories may expose the generation used by their most
  /// recently completed fetch. This lets the base notifier reject a page or
  /// count that belongs to a different repository snapshot.
  int? get lastFetchSnapshotGeneration => null;

  /// Current repository snapshot generation. A fetch result is publishable
  /// only while this still equals the generation captured by that fetch.
  /// This final synchronous gate closes the gap between a fetch completing
  /// and the paging notifier receiving the repository change stream.
  int? get currentSnapshotGeneration => null;

  /// Rows per page — an `offset().limit()` DB query, not an in-memory
  /// slice.
  final int pageSize;

  /// Hard cap on how many pages may be resident at once. E.g. pageSize
  /// 60 * maxPagesInMemory 6 = at most 360 [T] objects in memory no
  /// matter how large the query's logical result set is or how far the
  /// user has scrolled.
  final int maxPagesInMemory;

  bool _disposed = false;
  int _lastRequestedPage = 0;
  bool _countInFlight = false;
  int _nextCountRequestId = 0;
  int? _activeCountRequestId;

  /// Bumped by [reset]. Captured by [_requestPage]/[ensureCountLoaded]
  /// at the moment each fetch starts; if it no longer matches
  /// [_generation] when that fetch resolves, a [reset] happened in the
  /// meantime and this result belongs to a query that's no longer
  /// current — see the "stale group/page results" edge case in
  /// `GroupsPagingNotifier`/`TracksPagingNotifier` doc comments. Without
  /// this, an older in-flight page fetch (e.g. request A) that resolves
  /// AFTER a newer [reset] (triggered by e.g. a DB rescan or a changed
  /// search query, possibly itself followed by a newer page request B)
  /// would still land in `state.pages` via `Map.from(state.pages)`,
  /// silently reintroducing page data for a dataset/query that's no
  /// longer the current one.
  int _generation = 0;
  final Map<int, Future<void>> _pageInFlight = {};
  final Map<int, int> _pageInFlightGeneration = {};
  // Pages admitted here are scheduled but have not yet entered _requestPage.
  // Admission happens synchronously before creating a microtask, so a burst
  // of itemAt() calls cannot enqueue an unbounded scheduler backlog.
  final Set<int> _scheduledPageRequests = {};
  static const int _maxConcurrentPageFetches = 4;
  // Admission bounds physical concurrency, while this bound prevents a
  // pathological scroll/programmatic request burst from accumulating an
  // unbounded queue of distinct page futures behind the four workers.
  static const int _maxPendingPageRequests = 4;
  final List<Future<void>> _pageAdmissionTails = [
    Future<void>.value(),
    Future<void>.value(),
    Future<void>.value(),
    Future<void>.value(),
  ];
  int _nextPageAdmissionSlot = 0;

  /// Kicks off the total-count query if it hasn't resolved yet. Safe to
  /// call repeatedly (e.g. once per build) — it's a no-op once
  /// `state.totalCount` is set or a count fetch is already in flight.
  void ensureCountLoaded() {
    if (state.totalCount != null || _countInFlight || state.countError != null) {
      return;
    }
    _countInFlight = true;
    final requestGeneration = _generation;
    final requestSnapshotGeneration = currentSnapshotGeneration;
    final requestId = ++_nextCountRequestId;
    _activeCountRequestId = requestId;

    fetchCount().then((count) {
      // Only the request that currently owns `_countInFlight` may clear it
      // or publish a result. A reset invalidates the generation, but it
      // does not cancel an Isar Future that is already running. Keeping the
      // in-flight flag set until that Future completes prevents a reset from
      // starting a duplicate count against the same old query.
      if (_activeCountRequestId != requestId) return;
      _countInFlight = false;

      if (_disposed) return;
      if (requestGeneration != _generation) {
        // The old count finished after reset. It cannot update state, but
        // now that it has released the in-flight slot the current query can
        // safely start exactly one fresh count.
        ensureCountLoaded();
        return;
      }

      final currentGeneration = currentSnapshotGeneration;
      if (requestSnapshotGeneration != null &&
          currentGeneration != null &&
          requestSnapshotGeneration != currentGeneration) {
        reset();
        ensureCountLoaded();
        return;
      }
      if (requestSnapshotGeneration != null &&
          state.snapshotGeneration != null &&
          state.snapshotGeneration != requestSnapshotGeneration) {
        reset();
        ensureCountLoaded();
        return;
      }
      state = state.copyWith(
        totalCount: count,
        clearCountError: true,
        snapshotGeneration: requestSnapshotGeneration,
      );
    }).then<void>((_) {}, onError: (Object error, StackTrace stack) {
      if (_activeCountRequestId != requestId) return;
      _countInFlight = false;

      if (_disposed) return;
      if (requestGeneration != _generation) {
        ensureCountLoaded();
        return;
      }

      state = state.copyWith(countError: error);
    });
  }

  /// Retries a failed count query exactly when the UI/user asks for it.
  /// A failed request therefore cannot create a rebuild-driven infinite
  /// retry loop.
  void retryCount() {
    if (_disposed || _countInFlight) return;
    state = state.copyWith(clearCountError: true);
    ensureCountLoaded();
  }

  /// Returns the item at global logical [index] if its page is already
  /// loaded in memory. If not, schedules a fetch for that page (unless
  /// one is already in flight) and returns null — callers render a
  /// lightweight loading placeholder for that row in the meantime, per
  /// FIX #1's "maintain lightweight positional/page metadata instead of
  /// full [T] objects" for not-yet-loaded rows.
  T? itemAt(int index) {
    if (index < 0) return null;
    final pageIndex = index ~/ pageSize;
    final loadedPage = state.pages[pageIndex];
    if (loadedPage != null) {
      final withinPage = index % pageSize;
      return withinPage < loadedPage.length ? loadedPage[withinPage] : null;
    }
    // A failed page requires an explicit retry. This prevents a rebuild of
    // a placeholder row from becoming an unbounded request/failure loop.
    if (state.pageErrors.containsKey(pageIndex)) return null;
    // Defer the actual state mutation to a microtask rather than
    // mutating provider state synchronously inside itemBuilder (i.e.
    // during another widget's build) — this runs once the current
    // frame's build pass has returned.
    // Admit synchronously, before scheduling. The admission set is bounded
    // by the same global pending-work limit used by _requestPage().
    if (_scheduledPageRequests.length >= _maxPendingPageRequests) {
      return null;
    }
    if (!_scheduledPageRequests.add(pageIndex)) {
      return null;
    }
    Future.microtask(() {
      _scheduledPageRequests.remove(pageIndex);
      return _requestPage(pageIndex);
    });
    return null;
  }

  Future<void> _requestPage(int pageIndex) {
    if (_disposed) return Future.value();
    final existing = _pageInFlight[pageIndex];
    final existingGeneration = _pageInFlightGeneration[pageIndex];
    if (existing != null && existingGeneration == _generation) return existing;

    if (state.pages.containsKey(pageIndex) || state.pageErrors.containsKey(pageIndex)) {
      return Future.value();
    }
    // Stale requests from older generations cannot publish their results and
    // must not consume the admission budget of the current query. The actual
    // Isar futures remain physically in flight because they are not
    // cancellable, but they are no longer logical work for this generation.
    final currentGenerationPending = _pageInFlightGeneration.values
        .where((generation) => generation == _generation)
        .length;
    if (currentGenerationPending >= _maxPendingPageRequests) {
      // Do not enqueue more current-generation work. The caller can retry when
      // an existing current-generation request completes; stale generations
      // do not block admission.
      return Future.value();
    }

    // A reset invalidates publication of the old request, but the physical
    // Isar Future cannot be cancelled. Chain the new-generation request after
    // the old one instead of returning the stale Future (which could leave
    // the new generation permanently unloaded) or starting duplicate DB work.
    final predecessor = existing;
    late final Future<void> request;
    final start = predecessor == null
        ? Future<void>.value()
        : predecessor.catchError((_) {});
    request = start.then<void>((_) => _requestPageInternal(pageIndex)).whenComplete(() {
      if (identical(_pageInFlight[pageIndex], request)) {
        _pageInFlight.remove(pageIndex);
        _pageInFlightGeneration.remove(pageIndex);
      }
    });
    _pageInFlight[pageIndex] = request;
    _pageInFlightGeneration[pageIndex] = _generation;
    return request;
  }

  Future<void> _requestPageInternal(int pageIndex) async {
    // Captured before the await below — see [_generation] doc. A
    // [reset] that happens while this fetch is in flight bumps
    // [_generation], and the staleness checks below then make sure this
    // (now-obsolete) fetch's result is dropped instead of overwriting
    // whatever newer request/state replaced it.
    final requestGeneration = _generation;
    final requestSnapshotGeneration = currentSnapshotGeneration;
    _lastRequestedPage = pageIndex;
    state = state.copyWith(loadingPages: {...state.loadingPages, pageIndex});

    // Four independent admission chains provide a hard global concurrency
    // ceiling. A slot remains occupied until this request finishes.
    final slot = _nextPageAdmissionSlot++ % _maxConcurrentPageFetches;
    final predecessor = _pageAdmissionTails[slot];
    await predecessor.catchError((_) {});
    if (_disposed || requestGeneration != _generation) return;
    final release = Completer<void>();
    _pageAdmissionTails[slot] = release.future;
    List<T> items;
    try {
      items = await fetchPage(offset: pageIndex * pageSize, limit: pageSize);
      if (items.length > pageSize) {
        throw StateError('Paging source returned more than pageSize items');
      }
    } catch (error) {
      if (!release.isCompleted) release.complete();
      if (_disposed || requestGeneration != _generation) return;
      final errors = Map<int, Object>.from(state.pageErrors)..[pageIndex] = error;
      _evictErrors(errors);
      state = state.copyWith(
        loadingPages: {...state.loadingPages}..remove(pageIndex),
        pageErrors: errors,
      );
      return;
    }
    if (!release.isCompleted) release.complete();
    if (_disposed || requestGeneration != _generation) return;

    final fetchGeneration = requestSnapshotGeneration;
    final currentGeneration = currentSnapshotGeneration;
    if (fetchGeneration != null &&
        currentGeneration != null &&
        fetchGeneration != currentGeneration) {
      reset();
      ensureCountLoaded();
      return;
    }
    if (fetchGeneration != null &&
        state.snapshotGeneration != null &&
        state.snapshotGeneration != fetchGeneration) {
      reset();
      ensureCountLoaded();
      return;
    }

    final newPages = Map<int, List<T>>.from(state.pages)..[pageIndex] = items;
    _evict(newPages);
    final newLoading = {...state.loadingPages}..remove(pageIndex);
    final newErrors = Map<int, Object>.from(state.pageErrors)..remove(pageIndex);
    _evictErrors(newErrors);
    state = state.copyWith(
      pages: newPages,
      loadingPages: newLoading,
      snapshotGeneration: fetchGeneration ?? state.snapshotGeneration,
      pageErrors: newErrors,
    );
  }

  /// Evicts loaded pages, farthest-from-`_lastRequestedPage` first,
  /// until at most [maxPagesInMemory] remain — the actual bound on
  /// memory usage. "Farthest from the last requested page" (rather
  /// than e.g. strict LRU) keeps whatever the user is currently
  /// scrolled near resident even if they briefly jumped elsewhere and
  /// back.
  void _evict(Map<int, List<T>> pages) {
    while (pages.length > maxPagesInMemory) {
      int? farthest;
      int farthestDist = -1;
      for (final p in pages.keys) {
        final dist = (p - _lastRequestedPage).abs();
        if (dist > farthestDist) {
          farthestDist = dist;
          farthest = p;
        }
      }
      if (farthest == null) break;
      pages.remove(farthest);
    }
  }

  /// Keeps failure metadata bounded just like loaded pages.
  void _evictErrors(Map<int, Object> errors) {
    while (errors.length > maxPagesInMemory) {
      int? farthest;
      int farthestDist = -1;
      for (final p in errors.keys) {
        final dist = (p - _lastRequestedPage).abs();
        if (dist > farthestDist) { farthestDist = dist; farthest = p; }
      }
      if (farthest == null) break;
      errors.remove(farthest);
    }
  }

  /// Returns the failure recorded for the page containing [index], if any.
  Object? pageErrorAt(int index) => state.pageErrors[index ~/ pageSize];

  /// Explicitly retries one failed page after the caller has surfaced the
  /// error to the user (or otherwise decided a retry is appropriate).
  void retryPage(int pageIndex) {
    if (_disposed || pageIndex < 0 || state.loadingPages.contains(pageIndex)) return;
    final errors = Map<int, Object>.from(state.pageErrors)..remove(pageIndex);
    state = state.copyWith(pageErrors: errors);
    unawaited(_requestPage(pageIndex));
  }

  /// Drops every loaded page and the cached total count — call when
  /// the underlying query changes (e.g. new search text) or the DB
  /// changed underneath it (e.g. after a rescan).
  void reset() {
    _generation++;
    _lastRequestedPage = 0;
    // Do not clear `_countInFlight` here. An Isar Future already in flight
    // cannot be safely interrupted. Let its owner release the flag when it
    // completes; its generation check will prevent the stale result from
    // entering the new state, and it will then trigger the new generation's
    // count exactly once.
    state = WindowedPagingState<T>();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

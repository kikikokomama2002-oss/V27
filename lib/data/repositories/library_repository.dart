import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../playback/player_channel.dart';
import '../db/track.dart';

const _legacyLastScanMsKey = 'last_scan_timestamp_ms';
const _lastScanKey = 'last_scan_timestamp_seconds_v1';
const _volumeIdentityMigrationKey = 'volume_identity_migration_v1';
const _knownMediaStoreVolumesKey = 'known_media_store_volumes_v1';
const _lastPresentMediaStoreVolumesKey = 'last_present_media_store_volumes_v1';
const _mediaStoreVolumeStatesKey = 'media_store_volume_states_v1';
const _mediaStoreGenerationCursorsKey = 'media_store_generation_cursors_v1';
const _syncInProgressKey = 'library_sync_in_progress_v1';
const _lastDeletionReconciliationKey = 'last_deletion_reconciliation_timestamp_ms_v1';
const _deletionObservationBaselineEpochKey =
    'deletion_observation_baseline_epoch_v1';

/// Maximum time a missed MediaStore observer deletion may remain uncorrected
/// while the process stays alive. Ordinary scans remain incremental until this
/// durable deadline is reached; the first successful recovery persists a new
/// deadline so process restarts do not create an O(N) startup scan.
const _deletionReconciliationCheckInterval = Duration(minutes: 15);
const _deletionReconciliationInterval = Duration(hours: 6);

/// Safety overlap applied to the incremental scan cursor so a track
/// modified in the same second as the last scan (MediaStore's
/// DATE_MODIFIED has 1-second resolution) is never skipped.
const _scanOverlapSeconds = 2;

/// Maximum number of local MediaStore IDs compared with Android in one
/// deletion-sync batch. The native query uses the same bounded batch, so
/// neither side scales in memory with the full library size.
const _deletionSyncChunkSize = 500;


/// Which grouping tab a query is for. Each case maps to a real indexed
/// column on [Track] (`album`, `artist`, `folder`), so grouping never
/// falls back to scanning/deserializing every row.
enum GroupField { album, artist, folder }

/// A group's display name and track count, resolved entirely at the DB
/// layer (distinct index scan + indexed `count()`) — never by loading
/// every [Track] in the group into memory just to read `.length`.
class GroupSummary {
  const GroupSummary(this.name, this.trackCount, {String? displayName})
      : displayName = displayName ?? name;
  /// Stable DB/query key. For folders this remains volume-qualified.
  final String name;
  /// Human-facing label; keeps the storage-volume prefix out of the UI.
  final String displayName;
  final int trackCount;
}

String _newDeletionObservationEpoch() {
  final random = Random.secure();
  return List<String>.generate(
    4,
    (_) => random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'),
    growable: false,
  ).join('-');
}

class _PendingScanRequest {
  _PendingScanRequest({
    required this.forceFullIdentityReconcile,
    required this.reconcileDeletions,
  }) {
    // Observer/recovery requests are intentionally fire-and-forget. Keep a
    // terminal error on their completer from becoming an unhandled async
    // error when nobody owns the returned Future. Awaiting callers still see
    // the original completer result.
    unawaited(completer.future.catchError((_) {}));
  }

  final bool forceFullIdentityReconcile;
  final bool reconcileDeletions;
  final Completer<void> completer = Completer<void>();
}

class _PendingScanBatch {
  const _PendingScanBatch({
    required this.requests,
    required this.forceFullIdentityReconcile,
    required this.reconcileDeletions,
  });

  const _PendingScanBatch.empty()
      : requests = const <_PendingScanRequest>[],
        forceFullIdentityReconcile = false,
        reconcileDeletions = false;

  final List<_PendingScanRequest> requests;
  final bool forceFullIdentityReconcile;
  final bool reconcileDeletions;
}

/// Orchestrates scan -> bulk DB write -> deletion sync. The native scan
/// already runs off the platform's main thread; the Dart side keeps
/// writes batched in a single Isar transaction so refreshing a large
/// library never causes jank in the widget tree.
class LibraryRepository {
  /// Hard cap for direct repository search callers (queue specs also enforce this).
  /// This prevents an accidental/untrusted caller from creating an oversized
  /// Isar query even when it bypasses [QueueSpec].
  static const int maxSearchQueryLength = 4096;
  /// Repository-level page admission guard. UI callers normally use 60, but
  /// the repository must not allow an untrusted caller to request an
  /// arbitrarily large Track materialization in one call.
  static const int maxPageSize = 500;
  /// The supported production target is a multi-million-track library.
  /// Refuse offsets beyond that bound instead of allowing pathological
  /// skip-work to be injected through the repository API.
  static const int maxPageOffset = 5000000;
  /// Search predicates are ORed over terms; cap the term fan-out separately
  /// from the raw query length so a 4 KiB punctuation/one-character burst
  /// cannot create thousands of indexed branches.
  static const int maxSearchTerms = 128;
  static const int maxVolumeLength = 256;

  static bool _validPageArgs({required int offset, required int limit}) =>
      offset >= 0 && offset <= maxPageOffset && limit >= 0 && limit <= maxPageSize;

  static List<String>? _searchTerms(String query) {
    // Check the raw length before trim/splitting so a direct caller cannot
    // force allocation/work on an oversized string before admission control.
    if (query.length > maxSearchQueryLength) return null;
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return const <String>[];
    }
    final terms = Isar.splitWords(normalizedQuery);
    if (terms.isEmpty) return const <String>[];
    final unique = <String>{};
    for (final term in terms) {
      if (term.isEmpty) continue;
      unique.add(term);
      if (unique.length > maxSearchTerms) return null;
    }
    return unique.toList(growable: false);
  }

  LibraryRepository(this._isar) {
    _deletionReconciliationTimer = Timer.periodic(
      _deletionReconciliationCheckInterval,
      (_) => unawaited(_runPeriodicDeletionReconciliation()),
    );
  }
  final Isar _isar;
  Timer? _deletionReconciliationTimer;
  Timer? _startupDeletionReconciliationRetryTimer;
  bool _periodicDeletionReconciliationInFlight = false;
  bool _startupDeletionReconciliationRequested = false;
  bool _disposed = false;
  int _startupDeletionReconciliationRetryAttempt = 0;

  // A new process instance is never allowed to inherit deletion-observation
  // coverage from a previous process. The epoch is intentionally process-local
  // and is persisted only after a successful, stable reconciliation. Therefore
  // a process restart/crash/force-stop can never make an old baseline valid.
  final String _processDeletionObservationEpoch = _newDeletionObservationEpoch();

  /// Riverpod owns the repository lifetime. Cancelling the timer prevents
  /// future ticks; in-flight/queued work also observes [_disposed] at every
  /// async boundary so disposal cannot start new repository mutations.
  void dispose() {
    _disposed = true;
    disposeStreams();
    _deletionReconciliationTimer?.cancel();
    _deletionReconciliationTimer = null;
    _startupDeletionReconciliationRetryTimer?.cancel();
    _startupDeletionReconciliationRetryTimer = null;
    _scanCoalesceTimer?.cancel();
    _scanCoalesceTimer = null;
    _observerBaselineRetryTimer?.cancel();
    _observerBaselineRetryTimer = null;
    final error = StateError('LibraryRepository has been disposed');
    final pending = List<_PendingScanRequest>.of(_pendingScanRequestQueue);
    _pendingScanRequestQueue.clear();
    for (final request in pending) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(error);
      }
    }
  }

  void _scheduleObserverBaselineRetry() {
    if (_disposed || _observerBaselineRetryTimer != null) return;
    final index = min(
      _observerBaselineRetryAttempt,
      _observerBaselineRetryDelays.length - 1,
    );
    final delay = _observerBaselineRetryDelays[index];
    _observerBaselineRetryAttempt++;
    _observerBaselineRetryTimer = Timer(delay, () {
      _observerBaselineRetryTimer = null;
      unawaited(_retryObserverBaseline());
    });
  }

  Future<bool> _commitAndPersistDeletionObservationBaseline() async {
    if (_disposed) return false;
    try {
      final committed = await PlayerChannel.instance
          .commitDeletionObservationBaseline(_processDeletionObservationEpoch);
      if (!committed || _disposed) return false;

      // Native owns the live observer boundary; Dart owns the durable
      // process-epoch marker used by the next maintenance check. Persist the
      // marker only after native has accepted the stable boundary. If this
      // write fails, keep the marker invalid and let the cheap retry path
      // repair it rather than weakening deletion safety.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _deletionObservationBaselineEpochKey,
        _processDeletionObservationEpoch,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _retryObserverBaseline() async {
    if (_disposed) return;
    final committed = await _commitAndPersistDeletionObservationBaseline();
    if (committed) {
      _observerBaselineRetryAttempt = 0;
    } else {
      _scheduleObserverBaselineRetry();
    }
  }

  /// Establishes a deletion-safe observation boundary for this process
  /// instance. The initial incremental scan remains fast; this request is
  /// serialized through the same repository scan pipeline and therefore cannot
  /// race a normal/observer/maintenance scan.
  ///
  /// Failure is deliberately retried with bounded backoff. The durable
  /// baseline remains invalid until a complete stable reconciliation commits it.
  Future<void> requestStartupDeletionReconciliation() async {
    if (_disposed || _startupDeletionReconciliationRequested) return;
    _startupDeletionReconciliationRequested = true;
    await _runStartupDeletionReconciliationAttempt();
  }

  Future<void> _runStartupDeletionReconciliationAttempt() async {
    if (_disposed) return;
    try {
      await scanAndPersist(reconcileDeletions: true);
      _startupDeletionReconciliationRetryAttempt = 0;
    } catch (_) {
      _scheduleStartupDeletionReconciliationRetry();
    }
  }

  void _scheduleStartupDeletionReconciliationRetry() {
    if (_disposed || _startupDeletionReconciliationRetryTimer != null) return;
    const delays = <Duration>[
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 15),
    ];
    final index = min(
      _startupDeletionReconciliationRetryAttempt,
      delays.length - 1,
    );
    _startupDeletionReconciliationRetryAttempt++;
    _startupDeletionReconciliationRetryTimer = Timer(delays[index], () {
      _startupDeletionReconciliationRetryTimer = null;
      unawaited(_runStartupDeletionReconciliationAttempt());
    });
  }

  Future<void> _runPeriodicDeletionReconciliation() async {
    // Maintenance is single-flight. The reconciliation is deliberately O(N)
    // and can outlive the 15-minute maintenance tick on very large libraries.
    // Never allow a later tick to enqueue another full reconciliation while
    // the previous maintenance pass is still waiting/running.
    if (_disposed || _periodicDeletionReconciliationInFlight) return;
    _periodicDeletionReconciliationInFlight = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (_disposed) return;
      final last = prefs.getInt(_lastDeletionReconciliationKey);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final baselineEpoch =
          prefs.getString(_deletionObservationBaselineEpochKey);
      final baselineValid =
          baselineEpoch == _processDeletionObservationEpoch;
      // Native keeps this recovery bit sticky after observer loss until a
      // stable reconciliation explicitly commits a new boundary. This avoids
      // the failure case where an observer recovers before the next timer tick
      // and a missed deletion would otherwise be hidden behind the six-hour
      // maintenance interval.
      final observerNeedsRecovery = await PlayerChannel.instance
          .observerNeedsDeletionReconciliation();
      if (_disposed) return;
      final due = observerNeedsRecovery ||
          !baselineValid ||
          last == null ||
          nowMs < last ||
          nowMs - last >= _deletionReconciliationInterval.inMilliseconds;
      // A new process starts with an invalid deletion-observation baseline.
      // The startup path requests reconciliation immediately; this 15-minute
      // maintenance tick is the deterministic retry/fallback if that request
      // fails or is never reached. Once the current process has established a
      // stable baseline, normal maintenance returns to the six-hour interval.
      if (_disposed || !due) return;
      await scanAndPersist(reconcileDeletions: true);
    } catch (_) {
      // The next timer tick, observer event, or explicit scan is the retry
      // mechanism. A background maintenance failure must never surface as an
      // unhandled Future error.
    } finally {
      _periodicDeletionReconciliationInFlight = false;
    }
  }

  // Only one library scan may mutate/reconcile Isar at a time. Repeated
  // requests while a scan is active coalesce onto the same Future rather
  // than starting a second snapshot/deletion reconciliation concurrently.
  Future<void>? _scanInFlight;
  final List<_PendingScanRequest> _pendingScanRequestQueue =
      <_PendingScanRequest>[];
  Future<void>? _scanWorkerFuture;
  bool _scanWorkerScheduled = false;
  bool _scanInProgress = false;

  // Single repository-wide async serialization point. Unlike a Dart
  // `synchronized` block, this remains held across awaited platform/Isar I/O.
  // Every operation that can mutate/reconcile the library must pass through it.
  Future<void> _syncTail = Future<void>.value();
  int _repositorySyncPendingCount = 0;
  bool _repositorySyncInProgress = false;

  // Legacy volumes have no per-row generation cursor. Observer hints remain
  // the targeted deletion signal while the process is alive; uncertain events
  // and provider/version changes request conservative recovery. Recovery
  // decisions must come from durable synchronization state, never from a
  // process-local "first scan" flag: a clean process restart must not turn
  // an otherwise safe incremental startup into an O(N) identity walk.

  Future<T> _enqueueSync<T>(Future<T> Function() operation) {
    if (_disposed) {
      return Future<T>.error(
        StateError('LibraryRepository has been disposed'),
      );
    }

    // Mark the operation as queued synchronously, before the worker is
    // scheduled. Readers such as waitForStableSnapshot() must not observe a
    // false "stable" window between this call and the first await below.
    _repositorySyncPendingCount++;
    final result = Completer<T>();
    final previous = _syncTail;
    final gate = Completer<void>();
    _syncTail = gate.future;
    unawaited(() async {
      try {
        await previous;
      } catch (_) {
        // One failed operation must not poison the queue for later retries.
      }
      try {
        if (_disposed) {
          result.completeError(
            StateError('LibraryRepository was disposed before queued work started'),
          );
          return;
        }
        _repositorySyncInProgress = true;
        result.complete(await operation());
      } catch (error, stackTrace) {
        if (!result.isCompleted) {
          result.completeError(error, stackTrace);
        }
      } finally {
        _repositorySyncInProgress = false;
        _repositorySyncPendingCount--;
        gate.complete();
      }
    }());
    return result.future;
  }
  int _libraryGeneration = 0;

  /// Monotonically changes whenever a scan/reconciliation transaction may
  /// mutate the queryable library. Queue readers use this as a lightweight
  /// snapshot invalidation token. It is intentionally bumped before the
  /// asynchronous scan begins, so a queue request cannot finish against a
  /// dataset whose mutation has already started.
  int get libraryGeneration => _libraryGeneration;

  bool get scanInProgress => _scanInProgress;

  /// Returns the active scan future, or a drain future while a scan request has
  /// been queued but has not entered the coalescing worker yet. This closes the
  /// request-to-execution visibility gap without changing the public type.
  Future<void>? get scanInFlight => _scanInFlight ?? _scanWorkerFuture;

  /// FIX #2: fires `volume:id` identities of any tracks removed by
  /// [_syncDeletions] (i.e. deleted from device storage since the last
  /// scan). `PlaybackController` forwards these straight to the native
  /// queue so a track that's playing (or queued) right now gets pruned
  /// immediately instead of the native side only finding out the next
  /// time it happens to re-fetch that page.
  final _tracksDeletedController = StreamController<List<String>>.broadcast();
  Stream<List<String>> get tracksDeleted => _tracksDeletedController.stream;

  /// Fires when existing rows are inserted or updated by a scan. The playback
  /// queue uses this only as a lightweight invalidation signal; native
  /// re-anchors on the currently playing identity and re-resolves its window.
  final _tracksChangedController = StreamController<void>.broadcast();
  Stream<void> get tracksChanged => _tracksChangedController.stream;

  /// Successful scan generations invalidate the native logical queue even
  /// when the scan made no library-data change. UI paging listens only to
  /// [tracksChanged] so no-op scans do not evict resident pages.
  final _queueInvalidationController = StreamController<void>.broadcast();
  Stream<void> get queueInvalidations => _queueInvalidationController.stream;

  /// Prevent duplicate embedded/sidecar lookups for the same track when two
  /// lyrics screens/widgets ask at nearly the same time.
  final Map<String, Future<String?>> _lyricsInFlight = {};
  Map<String, int> _lastObservedVolumeLifecycleGenerations = {};
  DateTime? _lastSuccessfulScanCompletedAt;
  Timer? _scanCoalesceTimer;
  Timer? _observerBaselineRetryTimer;
  int _observerBaselineRetryAttempt = 0;
  bool _scanFailureRecoveryRetryScheduled = false;
  int _scanFailureRecoveryAttempt = 0;
  bool _deferredScanForceFullIdentityReconcile = false;
  bool _deferredScanReconcileDeletions = false;

  static const int _maxScanFailureRecoveryAttempts = 5;
  static const Duration _scanFailureRecoveryBaseDelay = Duration(seconds: 2);
  static const Duration _scanFailureRecoveryMaxDelay = Duration(minutes: 1);
  static const List<Duration> _observerBaselineRetryDelays = <Duration>[
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
  ];
  static const _scanRequestCoalesceWindow = Duration(seconds: 2);

  void disposeStreams() {
    _tracksDeletedController.close();
    _tracksChangedController.close();
    _queueInvalidationController.close();
    _lyricsInFlight.clear();
  }

  /// Scans for new/changed tracks, upserts them, and removes any track
  /// whose underlying file no longer exists in MediaStore (deleted from
  /// device storage since the last scan) so stale entries don't linger
  /// in the library.
  /// Waits until no scan is actively mutating Isar. Consumers should call
  /// this before starting a multi-query snapshot and re-check [scanInProgress]
  /// immediately before publishing the result.
  Future<int> waitForStableSnapshot() async {
    while (true) {
      // A failed scan may leave a recovery placeholder queued while the
      // worker is intentionally unscheduled during exponential backoff.
      // There is no active Isar mutation during this interval, so treating
      // it as stable prevents a tight microtask loop from starving the
      // event-loop timer that will perform the retry.
      if (_scanFailureRecoveryRetryScheduled &&
          !_scanWorkerScheduled &&
          !_repositorySyncInProgress &&
          _scanInFlight == null &&
          _repositorySyncPendingCount == 0) {
        return _libraryGeneration;
      }
      if (_repositorySyncPendingCount == 0 &&
          !_repositorySyncInProgress &&
          _pendingScanRequestQueue.isEmpty &&
          !_scanWorkerScheduled &&
          _scanInFlight == null) {
        return _libraryGeneration;
      }
      final coalesceTimerPending = _scanCoalesceTimer != null;
      if (coalesceTimerPending &&
          _repositorySyncPendingCount == 0 &&
          !_repositorySyncInProgress &&
          _scanInFlight == null &&
          !_scanWorkerScheduled) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        continue;
      }
      final tail = _syncTail;
      await tail;
    }
  }

  /// Reconciles only the MediaStore identities reported by the native
  /// ContentObserver. This is the deletion fast-path for modern volumes:
  /// MediaStore generation deltas contain currently-existing rows, so a
  /// deleted row cannot be discovered from the generation query itself.
  /// The observer gives us the affected identity; native validation decides
  /// whether that identity still exists before any Isar delete is committed.
  ///
  /// The batch is deliberately bounded to the same 500-item platform limit.
  Future<int> reconcileMediaStoreChangeIdentities(
    List<String> identities,
  ) => _enqueueSync(() async {
        final result =
            await _reconcileMediaStoreChangeIdentitiesLocked(identities);
        final targetedMutation = result.deleted > 0 || result.recreated;
        if (targetedMutation && !_tracksChangedController.isClosed) {
          // The targeted Isar mutation is already committed. Publish it before
          // the follow-up scan so a scan failure cannot hide the mutation.
          _tracksChangedController.add(null);
        }
        if (targetedMutation) {
          unawaited(scanAndPersist().catchError((_) {}));
        }
        return result.deleted;
      });

  Future<({int deleted, bool recreated})> _reconcileMediaStoreChangeIdentitiesLocked(
    List<String> identities,
  ) async {
    if (identities.isEmpty) return (deleted: 0, recreated: false);
    if (identities.length > _deletionSyncChunkSize) {
      var total = 0;
      var recreated = false;
      for (var start = 0; start < identities.length; start += _deletionSyncChunkSize) {
        final end = (start + _deletionSyncChunkSize).clamp(0, identities.length);
        final result = await _reconcileMediaStoreChangeIdentitiesLocked(
          identities.sublist(start, end),
        );
        total += result.deleted;
        recreated = recreated || result.recreated;
      }
      return (deleted: total, recreated: recreated);
    }

    var recreatedMutation = false;
    final parsed = <String, List<int>>{};
    for (final raw in identities) {
      final separator = raw.indexOf(':');
      if (separator <= 0 || separator >= raw.length - 1) continue;
      final volume = raw.substring(0, separator).trim();
      final id = int.tryParse(raw.substring(separator + 1));
      if (volume.isEmpty || id == null || id <= 0) continue;
      (parsed[volume] ??= <int>[]).add(id);
    }
    if (parsed.isEmpty) return (deleted: 0, recreated: false);

    final candidates = <Track>[];
    for (final entry in parsed.entries) {
      final ids = entry.value.toSet().toList(growable: false);
      if (ids.isEmpty) continue;
      final rows = await _isar.tracks
          .where()
          .anyOf(ids, (q, id) =>
              q.mediaStoreVolumeMediaStoreIdEqualTo(entry.key, id))
          .findAll();
      candidates.addAll(rows);
    }
    if (candidates.isEmpty) return (deleted: 0, recreated: false);

    final payload = candidates
        .map((t) => '${t.mediaStoreVolume}:${t.mediaStoreId}')
        .toList(growable: false);

    // An observer event is only a hint. Never perform a destructive delete
    // from a single existence-only observation: the MediaStore row can be
    // deleted and recreated between the observer query and the Isar commit.
    // Instead, confirm the candidate through the strict snapshot validator.
    // A present row (even with changed metadata/generation) is therefore not
    // considered stale; only a strict, stable snapshot that contains no row
    // can enter the deletion path.
    final validationPayload = candidates
        .map((t) => <String, dynamic>{
              'volume': t.mediaStoreVolume,
              'id': t.mediaStoreId,
              'dateModified': t.dateModified,
              'durationMs': t.durationMs,
              'displayName': t.displayName,
              'relativePath': t.relativePath,
              'title': t.title,
              'artist': t.artist,
              'album': t.album,
              'contentUri': t.contentUri,
              'generationModified': t.mediaStoreGenerationModified,
            })
        .toList(growable: false);
    final existing = await PlayerChannel.instance
        .findExistingMediaStoreIdentities(validationPayload);
    // Strict validation returns only exact matches, so metadata changes would
    // look absent. Re-query plain existence for those candidates and preserve
    // every currently-present row. This makes observer reconciliation fail
    // closed: a destructive delete is considered only after an authoritative
    // stable absence, never merely because an observer snapshot disagreed.
    final presentNow = await PlayerChannel.instance
        .findExistingMediaStoreObserverIdentities(payload);
    final stale = candidates.where((t) =>
        !presentNow.contains('${t.mediaStoreVolume}:${t.mediaStoreId}') &&
        !existing.contains('${t.mediaStoreVolume}:${t.mediaStoreId}'))
        .toList(growable: false);
    if (stale.isEmpty) return (deleted: 0, recreated: false);

    final deletedIdentities = <String>[];
    await _isar.writeTxn(() async {
      final idsToDelete = <int>[];
      for (final expected in stale) {
        final current = await _isar.tracks.get(expected.id);
        if (current == null) continue;
        if (current.mediaStoreVolume != expected.mediaStoreVolume ||
            current.mediaStoreId != expected.mediaStoreId ||
            current.dateModified != expected.dateModified ||
            current.durationMs != expected.durationMs ||
            current.displayName != expected.displayName ||
            current.relativePath != expected.relativePath ||
            current.title != expected.title ||
            current.artist != expected.artist ||
            current.album != expected.album ||
            current.contentUri != expected.contentUri ||
            current.mediaStoreGenerationModified !=
                expected.mediaStoreGenerationModified) {
          continue;
        }
        idsToDelete.add(current.id);
        deletedIdentities.add(
          '${current.mediaStoreVolume}:${current.mediaStoreId}',
        );
      }
      if (idsToDelete.isNotEmpty) {
        await _isar.tracks.deleteAll(idsToDelete);
      }
    });

    if (deletedIdentities.isNotEmpty) {
      try {
        // Close the MediaStore/Isar TOCTOU window with a post-commit identity
        // check. If the provider row reappeared, rehydrate the authoritative
        // current row instead of reporting a deletion for a live identity.
        final presentAfterDelete = await PlayerChannel.instance
            .findExistingMediaStoreObserverIdentities(deletedIdentities);
        if (presentAfterDelete.isNotEmpty) {
          final recreated = presentAfterDelete.toSet();
          final recreatedRows = deletedIdentities
              .where(recreated.contains)
              .toList(growable: false);
          if (recreatedRows.isNotEmpty) {
            // These identities are confirmed present again. Remove them from
            // the deletion publication before the fallible re-upsert so an
            // upsert/read failure can never prune a live playback queue.
            deletedIdentities.removeWhere(recreated.contains);
            final recreatedUpserted =
                await _upsertMediaStoreChangeIdentitiesLocked(recreatedRows);
            recreatedMutation = recreatedMutation || recreatedUpserted;
          }
        }
      } finally {
        // Isar deletion is already committed. Whatever fails during the
        // compensation/re-hydration step, publish the identities that remain
        // deleted so consumers cannot miss a committed mutation.
        if (deletedIdentities.isNotEmpty &&
            !_tracksDeletedController.isClosed) {
          _tracksDeletedController.add(List.unmodifiable(deletedIdentities));
        }
      }
    }
    return (
      deleted: deletedIdentities.length,
      recreated: recreatedMutation,
    );
  }

  /// Single entry point for native MediaStore observer hints. Targeted
  /// identities are reconciled first; uncertain events request an identity-only
  /// full reconciliation. The subsequent incremental scan remains serialized
  /// under the same repository queue.
  Future<void> handleMediaStoreChanged({
    List<String> identities = const <String>[],
    bool unknown = false,
  }) => _enqueueSync(() async {
        var targetedMutation = false;
        try {
          if (identities.isNotEmpty) {
            // An item-specific observer event is also the authoritative live
            // hint for API29/non-generation additions and metadata changes.
            // Upsert the current rows directly instead of forcing a whole-volume
            // DATE_MODIFIED/full enumeration. Deletion is handled separately by
            // the identity reconciliation below.
            final upserted =
                await _upsertMediaStoreChangeIdentitiesLocked(identities);
            final reconciliation =
                await _reconcileMediaStoreChangeIdentitiesLocked(identities);
            targetedMutation =
                upserted || reconciliation.deleted > 0 || reconciliation.recreated;
            if (targetedMutation && !_tracksChangedController.isClosed) {
              // The targeted mutation is committed before the follow-up scan.
              // Publish it now so a later scan failure cannot hide it.
              _tracksChangedController.add(null);
            }
          }
        } finally {
          // Even when targeted upsert/reconciliation fails, the observer event
          // remains uncertain and must be covered by a follow-up scan.
          unawaited(
            scanAndPersist(
              forceFullIdentityReconcile: unknown,
            ).catchError((_) {}),
          );
        }
      });

  Track _trackFromMediaStoreMap(
    Map<String, dynamic> map, {
    String? expectedVolume,
  }) {
    final rawVolume = map['volume'];
    if (rawVolume is! String || rawVolume.trim().isEmpty) {
      throw StateError('MediaStore scan row is missing a valid volume');
    }
    final volume = rawVolume.trim();
    if (expectedVolume != null && volume != expectedVolume) {
      throw StateError(
        'MediaStore scan row volume mismatch: expected $expectedVolume, got $volume',
      );
    }

    final rowId = map['id'];
    if (rowId is! num || !rowId.isFinite || rowId <= 0 || rowId % 1 != 0) {
      throw StateError('MediaStore scan row has an invalid ID');
    }

    final track = Track()
      ..mediaStoreVolume = volume
      ..mediaStoreId = rowId.toInt()
      ..title = (map['title'] as String?)?.trim().isNotEmpty == true
          ? map['title'] as String
          : 'Unknown Title'
      ..artist = (map['artist'] as String?)?.trim().isNotEmpty == true
          ? map['artist'] as String
          : 'Unknown Artist'
      ..album = (map['album'] as String?)?.trim().isNotEmpty == true
          ? map['album'] as String
          : 'Unknown Album'
      ..durationMs = (map['duration'] as num?)?.toInt() ?? 0
      ..contentUri = (map['contentUri'] as String?) ?? ''
      ..relativePath = map['relativePath'] as String?
      ..displayName = (map['displayName'] as String?) ?? ''
      ..dateModified = (map['dateModified'] as num?)?.toInt() ?? 0
      ..mediaStoreGenerationModified =
          (map['generationModified'] as num?)?.toInt()
      ..derivedCacheEpoch = _libraryGeneration;
    track.folder = Track.computeFolder(
      relativePath: track.relativePath,
      album: track.album,
      volume: track.mediaStoreVolume,
    );
    return track;
  }

  Future<bool> _upsertMediaStoreChangeIdentitiesLocked(
    List<String> identities,
  ) async {
    var changed = false;
    final grouped = <String, Set<int>>{};
    for (final raw in identities) {
      final separator = raw.indexOf(':');
      if (separator <= 0 || separator >= raw.length - 1) continue;
      final volume = raw.substring(0, separator).trim();
      final id = int.tryParse(raw.substring(separator + 1));
      if (volume.isEmpty || id == null || id <= 0) continue;
      (grouped[volume] ??= <int>{}).add(id);
    }

    for (final entry in grouped.entries) {
      final ids = entry.value.toList(growable: false);
      for (var start = 0; start < ids.length; start += _deletionSyncChunkSize) {
        final end = (start + _deletionSyncChunkSize).clamp(0, ids.length);
        final rows = await PlayerChannel.instance.scanLibraryIdentities(
          volume: entry.key,
          ids: ids.sublist(start, end),
        );
        if (rows.isEmpty) continue;
        final tracks = rows
            .map((m) => _trackFromMediaStoreMap(m, expectedVolume: entry.key))
            .where((t) => t.contentUri.isNotEmpty)
            .toList(growable: false);
        if (tracks.isNotEmpty) {
          changed = await _persistScanBatch(tracks) || changed;
        }
      }
    }
    return changed;
  }

  /// Performs an incremental library scan by default. Full deletion
  /// reconciliation is deliberately opt-in; normal startup/restore scans
  /// must not become O(N) merely because the library is large. A durable
  /// maintenance timer requests the stronger absence reconciliation on a
  /// bounded schedule, and callers may explicitly request it as well (for
  /// example, a manual refresh).
  Future<void> scanAndPersist({
    bool forceFullIdentityReconcile = false,
    bool reconcileDeletions = false,
  }) {
    if (_disposed) {
      return Future<void>.error(
        StateError('LibraryRepository has been disposed'),
      );
    }

    // Register synchronously so a burst of callers can be merged before the
    // worker starts. Requests arriving while a scan is already running remain
    // queued for exactly one follow-up pass, rather than each creating a pass.
    final requestForceFullIdentityReconcile =
        forceFullIdentityReconcile || _deferredScanForceFullIdentityReconcile;
    final requestReconcileDeletions =
        reconcileDeletions || _deferredScanReconcileDeletions;
    _deferredScanForceFullIdentityReconcile = false;
    _deferredScanReconcileDeletions = false;
    final request = _PendingScanRequest(
      forceFullIdentityReconcile: requestForceFullIdentityReconcile,
      reconcileDeletions: requestReconcileDeletions,
    );
    _pendingScanRequestQueue.add(request);

    // A failed scan establishes a repository-wide backoff window. New
    // requests join the pending batch but must not bypass that backoff by
    // scheduling another worker immediately. The retry timer owns the next
    // worker start.
    if (!_scanWorkerScheduled && !_scanFailureRecoveryRetryScheduled) {
      _scheduleScanWorkerRespectingCoalesce();
    }
    return request.completer.future;
  }

  Future<void> _drainScanRequestQueue() async {
    var failedExit = false;
    try {
      while (!_disposed) {
        if (_pendingScanRequestQueue.isEmpty) return;

        final batch = _takePendingScanRequests();
        if (batch.requests.isEmpty) continue;

        late final Future<void> scan;
        scan = _runCoalescedScan(
          forceFullIdentityReconcile: batch.forceFullIdentityReconcile,
          reconcileDeletions: batch.reconcileDeletions,
        ).whenComplete(() {
          if (identical(_scanInFlight, scan)) _scanInFlight = null;
        });
        _scanInFlight = scan;

        try {
          await scan;
          _scanFailureRecoveryRetryScheduled = false;
          _scanFailureRecoveryAttempt = 0;
          for (final request in batch.requests) {
            if (!request.completer.isCompleted) request.completer.complete();
          }
        } catch (error, stackTrace) {
          // Preserve the strongest flags from a failed merged scan. This is
          // especially important for fire-and-forget observer requests: there
          // is no caller awaiting the failed completer that can retry them.
          _pendingScanRequestQueue.insert(
            0,
            _PendingScanRequest(
              forceFullIdentityReconcile: batch.forceFullIdentityReconcile,
              reconcileDeletions: batch.reconcileDeletions,
            ),
          );
          for (final request in batch.requests) {
            if (!request.completer.isCompleted) {
              request.completer.completeError(error, stackTrace);
            }
          }

          failedExit = true;
          _scanFailureRecoveryAttempt++;
          if (_scanFailureRecoveryAttempt >=
                  _maxScanFailureRecoveryAttempts ||
              _disposed) {
            // Do not leave waitForStableSnapshot permanently blocked after a
            // persistent failure. Preserve the strongest recovery intent for
            // the next explicit/observer scan instead of silently dropping
            // deletion/full-reconcile work.
            _deferredScanForceFullIdentityReconcile |=
                batch.forceFullIdentityReconcile;
            _deferredScanReconcileDeletions |= batch.reconcileDeletions;
            final pending =
                List<_PendingScanRequest>.of(_pendingScanRequestQueue);
            _pendingScanRequestQueue.clear();
            for (final request in pending) {
              _deferredScanForceFullIdentityReconcile |=
                  request.forceFullIdentityReconcile;
              _deferredScanReconcileDeletions |=
                  request.reconcileDeletions;
            }
            for (final request in pending) {
              if (!request.completer.isCompleted) {
                request.completer.completeError(error, stackTrace);
              }
            }
            _scanFailureRecoveryRetryScheduled = false;
            _scanFailureRecoveryAttempt = 0;
            return;
          }

          if (!_scanFailureRecoveryRetryScheduled) {
            _scanFailureRecoveryRetryScheduled = true;
            final exponent = _scanFailureRecoveryAttempt - 1;
            final multiplier = 1 << exponent;
            final uncappedMillis =
                _scanFailureRecoveryBaseDelay.inMilliseconds * multiplier;
            final delay = Duration(
              milliseconds: uncappedMillis <
                      _scanFailureRecoveryMaxDelay.inMilliseconds
                  ? uncappedMillis
                  : _scanFailureRecoveryMaxDelay.inMilliseconds,
            );
            unawaited(Future<void>.delayed(delay, () {
              if (!_disposed) {
                // The retry timer is the only path allowed to cross the
                // failure backoff boundary. Schedule the worker before
                // clearing the gate so a new request arriving in this
                // callback cannot create a competing immediate attempt.
                _scheduleScanWorker(ignoreFailureBackoff: true);
              }
              _scanFailureRecoveryRetryScheduled = false;
            }));
          }
          return;
        }
        // Requests arriving during the scan remain queued and are merged into
        // one follow-up scan. Requests already in [batch] are now covered.
      }
    } finally {
      _scanWorkerScheduled = false;
      if (_disposed && _pendingScanRequestQueue.isNotEmpty) {
        final pending = List<_PendingScanRequest>.of(_pendingScanRequestQueue);
        _pendingScanRequestQueue.clear();
        final error = StateError('LibraryRepository has been disposed');
        for (final request in pending) {
          if (!request.completer.isCompleted) {
            request.completer.completeError(error);
          }
        }
      } else if (!_disposed &&
          !failedExit &&
          _pendingScanRequestQueue.isNotEmpty) {
        _scheduleScanWorkerRespectingCoalesce();
      }
    }
  }

  void _scheduleScanWorkerRespectingCoalesce() {
    if (_disposed || _scanWorkerScheduled || _scanFailureRecoveryRetryScheduled) {
      return;
    }
    final completedAt = _lastSuccessfulScanCompletedAt;
    if (completedAt == null) {
      _scheduleScanWorker();
      return;
    }
    final elapsed = DateTime.now().difference(completedAt);
    // A backwards wall-clock adjustment must never turn the coalescing delay
    // into an unexpectedly long stall. Treat negative elapsed time as zero.
    final effectiveElapsed = elapsed.isNegative ? Duration.zero : elapsed;
    final remaining = _scanRequestCoalesceWindow - effectiveElapsed;
    if (remaining <= Duration.zero) {
      _scheduleScanWorker();
      return;
    }
    if (_scanCoalesceTimer != null) return;
    _scanCoalesceTimer = Timer(remaining, () {
      _scanCoalesceTimer = null;
      if (_disposed || _scanFailureRecoveryRetryScheduled) return;
      _scheduleScanWorker();
    });
  }

  void _scheduleScanWorker({bool ignoreFailureBackoff = false}) {
    if (_scanWorkerScheduled || _disposed) return;
    if (_scanFailureRecoveryRetryScheduled && !ignoreFailureBackoff) return;
    _scanWorkerScheduled = true;
    final worker = _enqueueSync<void>(_drainScanRequestQueue);
    _scanWorkerFuture = worker;
    unawaited(worker.catchError((error, stackTrace) {
      final pending = List<_PendingScanRequest>.of(_pendingScanRequestQueue);
      _pendingScanRequestQueue.clear();
      for (final request in pending) {
        if (!request.completer.isCompleted) {
          request.completer.completeError(error, stackTrace);
        }
      }
    }).whenComplete(() {
      if (identical(_scanWorkerFuture, worker)) {
        _scanWorkerFuture = null;
      }
    }));
  }

  _PendingScanBatch _takePendingScanRequests() {
    if (_pendingScanRequestQueue.isEmpty) {
      return const _PendingScanBatch.empty();
    }
    final requests = List<_PendingScanRequest>.of(_pendingScanRequestQueue);
    _pendingScanRequestQueue.clear();
    var forceFullIdentityReconcile = false;
    var reconcileDeletions = false;
    for (final request in requests) {
      forceFullIdentityReconcile |= request.forceFullIdentityReconcile;
      reconcileDeletions |= request.reconcileDeletions;
    }
    return _PendingScanBatch(
      requests: requests,
      forceFullIdentityReconcile: forceFullIdentityReconcile,
      reconcileDeletions: reconcileDeletions,
    );
  }

  Future<void> _runCoalescedScan({
    bool forceFullIdentityReconcile = false,
    bool reconcileDeletions = false,
  }) async {
    await _scanAndPersistInternal(
      forceFullIdentityReconcile: forceFullIdentityReconcile,
      reconcileDeletions: reconcileDeletions,
    );
  }

  Future<void> _scanAndPersistInternal({
    bool forceFullIdentityReconcile = false,
    bool reconcileDeletions = false,
  }) async {
    _scanInProgress = true;
    try {
      await _scanAndPersistInternalImpl(
        forceFullIdentityReconcile: forceFullIdentityReconcile,
        reconcileDeletions: reconcileDeletions,
      );
    } finally {
      _scanInProgress = false;
    }
  }

  Future<void> _scanAndPersistInternalImpl({
    bool forceFullIdentityReconcile = false,
    bool reconcileDeletions = false,
  }) async {
    var changedAny = false;
    var invalidationEmitted = false;
    // Read durable recovery state before advancing the in-memory generation.
    // A preferences failure therefore cannot leave a speculative generation.
    final prefs = await SharedPreferences.getInstance();
    final interruptedSync = prefs.getBool(_syncInProgressKey) ?? false;
    _libraryGeneration = _libraryGeneration + 1;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // Only explicit/recovery/maintenance requests perform the expensive
    // absence walk. Ordinary startup, restore, and observer-driven scans stay
    // incremental and therefore do not acquire an accidental O(N) cost.
    final effectiveReconcileDeletions = reconcileDeletions;

    // Publish the invalidation token before any Isar batch can be committed.
    // The durable crash marker is written only after native accepts the new
    // generation, so a pre-native failure cannot leave a false marker.
    try {
      await PlayerChannel.instance.updateLibraryGeneration(_libraryGeneration);
    } catch (_) {
      // Native generation is monotonic. The platform may have accepted the
      // new generation before reporting an error, so never roll Dart back to
      // an epoch that native may already consider current.
      rethrow;
    }
    try {
      await prefs.setBool(_syncInProgressKey, true);
    // MediaStore.DATE_MODIFIED is expressed in Unix seconds. V16 persisted
    // this cursor in milliseconds; migrate that legacy value exactly once
    // before using the cursor so existing installations do not lose changes.
    var lastScan = prefs.getInt(_lastScanKey);
    if (lastScan == null) {
      final legacyLastScanMs = prefs.getInt(_legacyLastScanMsKey);
      if (legacyLastScanMs != null && legacyLastScanMs > 0) {
        lastScan = legacyLastScanMs ~/ 1000;
        await prefs.setInt(_lastScanKey, lastScan);
      }
    }
    lastScan ??= 0;
    final volumeMigrationComplete =
        prefs.getBool(_volumeIdentityMigrationKey) ?? false;

    // Capture the upper cursor before any MediaStore query. DATE_MODIFIED has
    // second resolution, so persist this captured second (with the existing
    // overlap) rather than the wall-clock time after a potentially long
    // multi-volume scan. A change that happens after this point is therefore
    // guaranteed to be considered by a later scan.
    final currentSecond =
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // MediaStore DATE_MODIFIED has second resolution. Exclude the current
    // (possibly still changing) second from this snapshot; the 2-second
    // overlap on the next pass guarantees those changes are picked up.
    final scanUntilSeconds =
        ((currentSecond - 1).clamp(0, currentSecond)).toInt();

    // Volume lifecycle: a newly inserted/reinserted volume can contain files
    // older than the global last-scan cursor. Compare the exact current set
    // with the set from the last successful scan and perform one bounded full
    // MediaStore scan when a volume reappears. This does not wipe Isar and it
    // does not force a full scan on ordinary startups.
    final currentVolumes =
        await PlayerChannel.instance.getMediaStoreVolumes();
    final currentVolumeStates =
        await PlayerChannel.instance.getMediaStoreVolumeStates();
    final persistedVolumeStates = _decodeVolumeStates(
      prefs.getString(_mediaStoreVolumeStatesKey),
    );
    final persistedGenerationCursors = _decodeGenerationCursors(
      prefs.getString(_mediaStoreGenerationCursorsKey),
    );
    // Generation/version is a snapshot-stability token, not a reason to
    // rescan an entire volume: ordinary MediaStore mutations advance it.
    // Presence is tracked separately by lifecycle-triggered reconciliation.
    final previousPresentVolumes =
        (prefs.getStringList(_lastPresentMediaStoreVolumesKey) ??
                prefs.getStringList(_knownMediaStoreVolumesKey) ??
                const <String>[])
            .toSet();
    // lifecycleGeneration is intentionally process-local on Android. Compare
    // it only with the last successful in-process snapshot; persisting it
    // across app restarts would turn every new process into a false lifecycle
    // change because the native counter starts from zero again. Clean restarts
    // instead rely on the persisted provider version/generation state below.
    // A normal process restart does not blindly enumerate removable volumes.
    // Persisted provider version/generation state and the crash marker decide
    // whether recovery is necessary; observer hints cover live-process changes.
    // API 29 (Android 10) exposes MediaStore.getVersion(), but that token is
    // only a coarse provider-state indicator; it is NOT a per-row deletion
    // change counter. A normal file deletion may therefore leave the version
    //unchanged. API 30+ has GENERATION_MODIFIED and can reconcile incrementally,
    // but API 29 cannot safely infer absence from an incremental cursor.
    //
    // Pre-Q devices have neither a generation nor a reliable per-row
    // deletion token. A complete absence check is therefore required after
    // process start/recovery, but doing it on every ordinary refresh would
    // make large legacy libraries O(N) for routine scans. During a live
    // process, the ContentObserver path supplies targeted identities and
    // uncertain events explicitly request recovery. Volume reappearance is
    // also promoted to a full scan below.
    // DATE_MODIFIED is a filesystem timestamp, not an authoritative change
    // cursor. It is therefore only a performance accelerator on volumes that
    // lack GENERATION_MODIFIED. Correctness for those volumes comes from the
    // process-start/recovery identity pass, MediaStore observer identities,
    // uncertain observer events, and explicit/version-triggered full scans.
    // Do not turn every ordinary refresh into O(N) enumeration merely because
    // the platform lacks a per-row generation cursor.
    // Full-reconciliation requirements are scoped to the affected volume.
    // A lifecycle/reappearance/version/recovery requirement on one volume must
    // never promote an unchanged primary or SD volume into a full enumeration.
    final fullScanVolumes = <String>{};
    if (!volumeMigrationComplete) fullScanVolumes.addAll(currentVolumes);
    // Process-local completion is an optimization only; it must never turn a
    // clean process restart into a mandatory O(N) identity walk. Durable sync
    // state (crash marker, persisted volume state/version, and generation
    // cursor validity below) is the source of truth for recovery. A first-ever
    // volume is still recovered through oldState/versionChanged handling.
    // A fresh process is not itself evidence that local MediaStore identities
    // need a full absence walk. If the previous sync committed successfully,
    // the persisted generation/version state is the recovery baseline. Only
    // an explicit reconciliation request or a durable interrupted-sync marker
    // may promote the whole current volume set to identity reconciliation.
    // This is critical for 500K-1M track libraries: ordinary process startup
    // must remain incremental on API 30+ instead of becoming O(N).
    final forceIdentityReconciliation =
        forceFullIdentityReconcile || interruptedSync;
    // Volumes without GENERATION_MODIFIED intentionally remain on the
    // timestamp accelerator during ordinary scans. A complete enumeration is
    // requested only by process-start/recovery, an explicit uncertain observer
    // event, volume/version change, or another already-established recovery
    // condition. This preserves the conservative correctness boundaries
    // without making every API29 refresh O(N).
    for (final volume in currentVolumes) {
      if (!previousPresentVolumes.contains(volume)) fullScanVolumes.add(volume);
      final previousLifecycle = _lastObservedVolumeLifecycleGenerations[volume];
      final currentLifecycle =
          (currentVolumeStates[volume]?['lifecycleGeneration'] as num?)?.toInt();
      if (previousLifecycle != null && currentLifecycle != null &&
          previousLifecycle != currentLifecycle) {
        fullScanVolumes.add(volume);
      }
    }
    final clockRolledBack = lastScan > 0 && scanUntilSeconds < lastScan;
    final scanSince = lastScan == 0 || clockRolledBack
        ? 0
        : (lastScan - _scanOverlapSeconds).clamp(0, lastScan).toInt();

    const scanChunkSize = 500;
    final fullyScannedVolumes = <String>{};
    final deletionReconciliationVolumes = <String>{};
    // Recovery is promoted only when the sync marker/cursor proves that
    // incremental absence cannot be trusted, or when an explicit/maintenance
    // reconciliation was requested. Ordinary startup remains incremental.
    if (effectiveReconcileDeletions || forceIdentityReconciliation) {
      // An explicit/manual scan is also a deletion-recovery boundary. The
      // MediaStore incremental cursor cannot enumerate rows that disappeared
      // before a ContentObserver event was delivered, so absence must be
      // checked against the current MediaStore identity set. Keep this
      // separate from forceIdentityReconciliation so API 30+ does not need a
      // second full MediaStore enumeration just to recover lost deletions.
      deletionReconciliationVolumes.addAll(currentVolumes);
      for (final volume in currentVolumes) {
        if (currentVolumeStates[volume]?['generationSupported'] != true) {
          fullScanVolumes.add(volume);
        }
      }
    }
    // Scan one volume/page at a time. The previous implementation built one
    // giant Dart list from the entire MediaStore result before touching Isar;
    // that defeated the bounded-memory design for large libraries. The
    // captured [scanUntilSeconds] makes every page a stable snapshot boundary.
    for (final volume in currentVolumes) {
      final oldState = persistedVolumeStates[volume];
      final versionChanged = oldState == null ||
          oldState['version'] != currentVolumeStates[volume]?['version'];
      final previousLifecycle = _lastObservedVolumeLifecycleGenerations[volume];
      final currentLifecycle =
          (currentVolumeStates[volume]?['lifecycleGeneration'] as num?)?.toInt();
      final lifecycleChanged = previousLifecycle != null &&
          currentLifecycle != null &&
          previousLifecycle != currentLifecycle;
      final volumeFullScan = fullScanVolumes.contains(volume) || versionChanged;
      final currentGeneration = (currentVolumeStates[volume]?['generation'] as num?)?.toInt() ?? 0;
      final savedGeneration = persistedGenerationCursors[volume];
      final generationCursorMissing = currentGeneration > 0 &&
          (savedGeneration == null || savedGeneration > currentGeneration);
      // MediaStore's volume generation advances for ordinary metadata changes
      // as well as deletions. It is therefore not a deletion signal and must
      // not, by itself, trigger an O(N) walk of every local Isar row. Targeted
      // observer identities handle known changes; an uncertain observer event,
      // crash recovery, version/full-scan conditions, or an explicit recovery
      // request still schedules the bounded identity reconciliation below.
      if (volumeFullScan || generationCursorMissing) {
        deletionReconciliationVolumes.add(volume);
      }
      final effectiveVolumeFullScan = volumeFullScan || generationCursorMissing;
      final useGenerationCursor = !effectiveVolumeFullScan &&
          currentGeneration > 0 && savedGeneration != null;
      final generationSince = useGenerationCursor ? savedGeneration! : -1;
      var cursorDateModifiedSeconds = 9223372036854775807;
      var cursorMediaStoreId = 9223372036854775807;
      var cursorGeneration = 9223372036854775807;
      while (true) {
        final rawTracks = await _readScanPage(
          volume: volume,
          sinceTimestamp: effectiveVolumeFullScan || useGenerationCursor ? 0 : scanSince,
          // Native timestamp mode treats this as DATE_MODIFIED <= until.
          // Zero is NOT an unbounded sentinel there; use Dart's 64-bit max
          // value, matching Kotlin Long.MAX_VALUE. Generation mode ignores
          // timestamp bounds, but this remains safe when generation is disabled.
          untilTimestamp: effectiveVolumeFullScan
              ? 9223372036854775807
              : (useGenerationCursor ? 0 : scanUntilSeconds),
          sinceGeneration: useGenerationCursor ? generationSince : -1,
          untilGeneration: useGenerationCursor ? currentGeneration : -1,
          cursorDateModifiedSeconds: cursorDateModifiedSeconds,
          cursorMediaStoreId: cursorMediaStoreId,
          cursorGeneration: cursorGeneration,
          limit: scanChunkSize,
        );
        if (rawTracks.isEmpty) break;
        final tracks = rawTracks
            .map((m) => _trackFromMediaStoreMap(m, expectedVolume: volume))
            .where((t) => t.contentUri.isNotEmpty)
            .toList(growable: false);

        if (tracks.isNotEmpty) {
          changedAny = await _persistScanBatch(
              tracks,
              // Full enumeration is sometimes required only to prove absence
              // (legacy volumes/recovery/manual deletion reconciliation). It
              // must not invalidate every row's derived cache. Invalidate only
              // when the volume schema/version or lifecycle boundary changed,
              // where cached derived state is no longer safely reusable.
              invalidateDerivedCache: versionChanged || lifecycleChanged,
            ) ||
            changedAny;
        }

        // A short page is not treated as terminal. Some MediaStore/OEM
        // providers legally return fewer rows than QUERY_ARG_LIMIT while
        // more rows remain. Continue from the last returned key until the
        // provider explicitly returns an empty page.
        final last = rawTracks.last;
        final nextDate = (last['dateModified'] as num?)?.toInt();
        final nextId = (last['id'] as num?)?.toInt();
        final nextGeneration = (last['generationModified'] as num?)?.toInt();
        if (nextDate == null || nextId == null) {
          throw StateError('MediaStore page cursor is missing dateModified/id');
        }
        if (useGenerationCursor) {
          if (nextGeneration == null || nextGeneration > cursorGeneration ||
              (nextGeneration == cursorGeneration && nextId >= cursorMediaStoreId)) {
            throw StateError('MediaStore generation page cursor did not make progress');
          }
          cursorGeneration = nextGeneration;
          cursorMediaStoreId = nextId;
        } else {
          if (nextDate > cursorDateModifiedSeconds ||
              (nextDate == cursorDateModifiedSeconds && nextId >= cursorMediaStoreId)) {
            throw StateError('MediaStore page cursor did not make progress');
          }
          cursorDateModifiedSeconds = nextDate;
          cursorMediaStoreId = nextId;
        }
      }
      if (effectiveVolumeFullScan) {
        fullyScannedVolumes.add(volume);
      }
    }

    final finalVolumes =
        (await PlayerChannel.instance.getMediaStoreVolumes()).toSet();
    final finalVolumeStates =
        await PlayerChannel.instance.getMediaStoreVolumeStates();
    if (currentVolumeStates.length != finalVolumeStates.length ||
        currentVolumeStates.keys.any((v) =>
            !finalVolumeStates.containsKey(v) ||
            finalVolumeStates[v]!['version'] != currentVolumeStates[v]!['version'] ||
            finalVolumeStates[v]!['lifecycleGeneration'] !=
                currentVolumeStates[v]!['lifecycleGeneration'])) {
      throw StateError(
        'MediaStore version/lifecycle changed during scan',
      );
    }
    // Generation advances for ordinary metadata changes as well as deletes.
    // A bump during this scan is therefore not a reason to discard the whole
    // pass. The persisted cursor below is the generation captured at scan
    // start, so changes after that upper bound remain eligible for the next
    // scan.
    // The scan must commit its cursor/volume snapshot only if the exact
    // volume set remained stable. A removed/reinserted/added volume makes
    // the snapshot incomplete; leaving the old cursor in place forces the
    // next pass to reconcile it instead of falsely marking it scanned.
    if (finalVolumes.length != currentVolumes.length ||
        !finalVolumes.containsAll(currentVolumes)) {
      throw StateError('MediaStore volume set changed during scan');
    }

    final deletionReconciliationSafe = finalVolumeStates.entries.every((entry) {
      final state = entry.value;
      if (state['generationSupported'] == true) return true;
      // Android 10/API 29 exposes MediaStore.getVersion(), which is a
      // provider-state token. Legacy pre-Q devices have neither generation
      // nor version, so deletion is permitted only when this pass performed
      // a complete scan of that volume.
      if (state['version'] != 'legacy') return true;
      return fullyScannedVolumes.contains(entry.key);
    });
    var rescanAfterDeletionStabilityChange = false;
    if (deletionReconciliationSafe &&
        deletionReconciliationVolumes.isNotEmpty) {
      await _syncDeletions(
        currentVolumes: finalVolumes,
        reconciliationVolumes: deletionReconciliationVolumes,
        currentVolumeStates: currentVolumeStates,
        onMutation: () => changedAny = true,
        onRescanRequested: () => rescanAfterDeletionStabilityChange = true,
      );
    }
    if (rescanAfterDeletionStabilityChange && !_disposed) {
      // The destructive reconciliation already committed. A provider change
      // observed at the compensation boundary means this pass is no longer a
      // complete absence snapshot, so request one bounded follow-up pass
      // instead of failing the whole scan and entering the global failure
      // recovery path. The request is coalesced with any observer work.
      unawaited(
        scanAndPersist(reconcileDeletions: true).catchError((_) {}),
      );
    }
    // The cursor advances only to the captured upper bound. Persisting a
    // later wall-clock value would create the classic multi-volume race:
    // a track changed after its volume was queried but before the scan
    // finished could be skipped forever on the next incremental scan.
    if (deletionReconciliationSafe &&
        (effectiveReconcileDeletions || forceIdentityReconciliation)) {
      await prefs.setInt(_lastDeletionReconciliationKey, nowMs);
    } else if (prefs.getInt(_lastDeletionReconciliationKey) == null) {
      // Establish a durable maintenance baseline after the first successful
      // ordinary scan. The initial library population already enumerates every
      // current MediaStore row, so another O(N) absence walk is unnecessary.
      // Future maintenance checks will perform bounded recovery after the
      // configured interval, including across process restarts.
      await prefs.setInt(_lastDeletionReconciliationKey, nowMs);
    }
    await prefs.setInt(_lastScanKey, scanUntilSeconds);
    final sortedVolumes = finalVolumes.toList()..sort();
    await prefs.setStringList(_knownMediaStoreVolumesKey, sortedVolumes);
    await prefs.setStringList(_lastPresentMediaStoreVolumesKey, sortedVolumes);
    await prefs.setString(_mediaStoreVolumeStatesKey,
        _encodeVolumeStates(finalVolumeStates));
    await prefs.setString(
      _mediaStoreGenerationCursorsKey,
      _encodeGenerationCursors({
        for (final entry in finalVolumeStates.entries)
          // Persist the generation captured at scan start, not the later
          // provider generation observed after the scan. Anything newer than
          // that captured upper bound is intentionally left for the next scan.
          entry.key: (currentVolumeStates[entry.key]?['generation'] as num?)?.toInt() ?? 0,
      }),
    );
    _lastObservedVolumeLifecycleGenerations = {
      for (final entry in finalVolumeStates.entries)
        entry.key: (entry.value['lifecycleGeneration'] as num?)?.toInt() ?? 0,
    };
    if (!volumeMigrationComplete) {
      await prefs.setBool(_volumeIdentityMigrationKey, true);
    }
    // Clear the durable crash marker only after the scan has completely
    // committed its cursor, volume state, and generation snapshot. If any
    // operation above fails, execution jumps to the catch block and this
    // marker intentionally remains true so the next process performs
    // conservative identity recovery.
    await prefs.setBool(_syncInProgressKey, false);

    // This is the final durable correctness boundary. The baseline is
    // committed only after the complete scan state, deletion work, final
    // provider-stability checks, cursors, and crash marker have all been
    // committed. If the process dies before this write completes, the next
    // process has a different epoch and therefore must reconcile again.
    //
    // Never move this write above any persistent scan/deletion state write:
    // doing so could make a partially committed library appear deletion-safe.
    if (deletionReconciliationSafe &&
        (effectiveReconcileDeletions || forceIdentityReconciliation)) {
      // The native layer owns the actual observer boundary. A successful
      // absence reconciliation is not sufficient by itself: native must
      // confirm that the complete observer set is active at this exact
      // commit point. Native keeps its recovery state conservative if
      // observer coverage is subsequently lost.
      final observerBaselineCommitted =
          await _commitAndPersistDeletionObservationBaseline();
      if (observerBaselineCommitted) {
        _observerBaselineRetryTimer?.cancel();
        _observerBaselineRetryTimer = null;
        _observerBaselineRetryAttempt = 0;
      } else {
        // Observer coverage can recover independently of the library scan.
        // Do not fail a fully committed scan (which would trigger the global
        // scan retry/backoff and another queue invalidation). Keep the durable
        // baseline invalid and retry only the cheap native coverage handshake
        // with its own bounded backoff.
        _scheduleObserverBaselineRetry();
      }
    }
    // Every successfully completed scan establishes a new library
    // generation, including a no-op scan. Native was invalidated at scan
    // start, so a successful no-op must still trigger queue rebase; otherwise
    // the resident native window would remain on the previous generation.
    // Emit only after all persistent scan state has committed successfully.
    if (!_queueInvalidationController.isClosed) {
      _queueInvalidationController.add(null);
      invalidationEmitted = true;
    }
    if (changedAny && !_tracksChangedController.isClosed) {
      _tracksChangedController.add(null);
    }
    _lastSuccessfulScanCompletedAt = DateTime.now();
    } catch (error) {
      // A caught failure in an ordinary incremental pass is not a crash. Its
      // cursor was never committed, so the next incremental pass replays the
      // affected MediaStore range. Do not leave the durable crash marker set
      // for this common transient case, otherwise every retry is promoted to
      // an O(N) identity recovery. Keep the marker when this pass was itself
      // an explicit/recovery reconciliation, because its stronger absence
      // proof may have been only partially committed. A process crash still
      // leaves the marker set because this catch block cannot run on crash.
      if (!interruptedSync &&
          !forceFullIdentityReconcile &&
          !effectiveReconcileDeletions) {
        try {
          await prefs.setBool(_syncInProgressKey, false);
        } catch (_) {
          // Preserve the original scan failure; if this cleanup write fails,
          // the marker remains conservative for the next process.
        }
      }
      // Native generation is monotonic. Once the new epoch was accepted at
      // scan start, never attempt to roll it back on a later scan failure:
      // doing so would split Dart and native generation state. The failed
      // attempt therefore consumes the epoch even when no Isar mutation
      // committed. A later scan can establish the next epoch normally.
      if (!invalidationEmitted && !_queueInvalidationController.isClosed) {
        // Native has already consumed the monotonic generation and therefore
        // considers its resident window stale. Even when the scan fails before
        // the first Isar mutation, explicitly trigger recovery against the
        // last committed Isar snapshot; otherwise the queue can remain stuck
        // at its physical window edge until an unrelated successful scan.
        _queueInvalidationController.add(null);
      }
      if (changedAny && !_tracksChangedController.isClosed) {
        _tracksChangedController.add(null);
      }
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> _readScanPage({
    required String volume,
    required int sinceTimestamp,
    required int untilTimestamp,
    required int cursorDateModifiedSeconds,
    required int cursorMediaStoreId,
    required int cursorGeneration,
    required int sinceGeneration,
    required int untilGeneration,
    required int limit,
  }) {
    return PlayerChannel.instance.scanLibraryPage(
      volume: volume,
      sinceTimestamp: sinceTimestamp,
      untilTimestamp: untilTimestamp,
      cursorDateModifiedSeconds: cursorDateModifiedSeconds,
      cursorMediaStoreId: cursorMediaStoreId,
      sinceGeneration: sinceGeneration,
      untilGeneration: untilGeneration,
      cursorGeneration: cursorGeneration,
      limit: limit,
    );
  }

  Future<bool> _persistScanBatch(List<Track> tracks, {bool invalidateDerivedCache = false}) async {
    var changed = false;
    await _isar.writeTxn(() async {
      // Resolve existing rows in one indexed query per volume instead of
      // issuing one Isar query for every track. The scan transaction remains
      // bounded to this batch.
      final existingByIdentity = <String, Track>{};
      final byVolume = <String, List<Track>>{};
      for (final track in tracks) {
        (byVolume[track.mediaStoreVolume] ??= <Track>[]).add(track);
      }
      for (final group in byVolume.entries) {
        // IMPORTANT: use the unique composite index (volume, mediaStoreId).
        // A filter() query here scans the entire Track collection for every
        // 500-row batch and becomes O(N²/B) on large libraries.
        final ids = group.value.map((t) => t.mediaStoreId).toSet().toList(growable: false);
        if (ids.isEmpty) continue;
        final rows = await _isar.tracks
            .where()
            .anyOf(
              ids,
              (q, id) =>
                  q.mediaStoreVolumeMediaStoreIdEqualTo(group.key, id),
            )
            .findAll();
        for (final row in rows) {
          existingByIdentity['${row.mediaStoreVolume}:${row.mediaStoreId}'] = row;
        }
      }

      // Only rows that are actually new or actually changed are written.
      // `changed` (used for invalidation/reporting) was previously computed
      // without gating persistence on it, so a full legacy re-enumeration
      // rewrote every already-identical row on every single scan. Track
      // per-row write necessity separately and pass only that subset to
      // putAll — full MediaStore enumeration is still required for legacy
      // deletion correctness, but enumerating for comparison does not
      // require persisting rows that compared equal.
      final rowsToWrite = <Track>[];
      for (final track in tracks) {
        final existing =
            existingByIdentity['${track.mediaStoreVolume}:${track.mediaStoreId}'];
        if (existing == null) {
          // The row will be inserted below. New rows are library mutations
          // too, so they must invalidate paging/queue consumers just like
          // metadata updates do.
          changed = true;
          rowsToWrite.add(track);
          continue;
        }
        track.id = existing.id;
        final sameObservableIdentity =
            existing.dateModified == track.dateModified &&
            existing.contentUri == track.contentUri &&
            existing.durationMs == track.durationMs &&
            existing.displayName == track.displayName &&
            existing.relativePath == track.relativePath &&
            existing.title == track.title &&
            existing.artist == track.artist &&
            existing.album == track.album;
        // A per-row generation is only available on API 30+. Treat
        // "unavailable on either side" as a neutral signal rather than a
        // mismatch: requiring it unconditionally would fail closed on
        // *every* legacy (API 24-29) track on *every* scan forever, since
        // both sides are always null there, forcing a full derived-cache
        // wipe and rewrite of the entire existing library on every
        // reconciliation even when nothing on disk changed. Where a
        // generation genuinely is available on both sides, an explicit
        // mismatch on top of otherwise-identical observable metadata is
        // still treated as untrustworthy — that combination is rare enough
        // (an edit that bumps generation without touching any observed
        // field) that failing closed there costs nothing on modern Android.
        final generationMismatch =
            existing.mediaStoreGenerationModified != null &&
            track.mediaStoreGenerationModified != null &&
            existing.mediaStoreGenerationModified !=
                track.mediaStoreGenerationModified;
        // Preserve derived state when the full observable metadata — content
        // URI, dateModified, duration, display name, path, title, artist,
        // album — matches exactly and no available generation contradicts
        // it. That combination is already the identity evidence the rest of
        // this codebase treats as strong (see the composite `sameObservableIdentity`
        // fields above); requiring an API-30+-only generation on top of it
        // for legacy devices provided no additional safety, only guaranteed
        // cache thrash.
        if (sameObservableIdentity && !generationMismatch && !invalidateDerivedCache) {
          track.embeddedLyricsText = existing.embeddedLyricsText;
          track.lyricsChecked = existing.lyricsChecked;
          track.lyricsCheckedAtMs = existing.lyricsCheckedAtMs;
          track.derivedCacheEpoch = existing.derivedCacheEpoch;
        } else {
          track.embeddedLyricsText = null;
          track.lyricsChecked = false;
          track.lyricsCheckedAtMs = 0;
          track.derivedCacheEpoch = _libraryGeneration;
        }
        final rowChanged =
            existing.dateModified != track.dateModified ||
            existing.contentUri != track.contentUri ||
            existing.durationMs != track.durationMs ||
            existing.displayName != track.displayName ||
            existing.title != track.title ||
            existing.artist != track.artist ||
            existing.album != track.album ||
            existing.relativePath != track.relativePath ||
            existing.mediaStoreGenerationModified != track.mediaStoreGenerationModified ||
            existing.derivedCacheEpoch != track.derivedCacheEpoch ||
            existing.folder != track.folder;
        changed = changed || rowChanged;
        if (rowChanged) rowsToWrite.add(track);
      }
      if (rowsToWrite.isNotEmpty) await _isar.tracks.putAll(rowsToWrite);
    });
    return changed;
  }

  /// Diffs local Track rows against MediaStore in bounded batches.
  ///
  /// The old implementation first materialized the entire MediaStore ID
  /// set and large local ID lists. This version walks Isar by primary-key
  /// ranges and asks MediaStore only about the current batch, keeping both
  /// the platform-channel payload and Dart working sets bounded.
  Future<void> _syncDeletions({
    required Set<String> currentVolumes,
    required Set<String> reconciliationVolumes,
    required Map<String, Map<String, dynamic>> currentVolumeStates,
    void Function()? onMutation,
    void Function()? onRescanRequested,
  }) async {
    const candidateChunkSize = _deletionSyncChunkSize;
    // Reconcile only volumes whose provider snapshot actually requires an
    // absence check. This preserves correctness while preventing a small SD
    // card mutation from traversing the entire primary-volume library.
    for (final volume in reconciliationVolumes) {
      if (!currentVolumes.contains(volume)) continue;
      var lastIsarId = 0;

      while (true) {
        // Read the identity pair from the same Track snapshot. Two independent
      // projection queries can observe different row sets between scans.
        final snapshot = await _isar.tracks
            .where()
          .idGreaterThan(lastIsarId)
          .filter()
          .mediaStoreVolumeEqualTo(volume)
          .limit(candidateChunkSize)
            .findAll();
        if (snapshot.isEmpty) break;

      // A temporarily absent removable volume is NOT a deletion. Keep its
      // rows in Isar until the volume is seen again; reappearance triggers
      // the bounded full-volume scan above. Only validate identities for
      // volumes that MediaStore currently exposes.
      final candidates = snapshot
          .where((t) => currentVolumes.contains(t.mediaStoreVolume))
          .map((t) => <String, dynamic>{
                'volume': t.mediaStoreVolume,
                'id': t.mediaStoreId,
                'dateModified': t.dateModified,
                'durationMs': t.durationMs,
                'displayName': t.displayName,
                'relativePath': t.relativePath,
                'title': t.title,
                'artist': t.artist,
                'album': t.album,
                'contentUri': t.contentUri,
                'generationModified': t.mediaStoreGenerationModified,
              })
          .toList(growable: false);
      final existing = await PlayerChannel.instance
          .findExistingMediaStoreIdentities(candidates);

      final staleIsarIds = <int>[];
      final staleIdentities = <String>[];
      for (var i = 0; i < snapshot.length; i++) {
        final track = snapshot[i];
        // Removable volumes that are currently absent are intentionally
        // skipped; they are unavailable, not deleted.
        if (!currentVolumes.contains(track.mediaStoreVolume)) continue;
        final key = '${track.mediaStoreVolume}:${track.mediaStoreId}';
        if (!existing.contains(key)) {
          staleIsarIds.add(track.id);
          staleIdentities.add(key);
        }
      }

      if (staleIdentities.isNotEmpty) {
        // Strict matching above is intentionally conservative for ordinary
        // reconciliation, but it cannot distinguish a deleted row from a
        // row whose MediaStore metadata changed since the last scan. Before
        // making a destructive Isar decision, perform an identity-only
        // existence check for the stale set. A present identity is still the
        // same media object even when dateModified/title/album/etc. changed.
        final stillPresent = await PlayerChannel.instance
            .findExistingMediaStoreObserverIdentities(staleIdentities);
        if (stillPresent.isNotEmpty) {
          final stillPresentSet = stillPresent.toSet();
          final filteredIds = <int>[];
          final filteredIdentities = <String>[];
          for (var i = 0; i < staleIdentities.length; i++) {
            if (stillPresentSet.contains(staleIdentities[i])) continue;
            filteredIds.add(staleIsarIds[i]);
            filteredIdentities.add(staleIdentities[i]);
          }
          staleIsarIds
            ..clear()
            ..addAll(filteredIds);
          staleIdentities
            ..clear()
            ..addAll(filteredIdentities);
        }
      }

      if (staleIsarIds.isNotEmpty) {
        final expectedRowsByIsarId = {
          for (final track in snapshot) track.id: track,
        };
        final beforeDeleteVolumes =
            (await PlayerChannel.instance.getMediaStoreVolumes()).toSet();
        if (beforeDeleteVolumes.length != currentVolumes.length ||
            !beforeDeleteVolumes.containsAll(currentVolumes)) {
          throw StateError('MediaStore volume set changed before deletion commit');
        }
        final deletedIdentities = <String>[];
        await _isar.writeTxn(() async {
          // Re-read each candidate inside the same write transaction that
          // performs the delete. This closes the Isar-side race where a
          // candidate snapshot could otherwise become stale between the
          // MediaStore validation and deleteAll(). Identity remains the
          // volume + MediaStore ID pair; never fall back to ID-only.
          final idsToDelete = <int>[];
          for (var i = 0; i < staleIsarIds.length; i++) {
            final current = await _isar.tracks.get(staleIsarIds[i]);
            if (current == null) continue;

            final expectedIdentity = staleIdentities[i];
            final currentIdentity =
                '${current.mediaStoreVolume}:${current.mediaStoreId}';
            if (currentIdentity != expectedIdentity) continue;

            final expectedRow = expectedRowsByIsarId[current.id];
            if (expectedRow == null ||
                current.dateModified != expectedRow.dateModified ||
                current.contentUri != expectedRow.contentUri ||
                current.durationMs != expectedRow.durationMs ||
                current.displayName != expectedRow.displayName ||
                current.relativePath != expectedRow.relativePath ||
                current.title != expectedRow.title ||
                current.artist != expectedRow.artist ||
                current.album != expectedRow.album ||
                current.mediaStoreGenerationModified !=
                    expectedRow.mediaStoreGenerationModified) {
              continue;
            }

            idsToDelete.add(current.id);
            deletedIdentities.add(expectedIdentity);
          }
          if (idsToDelete.isNotEmpty) {
            await _isar.tracks.deleteAll(idsToDelete);
          }
        });
        // The transaction has committed successfully at this point. Publish
        // the mutation only after commit; callbacks must never make an outer
        // generation/state decision based on uncommitted Isar work.
        if (deletedIdentities.isNotEmpty) {
          onMutation?.call();
        }

        if (deletedIdentities.isNotEmpty) {
          try {
            // Cross-store transactions cannot be made atomic: MediaStore and
            // Isar have independent commit boundaries. Always re-query the
            // identities after the destructive Isar transaction, even on
            // pre-R devices where MediaStore has no generation token. This is
            // the final compensation barrier for a delete/recreate that lands
            // between validation and the Isar commit.
            final afterDeleteStates =
                await PlayerChannel.instance.getMediaStoreVolumeStates();
            final snapshotStillStable =
                afterDeleteStates.length == currentVolumeStates.length &&
                currentVolumeStates.keys.every((volume) {
              final before = currentVolumeStates[volume];
              final after = afterDeleteStates[volume];
              return before != null && after != null &&
                  before['version'] == after['version'] &&
                  before['lifecycleGeneration'] == after['lifecycleGeneration'];
            });
            // This is deliberately an existence-only query. A recreated
            // MediaStore row may legitimately have different metadata from
            // the old row, so strict identity/metadata validation would
            // incorrectly classify the recreation as still absent.
            final recreated = await PlayerChannel.instance
                .findExistingMediaStoreObserverIdentities(deletedIdentities);
            final recreatedDeletedIdentities = recreated
                .where(deletedIdentities.contains)
                .toSet();
            if (recreatedDeletedIdentities.isNotEmpty) {
              // These identities are confirmed present again. Remove them from
              // the deletion publication before the fallible re-read/upsert so
              // a temporary MediaStore/Isar error cannot report a live track as
              // deleted to the playback queue. A later scan will repair a row
              // if the re-upsert itself fails.
              deletedIdentities.removeWhere(recreatedDeletedIdentities.contains);
              // The MediaStore row reappeared after the Isar deletion. Never
              // restore the old Track object because it may contain stale
              // derived state. Re-read the authoritative MediaStore identity
              // immediately and upsert the fresh row instead.
              final recreatedRows = <Map<String, dynamic>>[];
              for (final candidate in candidates) {
                final key = '${candidate['volume']}:${candidate['id']}';
                if (recreatedDeletedIdentities.contains(key)) {
                  recreatedRows.addAll(
                    await PlayerChannel.instance.scanLibraryIdentities(
                      volume: candidate['volume'] as String,
                      ids: <int>[candidate['id'] as int],
                    ),
                  );
                }
              }
              if (recreatedRows.isEmpty) {
                throw StateError(
                  'MediaStore identity reappeared but could not be re-read',
                );
              }
              final restored = recreatedRows
                  .map(_trackFromMediaStoreMap)
                  .where((t) => t.contentUri.isNotEmpty)
                  .toList(growable: false);
              if (restored.isEmpty) {
                throw StateError('Recreated MediaStore identities have no usable rows');
              }
              await _isar.writeTxn(() async {
                await _isar.tracks.putAll(restored);
              });
            }

            if (!snapshotStillStable) {
              // The deletion transaction and recreation compensation have
              // already committed. A version/lifecycle change means only the
              // absence snapshot is stale; it is not a failed scan. Request a
              // follow-up reconciliation instead of throwing and forcing the
              // entire scan through the global failure/backoff path.
              onRescanRequested?.call();
            }
          } finally {
            // The destructive Isar transaction has already committed. Publish
            // whatever identities remain deleted even when any compensation
            // query, re-read, re-upsert, or stability check throws.
            if (deletedIdentities.isNotEmpty &&
                !_tracksDeletedController.isClosed) {
              _tracksDeletedController.add(List.unmodifiable(deletedIdentities));
            }
          }
        }
      }

        lastIsarId = snapshot.last.id;
        if (snapshot.length < candidateChunkSize) break;
      }
    }
  }

  /// Total track count via an indexed `count()` — never loads a Track
  /// object just to size a list.
  Future<int> tracksCount() => _isar.tracks.where().count();

  /// One page of the full library, sorted by title. This — not a
  /// single `.findAll()` over the whole collection — is what backs the
  /// flat "Tracks" tab now, so it only ever holds as many rows in
  /// memory as have actually been scrolled to (see
  /// `TracksPagingNotifier` in `core/providers.dart`).
  Future<List<Track>> tracksPage({required int offset, required int limit}) {
    if (!_validPageArgs(offset: offset, limit: limit) || limit == 0) {
      return Future<List<Track>>.value(const <Track>[]);
    }
    return _isar.tracks
        .where()
        .anyTitle()
        .offset(offset)
        .limit(limit)
        .findAll();
  }

  /// One page of index-backed search results. Search uses a multi-entry
  /// word index and Unicode-aware word-prefix matching; it never uses
  /// collection-scale `.contains()` filters. Query terms are ORed, matching
  /// the broad title/artist/album search behavior while making each term an
  /// index lookup.
  Future<List<Track>> searchPage(
    String query, {
    required int offset,
    required int limit,
  }) {
    if (!_validPageArgs(offset: offset, limit: limit) || limit == 0) {
      return Future<List<Track>>.value(const <Track>[]);
    }
    final terms = _searchTerms(query);
    if (terms == null) return Future<List<Track>>.value(const <Track>[]);
    if (terms.isEmpty) {
      // Empty input is the unfiltered Tracks view; a non-empty input that
      // tokenizes to nothing (for example "!!!") is an empty search result.
      if (query.trim().isEmpty) {
        return tracksPage(offset: offset, limit: limit);
      }
      return Future<List<Track>>.value(const <Track>[]);
    }
    // Traverse the composite title/volume/ID index for canonical ordering,
    // then apply the indexed search predicate as a filter. This deliberately
    // avoids `sortByTitle()`: Isar sorts before offset/limit, so sorting a
    // broad search result could materialize millions of matching Tracks.
    // With `anyTitle()` the database streams the canonical order and only
    // returns the requested page after the search filter has been applied.
    return _isar.tracks
        .where()
        .anyTitle()
        .filter()
        .anyOf(
          terms,
          (q, term) => q.searchWordsElementStartsWith(term),
        )
        .offset(offset)
        .limit(limit)
        .findAll();
  }

  /// Count the same indexed search query uses; no Track objects are loaded.
  Future<int> searchCount(String query) {
    final terms = _searchTerms(query);
    if (terms == null) return Future<int>.value(0);
    if (terms.isEmpty) {
      return query.trim().isEmpty ? tracksCount() : Future<int>.value(0);
    }
    return _isar.tracks
        .where()
        .anyOf(
          terms,
          (q, term) => q.searchWordsElementStartsWith(term),
        )
        .count();
  }

  /// Fires one coalesced invalidation after repository-owned writes. Paging
  /// notifiers subscribe to this instead of Isar's raw `watchLazy()` so a
  /// large batched scan does not cause one UI reset per transaction.
  Stream<void> watchTracksChanged() => _tracksChangedController.stream;
  Stream<void> watchQueueInvalidations() => _queueInvalidationController.stream;

  /// Indexed point lookup for the currently-playing MediaStore identity.
  /// The volume is part of the identity because MediaStore IDs are only
  /// unique inside a volume.
  Future<Track?> trackByMediaStoreIdentity(String volume, int id) {
    if (volume.length > maxVolumeLength || id <= 0) {
      return Future<Track?>.value(null);
    }
    final normalizedVolume = volume.trim();
    if (normalizedVolume.isEmpty) {
      return Future<Track?>.value(null);
    }
    return _isar.tracks
        .where()
        .mediaStoreVolumeMediaStoreIdEqualTo(normalizedVolume, id)
        .findFirst();
  }

  /// FIX #5 — BOUNDED MEMORY FOR GROUP NAME PAGING.
  ///
  /// One page of distinct, sorted group names for [field] — the
  /// database-backed replacement for the old `distinctGroupNames()`,
  /// which returned every distinct name in the library as a single
  /// `List<String>` that callers then cached wholesale in Dart
  /// (`GroupsPagingNotifier._allNames`). That list was small relative
  /// to the full `Track` table, but it was still an unbounded-with-
  /// library-size cache: a library with a very large number of
  /// distinct albums/artists/folders grew it without limit.
  ///
  /// Each grouping property has its own value index. `where(distinct: true)`
  /// therefore traverses that index directly in sorted order and deduplicates
  /// at the index layer before offset/limit; only the requested property values
  /// are projected into Dart. This avoids a collection-wide sort for every
  /// group-name page on multi-million-track libraries.
  /// [GroupsPagingNotifier] (see `core/providers.dart`) calls this once
  /// per page the same way [tracksPage] is called once per page of the
  /// flat Tracks tab, and relies on `WindowedPagingNotifier`'s existing
  /// bounded-page eviction to cap how many pages of names are resident
  /// at once — exactly the same mechanism already used for [Track]
  /// pages, not a second bespoke cache.
  Future<List<String>> distinctGroupNamesPage(
    GroupField field, {
    required int offset,
    required int limit,
  }) {
    if (!_validPageArgs(offset: offset, limit: limit) || limit == 0) {
      return Future<List<String>>.value(const <String>[]);
    }
    return switch (field) {
      GroupField.album => _isar.tracks
          .where(distinct: true)
          .anyAlbum()
          .offset(offset)
          .limit(limit)
          .albumProperty()
          .findAll(),
      GroupField.artist => _isar.tracks
          .where(distinct: true)
          .anyArtist()
          .offset(offset)
          .limit(limit)
          .artistProperty()
          .findAll(),
      GroupField.folder => _isar.tracks
          .where(distinct: true)
          .anyFolder()
          .offset(offset)
          .limit(limit)
          .folderProperty()
          .findAll(),
    };
  }

  /// Total number of distinct group names for [field] — an indexed
  /// `count()` over the same distinct query [distinctGroupNamesPage]
  /// pages through, so the Albums/Artists/Folders tabs can size
  /// `ListView.builder` (`itemCount`) without ever loading a single
  /// name into memory just to count them.
  Future<int> distinctGroupNamesCount(GroupField field) {
    return switch (field) {
      GroupField.album =>
        _isar.tracks.where(distinct: true).anyAlbum().count(),
      GroupField.artist =>
        _isar.tracks.where(distinct: true).anyArtist().count(),
      GroupField.folder =>
        _isar.tracks.where(distinct: true).anyFolder().count(),
    };
  }

  /// Indexed count of tracks belonging to [name] under [field] — a
  /// single index-backed `count()` query, no rows deserialized.
  Future<int> countForGroup(GroupField field, String name) {
    if (name.trim().isEmpty) {
      return Future<int>.value(0);
    }
    return switch (field) {
      GroupField.album =>
        _isar.tracks.where().albumEqualTo(name).count(),
      GroupField.artist => _isar.tracks
          .where()
          .artistEqualTo(name)
          .count(),
      GroupField.folder => _isar.tracks
          .where()
          .folderEqualTo(name)
          .count(),
    };
  }

  /// FIX #3 — BOUNDED-MEMORY GROUP COUNTS FOR A PAGE OF GROUP NAMES.
  ///
  /// Given one page of distinct group [names] (as returned by
  /// [distinctGroupNamesPage]), resolves every name's track count.
  ///
  /// Isar 3.x has no native `GROUP BY ... COUNT(*)` for this query, so there
  /// is a genuine tradeoff between two axes: number of queries issued, and
  /// memory used per query. This deliberately chooses to bound memory,
  /// because a single `.anyOf()` union projecting the grouping property for
  /// every matching row (the alternative) has memory proportional to how
  /// many *tracks* share a name — a page containing just one very common
  /// name (for example an artist called "Various Artists") could then
  /// materialize a result as large as the entire library. Instead this
  /// issues one indexed `count()` per name — each is O(1) memory, since
  /// `count()` never materializes matching rows — run with a small
  /// concurrency window so total latency doesn't degrade to fully
  /// sequential. Total query count is bounded by `names.length`, which is
  /// itself bounded by [maxPageSize].
  ///
  /// Matches [countForGroup]'s case-insensitive equality semantics: a
  /// name's count includes every track whose [field] value matches that
  /// name case-insensitively, exactly like calling [countForGroup] once
  /// per name would. Returns 0 for a name with no matches rather than
  /// omitting it, so callers can always safely index the result by the
  /// exact name they passed in.
  Future<Map<String, int>> countsForGroups(
    GroupField field,
    List<String> names,
  ) async {
    if (names.isEmpty) return const {};
    if (names.length > maxPageSize) {
      throw ArgumentError.value(names.length, 'names', 'maximum is $maxPageSize');
    }
    // Count at the Isar layer. Do not replace indexed COUNT operations with
    // anyOf()+findAll(), which would deserialize a copy of the grouping
    // property for every matching Track — memory proportional to group
    // size, not page size. A small concurrency window avoids fully
    // sequential N+1 latency while keeping both DB work and Dart memory
    // bounded regardless of how large any single group is.
    const maxConcurrent = 4;
    // Deduplicate only exact input strings. Do not approximate Isar's
    // case-insensitive collation with Dart `toLowerCase()`: the latter is not
    // the database's defined equality relation for every Unicode string.
    // Exact duplicates are always safe to collapse; case variants are queried
    // independently and therefore cannot be accidentally aliased.
    final uniqueNames = names.toSet().toList(growable: false);

    final counts = <String, int>{for (final name in names) name: 0};
    for (var i = 0; i < uniqueNames.length; i += maxConcurrent) {
      final chunk = uniqueNames.skip(i).take(maxConcurrent).toList(growable: false);
      final results = await Future.wait(chunk.map((name) async {
        final count = switch (field) {
          GroupField.album => await _isar.tracks
              .where()
              .albumEqualTo(name)
              .count(),
          GroupField.artist => await _isar.tracks
              .where()
              .artistEqualTo(name)
              .count(),
          GroupField.folder => await _isar.tracks
              .where()
              .folderEqualTo(name)
              .count(),
        };
        return (name, count);
      }));
      for (final result in results) {
        counts[result.$1] = result.$2;
      }
    }
    return counts;
  }

  Future<List<Track>> tracksForGroupPage(
    GroupField field,
    String name, {
    required int offset,
    required int limit,
  }) {
    if (!_validPageArgs(offset: offset, limit: limit) || limit == 0 ||
        name.trim().isEmpty) {
      return Future<List<Track>>.value(const <Track>[]);
    }
    return switch (field) {
      GroupField.album => _isar.tracks
          .where()
          .anyTitle()
          .filter()
          .albumEqualTo(name)
          .offset(offset)
          .limit(limit)
          .findAll(),
      GroupField.artist => _isar.tracks
          .where()
          .anyTitle()
          .filter()
          .artistEqualTo(name)
          .offset(offset)
          .limit(limit)
          .findAll(),
      GroupField.folder => _isar.tracks
          .where()
          .anyTitle()
          .filter()
          .folderEqualTo(name)
          .offset(offset)
          .limit(limit)
          .findAll(),
    };
  }

  /// Returns the zero-based position of a MediaStore identity in the same
  /// deterministic title/volume/id order used by [tracksPage]. The title
  /// index is used for the large leading range; the smaller tie-break ranges
  /// are evaluated only inside the matching title range. This avoids the
  /// previous single full-collection `.filter().count()` for the common
  /// all-tracks/group position paths.
  Future<int?> allTracksPosition(String volume, int mediaStoreId) async {
    final current = await trackByMediaStoreIdentity(volume, mediaStoreId);
    if (current == null) return null;

    final titleBefore = await _isar.tracks
        .where()
        .titleLessThan(current.title)
        .count();

    final sameTitleVolumeBefore = await _isar.tracks
        .where()
        .titleEqualTo(current.title)
        .filter()
        .mediaStoreVolumeLessThan(current.mediaStoreVolume)
        .count();

    final sameTitleSameVolumeIdBefore = await _isar.tracks
        .where()
        .titleEqualTo(current.title)
        .filter()
        .mediaStoreVolumeEqualTo(current.mediaStoreVolume)
        .and()
        .mediaStoreIdLessThan(current.mediaStoreId)
        .count();

    return titleBefore + sameTitleVolumeBefore + sameTitleSameVolumeIdBefore;
  }

  Future<int?> searchPosition(
    String query,
    String volume,
    int mediaStoreId,
  ) async {
    final terms = _searchTerms(query);
    if (terms == null) return null;
    if (terms.isEmpty) {
      // Keep searchPage/searchCount/searchPosition semantically identical:
      // a blank query is the unfiltered Tracks result set. Punctuation-only
      // input also produces zero terms, but unlike blank input it is an
      // explicit non-empty query and therefore has an empty result set.
      if (query.trim().isNotEmpty) return null;
      return allTracksPosition(volume, mediaStoreId);
    }

    final current = await trackByMediaStoreIdentity(volume, mediaStoreId);
    if (current == null) return null;

    // The search predicate itself is index-backed. The title/volume/ID
    // ordering constraints remain ordinary filters applied to that already-
    // narrowed candidate set, so this no longer performs a whole-collection
    // `.contains()` pass for every position component.
    final matchesCurrent = await _isar.tracks
        .where()
        .anyOf(
          terms,
          (q, term) => q.searchWordsElementStartsWith(term),
        )
        .filter()
        .mediaStoreVolumeEqualTo(current.mediaStoreVolume)
        .mediaStoreIdEqualTo(mediaStoreId)
        .count();
    if (matchesCurrent == 0) return null;

    final titleBefore = await _isar.tracks
        .where()
        .anyOf(
          terms,
          (q, term) => q.searchWordsElementStartsWith(term),
        )
        .filter()
        .titleLessThan(current.title)
        .count();

    final sameTitleVolumeBefore = await _isar.tracks
        .where()
        .anyOf(
          terms,
          (q, term) => q.searchWordsElementStartsWith(term),
        )
        .filter()
        .titleEqualTo(current.title)
        .mediaStoreVolumeLessThan(current.mediaStoreVolume)
        .count();

    final sameTitleSameVolumeIdBefore = await _isar.tracks
        .where()
        .anyOf(
          terms,
          (q, term) => q.searchWordsElementStartsWith(term),
        )
        .filter()
        .titleEqualTo(current.title)
        .mediaStoreVolumeEqualTo(current.mediaStoreVolume)
        .mediaStoreIdLessThan(current.mediaStoreId)
        .count();

    return titleBefore + sameTitleVolumeBefore + sameTitleSameVolumeIdBefore;
  }

  Future<int?> groupPosition(
    GroupField field,
    String name,
    String volume,
    int mediaStoreId,
  ) async {
    if (name.trim().isEmpty) {
      return null;
    }
    final current = await trackByMediaStoreIdentity(volume, mediaStoreId);
    if (current == null) return null;

    final matchesCurrent = switch (field) {
      GroupField.album => await _isar.tracks
          .where()
          .mediaStoreVolumeMediaStoreIdEqualTo(current.mediaStoreVolume, mediaStoreId)
          .filter()
          .albumEqualTo(name)
          .count(),
      GroupField.artist => await _isar.tracks
          .where()
          .mediaStoreVolumeMediaStoreIdEqualTo(current.mediaStoreVolume, mediaStoreId)
          .filter()
          .artistEqualTo(name)
          .count(),
      GroupField.folder => await _isar.tracks
          .where()
          .mediaStoreVolumeMediaStoreIdEqualTo(current.mediaStoreVolume, mediaStoreId)
          .filter()
          .folderEqualTo(name)
          .count(),
    };
    if (matchesCurrent == 0) return null;

    Future<int> countBeforeWithGroup() async {
      final titleBefore = switch (field) {
        GroupField.album => await _isar.tracks
            .where()
            .titleLessThan(current.title)
            .filter()
            .albumEqualTo(name)
            .count(),
        GroupField.artist => await _isar.tracks
            .where()
            .titleLessThan(current.title)
            .filter()
            .artistEqualTo(name)
            .count(),
        GroupField.folder => await _isar.tracks
            .where()
            .titleLessThan(current.title)
            .filter()
            .folderEqualTo(name)
            .count(),
      };

      final sameTitleVolumeBefore = switch (field) {
        GroupField.album => await _isar.tracks
            .where()
            .titleEqualTo(current.title)
            .filter()
            .mediaStoreVolumeLessThan(current.mediaStoreVolume)
            .and()
            .albumEqualTo(name)
            .count(),
        GroupField.artist => await _isar.tracks
            .where()
            .titleEqualTo(current.title)
            .filter()
            .mediaStoreVolumeLessThan(current.mediaStoreVolume)
            .and()
            .artistEqualTo(name)
            .count(),
        GroupField.folder => await _isar.tracks
            .where()
            .titleEqualTo(current.title)
            .filter()
            .mediaStoreVolumeLessThan(current.mediaStoreVolume)
            .and()
            .folderEqualTo(name)
            .count(),
      };

      final sameTitleSameVolumeIdBefore = switch (field) {
        GroupField.album => await _isar.tracks
            .where()
            .titleEqualTo(current.title)
            .filter()
            .mediaStoreVolumeEqualTo(current.mediaStoreVolume)
            .and()
            .mediaStoreIdLessThan(current.mediaStoreId)
            .and()
            .albumEqualTo(name)
            .count(),
        GroupField.artist => await _isar.tracks
            .where()
            .titleEqualTo(current.title)
            .filter()
            .mediaStoreVolumeEqualTo(current.mediaStoreVolume)
            .and()
            .mediaStoreIdLessThan(current.mediaStoreId)
            .and()
            .artistEqualTo(name)
            .count(),
        GroupField.folder => await _isar.tracks
            .where()
            .titleEqualTo(current.title)
            .filter()
            .mediaStoreVolumeEqualTo(current.mediaStoreVolume)
            .and()
            .mediaStoreIdLessThan(current.mediaStoreId)
            .and()
            .folderEqualTo(name)
            .count(),
      };

      return titleBefore + sameTitleVolumeBefore + sameTitleSameVolumeIdBefore;
    }

    return countBeforeWithGroup();
  }

  String _encodeVolumeStates(Map<String, Map<String, dynamic>> states) =>
      jsonEncode(states);

  Map<String, Map<String, dynamic>> _decodeVolumeStates(String? encoded) {
    if (encoded == null || encoded.isEmpty) {
      return <String, Map<String, dynamic>>{};
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return <String, Map<String, dynamic>>{};
      final result = <String, Map<String, dynamic>>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        result[entry.key as String] =
            Map<String, dynamic>.from(entry.value as Map);
      }
      return result;
    } catch (_) {
      return <String, Map<String, dynamic>>{};
    }
  }

  String _encodeGenerationCursors(Map<String, int> cursors) =>
      jsonEncode(cursors);

  Map<String, int> _decodeGenerationCursors(String? encoded) {
    if (encoded == null || encoded.isEmpty) return <String, int>{};
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return <String, int>{};
      final result = <String, int>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String || entry.value is! num) continue;
        result[entry.key as String] = (entry.value as num).toInt();
      }
      return result;
    } catch (_) {
      return <String, int>{};
    }
  }

  /// Resolves and returns lyrics text for [track], caching it on the
  /// record so re-opening the lyrics view for the same track skips the
  /// native lookup entirely.
  ///
  /// Tries [track]'s embedded tags first (ID3 USLT/COMM, a Vorbis
  /// "LYRICS"/"UNSYNCEDLYRICS" comment, or the MP4 "©lyr" atom), then
  /// falls back to a sidecar `.lrc` file in the same folder — see
  /// `PlayerChannel.getLyrics` / native `SidecarLyricsResolver` for how
  /// that fallback stays correct under Android 13+ Scoped Storage.
  ///
  /// Returns null if neither source has lyrics for this track. The
  /// returned text may itself be `.lrc`-formatted — callers should run
  /// it through `LrcParser.parse` and fall back to a plain-text display
  /// if that yields no timed lines (see `LyricsScreen`).
  ///
  /// Both positive and negative lyrics results are cached briefly. A sidecar
  /// `.lrc` can be created or edited without changing the audio file's
  /// MediaStore timestamp, so a permanent positive cache would otherwise
  /// serve stale sidecar lyrics indefinitely. The short TTL bounds that
  /// staleness while still avoiding repeated metadata/SAF work on every view.
  static const _lyricsCacheTtl = Duration(minutes: 2);

  Future<String?> ensureLyrics(Track track, {bool forceRefresh = false}) {
    if (_disposed) {
      return Future<String?>.error(
        StateError('LibraryRepository is disposed'),
      );
    }
    final key = '${track.mediaStoreVolume}:${track.mediaStoreId}:gen=${track.mediaStoreGenerationModified ?? -1}:epoch=${track.derivedCacheEpoch}:${track.dateModified}:${track.contentUri}:${track.durationMs}:${track.displayName}:${track.relativePath ?? ''}:${track.title}:${track.artist}:${track.album}:force=$forceRefresh';
    final inFlight = _lyricsInFlight[key];
    if (inFlight != null) return inFlight;

    // Force-refresh has its own in-flight key so it can never join a
    // non-forced lookup that may return a cached lyrics value.
    final future = _ensureLyricsInternal(track, forceRefresh: forceRefresh);
    _lyricsInFlight[key] = future;
    future.then(
      (_) {
        _lyricsInFlight.remove(key);
      },
      onError: (Object _, StackTrace __) {
        _lyricsInFlight.remove(key);
      },
    );
    return future;
  }

  Future<String?> _ensureLyricsInternal(Track track, {required bool forceRefresh}) async {
    final cached = track.embeddedLyricsText;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cacheIsFresh = track.lyricsChecked &&
        track.lyricsCheckedAtMs > 0 &&
        nowMs >= track.lyricsCheckedAtMs &&
        nowMs - track.lyricsCheckedAtMs < _lyricsCacheTtl.inMilliseconds;
    if (!forceRefresh && cacheIsFresh) return cached;

    final text = await PlayerChannel.instance.getLyrics(
      track.contentUri,
      mediaStoreVolume: track.mediaStoreVolume,
      relativePath: track.relativePath,
      displayName: track.displayName,
    );

    // Disposal may race the native lookup. Never touch the closed Isar
    // instance after the repository has been disposed; the native result is
    // still valid for the Track snapshot supplied by the caller.
    if (_disposed) return text;

    await _isar.writeTxn(() async {
      if (_disposed) return;
      final current = await _isar.tracks
          .where()
          .mediaStoreVolumeMediaStoreIdEqualTo(
            track.mediaStoreVolume,
            track.mediaStoreId,
          )
          .findFirst();
      if (current == null ||
          current.dateModified != track.dateModified ||
          current.contentUri != track.contentUri ||
          current.durationMs != track.durationMs ||
          current.displayName != track.displayName ||
          current.relativePath != track.relativePath ||
          current.title != track.title ||
          current.artist != track.artist ||
          current.album != track.album ||
          current.mediaStoreGenerationModified != track.mediaStoreGenerationModified ||
          current.derivedCacheEpoch != track.derivedCacheEpoch) {
        // The native lookup completed for an older row version. Do not persist
        // that derived result against the newer row, but the caller requested
        // the lyrics text itself, which is still valid for the Track snapshot
        // it supplied.
        return;
      }
      current.embeddedLyricsText = text;
      current.lyricsChecked = true;
      current.lyricsCheckedAtMs = nowMs;
      await _isar.tracks.put(current);
    });
    return text;
  }
}

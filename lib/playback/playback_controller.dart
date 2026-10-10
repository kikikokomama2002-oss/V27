import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import '../core/generation_gate.dart';
import '../data/repositories/library_repository.dart';
import 'player_channel.dart';
import 'playback_state.dart';
import 'queue_spec.dart';

/// Number of tracks fetched on either side of the tapped track for a
/// new queue's initial native window (FIX #2). Skewed forward (most
/// listening moves forward via Next / natural playback) while still
/// giving Previous some immediate headroom without a round-trip.
const _initialWindowBefore = 20;
const _initialWindowAfter = 80;
const _savedQueueSpecKey = 'active_queue_spec_v1';
const _savedQueueContextIdKey = 'active_queue_context_id_v1';
const _pendingQueueSpecKey = 'pending_queue_spec_v1';
const _pendingQueueContextIdKey = 'pending_queue_context_id_v1';
const _pendingQueueAtKey = 'pending_queue_saved_at_ms_v1';
const _savedQueueAtKey = 'active_queue_saved_at_ms_v1';
const _queueRestoreMaxAge = Duration(hours: 24);
final _queueGenerationEpoch = 'epoch-${DateTime.now().microsecondsSinceEpoch}-${Object().hashCode}';

class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> protect<T>(Future<T> Function() action) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = previous.then<void>((_) => release.future,
        onError: (Object _, StackTrace __) => release.future);
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      if (!release.isCompleted) release.complete();
    }
  }
}

/// Owns the live [PlaybackState] and exposes high-level transport intents
/// (playQueue, togglePlayPause, seek, next, previous) used by the UI.
/// Listens to the native EventChannel stream and republishes state
/// updates into Riverpod so any widget can watch it.
///
/// FIX #2 — QUERY-BACKED PLAYBACK QUEUE:
///
/// [playQueue] no longer takes a `List<Track>` — it takes a [QueueSpec]
/// (the query the track was tapped from: all tracks / a search / one
/// album-artist-folder group) plus a logical [startIndex] into that
/// query's full, ordered result set. Only a small initial window of
/// [Track]s around [startIndex] is ever sent to native — see
/// `PlayerChannel.setQueueContext`.
///
/// As the native sliding-window queue controller (Kotlin `PlayerHolder`)
/// plays toward either edge of what it's been given, it calls back into
/// Dart via [PlayerChannel.setNativeCallHandler]'s `requestQueuePage`,
/// which [_handleNativeCall] resolves by re-running [QueueSpec.resolvePage]
/// against the CURRENT [_activeSpec] — the same indexed
/// `offset().limit()` Isar query the windowed UI pagers use, not a
/// second copy of the library held anywhere in Dart. A 10,000-track
/// "all tracks" queue therefore costs Dart the same handful of
/// resident [Track] objects as a 60-track one, exactly like the UI
/// list itself.
class PlaybackController extends StateNotifier<PlaybackState> {
  PlaybackController(this._ref) : super(const PlaybackState()) {
    _sub = PlayerChannel.instance.stateStream.listen((s) => state = s);
    PlayerChannel.instance.setNativeCallHandler(_handleNativeCall);
    // libraryRepositoryProvider depends on isarProvider's async open, so
    // it may still be null at construction time — watch for it to
    // become available rather than reading it once, same reasoning as
    // the paging notifiers in core/providers.dart.
    _ref.listen<LibraryRepository?>(
      libraryRepositoryProvider,
      (previous, next) {
        if (next == null || previous != null) return;
        _deletionsSub = next.tracksDeleted.listen(_onTracksDeleted);
        _changesSub = next.tracksChanged.listen((_) => _onTracksChanged());
        _queueInvalidationsSub =
            next.queueInvalidations.listen((_) => _onTracksChanged());
        unawaited(_restoreQueueContext());
      },
      fireImmediately: true,
    );
  }

  final Ref _ref;
  late final StreamSubscription<PlaybackState> _sub;
  StreamSubscription<List<String>>? _deletionsSub;
  StreamSubscription<void>? _changesSub;
  StreamSubscription<void>? _queueInvalidationsSub;

  QueueSpec? _activeSpec;
  int _contextCounter = 0;
  final GenerationGate _queueGenerationGate = GenerationGate();
  String? _activeContextId;
  final _queueInstallMutex = _AsyncMutex();

  // SharedPreferences is the crash-recovery state machine for queue requests.
  // Serialize all pending-descriptor mutations so a newer playQueue() can
  // invalidate an older descriptor even when the newer request exits early.
  final _queuePrefsMutex = _AsyncMutex();

  /// FIX #4 — request ids (from native's `requestId` arg — see
  /// `MethodChannelQueuePageProvider`) currently being handled by
  /// [_handleNativeCall]'s `requestQueuePage` case. Only ever holds ids
  /// for genuinely in-flight requests — added right before the DB
  /// query starts, removed in a `finally` once it finishes — so a
  /// `cancelQueuePage` notice that arrives for an id NOT in here (the
  /// matching request already finished, or — impossible in practice
  /// given the two calls share one ordered channel — hasn't arrived
  /// yet) is simply dropped rather than remembered forever. This is
  /// what keeps [_cancelledRequestIds] bounded.
  final Set<int> _pendingRequestIds = {};

  /// Ids from [_pendingRequestIds] that received a `cancelQueuePage`
  /// notice while still in flight — checked once the DB read finishes
  /// so a cancelled request can skip its second query and building a
  /// result payload nothing on the native side will read (see
  /// `MethodChannelQueuePageProvider.requestPage`'s
  /// `invokeOnCancellation`). Isar's `findAll()` can't be aborted
  /// mid-query, so this can't skip work already started, only work not
  /// yet done.
  final Set<int> _cancelledRequestIds = {};

  LibraryRepository? get _repo => _ref.read(libraryRepositoryProvider);

  /// Establishes [spec] (all tracks / a search / one group) as the
  /// active queue and starts playback at its logical [startIndex] —
  /// see class doc for how native gets the rest of the queue without
  /// Dart ever holding [spec]'s complete track list.
  Future<void> playQueue(
    QueueSpec spec, {
    required int startIndex,
    required String startVolume,
    required int startMediaStoreId,
  }) async {
    final requestGeneration = _queueGenerationGate.begin();
    final prefs = await SharedPreferences.getInstance();

    // A newer request supersedes any older crash-recovery descriptor
    // immediately, even if this request later exits before it can resolve a
    // queue. The same mutex is used by the older request when it attempts to
    // write its descriptor, so it cannot reintroduce stale state after this
    // invalidation.
    await _queuePrefsMutex.protect<void>(() async {
      if (!_queueGenerationGate.isCurrent(requestGeneration)) return;
      await prefs.remove(_pendingQueueSpecKey);
      await prefs.remove(_pendingQueueContextIdKey);
      await prefs.remove(_pendingQueueAtKey);
    });
    if (!_queueGenerationGate.isCurrent(requestGeneration)) return;

    final repo = _repo;
    if (repo == null) return;

    List<Map<String, dynamic>> window = const [];
    var totalCount = 0;
    var clampedStart = 0;
    var windowStart = 0;
    var snapshotGeneration = 0;

    // The UI index is only a hint: the tapped Track identity is stable even
    // if inserts/deletes happen while the async count/page calls are running.
    // Resolve the position again immediately before loading the initial window
    // and verify that the returned window still contains that identity. A
    // bounded retry handles a mutation occurring between those two queries.
    for (var attempt = 0; attempt < 3; attempt++) {
      snapshotGeneration = await repo.waitForStableSnapshot();
      if (!_queueGenerationGate.isCurrent(requestGeneration)) return;
      if (snapshotGeneration != repo.libraryGeneration || repo.scanInProgress) continue;
      totalCount = await spec.resolveCount(repo);
      if (!_queueGenerationGate.isCurrent(requestGeneration)) return;
      if (totalCount == 0) return;
      final resolvedPosition = await spec.resolvePosition(
        repo,
        volume: startVolume,
        mediaStoreId: startMediaStoreId,
      );
      if (!_queueGenerationGate.isCurrent(requestGeneration)) return;
      if (resolvedPosition == null) return;
      clampedStart = resolvedPosition.clamp(0, totalCount - 1).toInt();
      windowStart =
          (clampedStart - _initialWindowBefore).clamp(0, totalCount - 1).toInt();
      final windowEnd =
          (clampedStart + _initialWindowAfter + 1).clamp(0, totalCount).toInt();
      final candidate = await spec.resolvePage(
        repo,
        offset: windowStart,
        limit: windowEnd - windowStart,
      );
      if (!_queueGenerationGate.isCurrent(requestGeneration)) return;

      // The count query and page query are separate Isar operations. If the
      // library changed between them, do not install a window paired with an
      // obsolete logical count. A bounded retry re-resolves position/page
      // against the newer dataset.
      final verifiedCount = await spec.resolveCount(repo);
      if (!_queueGenerationGate.isCurrent(requestGeneration)) return;
      if (snapshotGeneration != repo.libraryGeneration || repo.scanInProgress) {
        continue;
      }
      if (verifiedCount != totalCount) {
        totalCount = verifiedCount;
        if (totalCount <= 0) return;
        continue;
      }

      final targetOffset = clampedStart - windowStart;
      if (targetOffset >= 0 && targetOffset < candidate.length) {
        final target = candidate[targetOffset];
        final targetVolume = target['volume'] as String?;
        final targetId = (target['id'] as num?)?.toInt();
        if (targetVolume == startVolume && targetId == startMediaStoreId) {
          window = candidate;
          break;
        }
      }
      if (attempt == 2) return;
    }
    if (window.isEmpty) return;

    _contextCounter++;
    final contextId = 'q$_contextCounter';
    final installLibraryGeneration = repo.libraryGeneration;
      if (installLibraryGeneration != repo.libraryGeneration) {
        throw StateError('Library changed before queue installation');
      }

    if (!_queueGenerationGate.isCurrent(requestGeneration)) return;

    // Two-phase persistence closes the crash window between native queue
    // installation and SharedPreferences. The write itself is serialized with
    // the supersession/clear path above, so an obsolete request cannot publish
    // its descriptor after a newer request has invalidated it.
    final pendingWritten = await _queuePrefsMutex.protect<bool>(() async {
      if (!_queueGenerationGate.isCurrent(requestGeneration)) return false;
      await prefs.setString(_pendingQueueSpecKey, jsonEncode(spec.toMap()));
      await prefs.setString(_pendingQueueContextIdKey, contextId);
      await prefs.setInt(_pendingQueueAtKey, DateTime.now().millisecondsSinceEpoch);
      return _queueGenerationGate.isCurrent(requestGeneration);
    });
    if (!pendingWritten) return;

    try {
      await _queueInstallMutex.protect<void>(() async {
        if (!_queueGenerationGate.isCurrent(requestGeneration)) return;
        // Publish the logical descriptor before native installation, but only
        // while holding the install mutex. This makes Dart's descriptor and
        // the native queue transition one serialized state change: a newer
        // playQueue cannot observe an older native queue with a newer Dart
        // descriptor, nor can an older request commit after a newer request.
        _activeSpec = spec;
        _activeContextId = contextId;
        try {
          if (installLibraryGeneration != repo.libraryGeneration) {
        throw StateError('Library changed before native queue installation');
      }

      await PlayerChannel.instance.setQueueContext(
            contextId: contextId,
            queueGeneration: requestGeneration,
            queueGenerationEpoch: _queueGenerationEpoch,
            libraryGeneration: installLibraryGeneration,
            spec: spec.toMap(),
            totalCount: totalCount,
            startIndex: clampedStart,
            initialWindow: window,
            windowStartIndex: windowStart,
            startItemIdentity: '$startVolume:$startMediaStoreId',
          );
          if (!_queueGenerationGate.isCurrent(requestGeneration)) {
            if (_activeContextId == contextId) {
              _activeSpec = null;
              _activeContextId = null;
            }
            // The native install may already have succeeded before this Dart
            // generation became stale. Clear only that exact native context;
            // the native side refuses to clear a newer queue.
            await PlayerChannel.instance.clearQueueContextIfMatches(contextId);
            return;
          }
        } catch (_) {
          if (_activeContextId == contextId) {
            _activeSpec = null;
            _activeContextId = null;
          }
          await PlayerChannel.instance.clearQueueContextIfMatches(contextId);
          rethrow;
        }
      });
    } catch (_) {
      await _queuePrefsMutex.protect<void>(() async {
        if (prefs.getString(_pendingQueueContextIdKey) == contextId) {
          await prefs.remove(_pendingQueueSpecKey);
          await prefs.remove(_pendingQueueContextIdKey);
          await prefs.remove(_pendingQueueAtKey);
        }
      });
      rethrow;
    }

    await _queuePrefsMutex.protect<void>(() async {
      if (!_queueGenerationGate.isCurrent(requestGeneration)) return;
      await prefs.setString(_savedQueueSpecKey, jsonEncode(spec.toMap()));
      if (!_queueGenerationGate.isCurrent(requestGeneration)) return;
      await prefs.setString(_savedQueueContextIdKey, contextId);
      if (!_queueGenerationGate.isCurrent(requestGeneration)) return;
      await prefs.setInt(_savedQueueAtKey, DateTime.now().millisecondsSinceEpoch);
      if (prefs.getString(_pendingQueueContextIdKey) == contextId) {
        await prefs.remove(_pendingQueueSpecKey);
        await prefs.remove(_pendingQueueContextIdKey);
        await prefs.remove(_pendingQueueAtKey);
      }
    });
  }

  Future<void> _restoreQueueContext() async {
    final restoreGeneration = _queueGenerationGate.begin();
    final prefs = await SharedPreferences.getInstance();
    if (_activeContextId != null) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final savedAt = prefs.getInt(_savedQueueAtKey);
    final pendingAt = prefs.getInt(_pendingQueueAtKey);
    final savedExpired = savedAt != null &&
        nowMs - savedAt > _queueRestoreMaxAge.inMilliseconds;
    final pendingExpired = pendingAt != null &&
        nowMs - pendingAt > _queueRestoreMaxAge.inMilliseconds;

    final nativeContextId = await PlayerChannel.instance.getQueueContextId();

    // Do NOT expire persisted descriptors before checking whether the native
    // queue survived. Native ExoPlayer and Dart/SharedPreferences have
    // different lifetimes; if native still owns this context, its matching
    // logical descriptor is required for page refills even when its timestamp
    // is older than the normal restore TTL. Only apply TTL cleanup when there
    // is no surviving native queue to recover.
    if (nativeContextId == null || nativeContextId.isEmpty) {
      await _queuePrefsMutex.protect<void>(() async {
        if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
        if (savedExpired) {
          await prefs.remove(_savedQueueSpecKey);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_savedQueueContextIdKey);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_savedQueueAtKey);
        }
        if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
        if (pendingExpired) {
          await prefs.remove(_pendingQueueSpecKey);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_pendingQueueContextIdKey);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_pendingQueueAtKey);
        }
      });
      if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
    }
    final pendingContext = prefs.getString(_pendingQueueContextIdKey);
    final pendingSpec = prefs.getString(_pendingQueueSpecKey);
    final savedContext = prefs.getString(_savedQueueContextIdKey);
    final savedSpec = prefs.getString(_savedQueueSpecKey);

    // Native queue survived across engine recreation. Recover and publish the
    // logical descriptor before triggering any native rebase. Native rebase can
    // call requestQueuePage asynchronously, so _activeSpec must already be
    // visible to that callback.
    if (nativeContextId != null && nativeContextId.isNotEmpty) {
      String? encoded;
      if (pendingContext == nativeContextId && pendingSpec != null) {
        if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
        encoded = pendingSpec;
        final committed = await _queuePrefsMutex.protect<bool>(() async {
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return false;
          await prefs.setString(_savedQueueSpecKey, pendingSpec);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return false;
          await prefs.setString(_savedQueueContextIdKey, nativeContextId);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return false;
          await prefs.setInt(_savedQueueAtKey, DateTime.now().millisecondsSinceEpoch);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return false;
          await prefs.remove(_pendingQueueSpecKey);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return false;
          await prefs.remove(_pendingQueueContextIdKey);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return false;
          await prefs.remove(_pendingQueueAtKey);
          return true;
        });
        if (!committed) return;
      } else if (savedContext == nativeContextId && savedSpec != null) {
        encoded = savedSpec;
      } else {
        // A live native queue with no matching logical descriptor is not a
        // recoverable state. Keeping it alive would leave Dart unable to
        // service the next page request once the currently loaded window is
        // exhausted. Fail closed by clearing that native context instead of
        // leaving a live-but-unrecoverable queue behind.
        try {
          await PlayerChannel.instance.clearQueueContextIfMatches(nativeContextId);
        } catch (_) {
          // Best effort; the in-memory Dart descriptor is still absent, so a
          // later restore attempt will re-check the native context.
        }
        await _queuePrefsMutex.protect<void>(() async {
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_pendingQueueSpecKey);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_pendingQueueContextIdKey);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_pendingQueueAtKey);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_savedQueueSpecKey);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_savedQueueContextIdKey);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_savedQueueAtKey);
        });
        return;
      }

      QueueSpec? spec;
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is Map) {
          spec = QueueSpec.fromMap(decoded);
        }
      } catch (_) {
        spec = null;
      }
      final repo = _repo;
      if (spec == null || repo == null) {
        // A native queue survived, but its logical descriptor is corrupt or
        // no longer decodable. Keeping that native window alive would create
        // a live queue that Dart can never refill. Fail closed exactly as we
        // do for a missing descriptor.
        try {
          await PlayerChannel.instance.clearQueueContextIfMatches(nativeContextId);
        } catch (_) {}
        await _queuePrefsMutex.protect<void>(() async {
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_pendingQueueSpecKey);
          await prefs.remove(_pendingQueueContextIdKey);
          await prefs.remove(_pendingQueueAtKey);
          await prefs.remove(_savedQueueSpecKey);
          await prefs.remove(_savedQueueContextIdKey);
          await prefs.remove(_savedQueueAtKey);
        });
        _activeSpec = null;
        _activeContextId = null;
        return;
      }
      if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;

        try {
        // Publish before scan/refresh so the native delayed rebase can safely
        // obtain a page from the restored logical queue.
        _activeSpec = spec;
        _activeContextId = nativeContextId;

        await repo.scanAndPersist();
        if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
        await PlayerChannel.instance.refreshQueueAfterLibraryChange();
        if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;

        final currentCount = await spec.resolveCount(repo);
        if (currentCount > 0) {
          final firstPage = await spec.resolvePage(repo, offset: 0, limit: 1);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          if (firstPage.isEmpty) return;
        }
        final suffix = int.tryParse(
          nativeContextId.startsWith('q') ? nativeContextId.substring(1) : '',
        );
        if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
        if (suffix != null && suffix > _contextCounter) _contextCounter = suffix;
      } catch (_) {
        // The native queue survived, so its logical recovery descriptor is
        // still valid even when reconciliation fails transiently. Keep both
        // the active in-memory descriptor and the persisted descriptor so a
        // later retry can reconcile/recover the queue. Only a newer queue
        // request may invalidate this state.
        return;
      }
      return;
    }

    // Native queue is gone, but a valid persisted logical descriptor remains.
    // Reconstruct a fresh bounded native window instead of silently discarding
    // the saved queue. Start at logical index 0 because native playback
    // position cannot survive a destroyed ExoPlayer instance.
    final encoded = pendingSpec ?? savedSpec;
    if (encoded == null) return;
    final repo = _repo;
    if (repo == null) return;

    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return;
      final spec = QueueSpec.fromMap(decoded);
      if (spec == null) return;
      final restoreLibraryGeneration = await repo.waitForStableSnapshot();
      if (!_queueGenerationGate.isCurrent(restoreGeneration) ||
          restoreLibraryGeneration != repo.libraryGeneration ||
          repo.scanInProgress) return;
      final totalCount = await spec.resolveCount(repo);
      if (!_queueGenerationGate.isCurrent(restoreGeneration) ||
          restoreLibraryGeneration != repo.libraryGeneration ||
          repo.scanInProgress) return;
      if (totalCount <= 0) {
        await _queuePrefsMutex.protect<void>(() async {
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_savedQueueSpecKey);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_savedQueueContextIdKey);
          if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
          await prefs.remove(_savedQueueAtKey);
        });
        return;
      }
      final limit = totalCount.clamp(1, _initialWindowAfter + 1).toInt();
      final window = await spec.resolvePage(repo, offset: 0, limit: limit);
      if (!_queueGenerationGate.isCurrent(restoreGeneration) ||
          restoreLibraryGeneration != repo.libraryGeneration ||
          repo.scanInProgress) return;
      if (window.isEmpty) return;
      final first = window.first;
      final startVolume = first['volume'] as String?;
      final startId = (first['id'] as num?)?.toInt();
      if (startVolume == null || startId == null) return;

      _contextCounter++;
      final newContextId = 'q$_contextCounter';
      if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
      await PlayerChannel.instance.setQueueContext(
        contextId: newContextId,
        queueGeneration: restoreGeneration,
        queueGenerationEpoch: _queueGenerationEpoch,
        libraryGeneration: restoreLibraryGeneration,
        spec: spec.toMap(),
        totalCount: totalCount,
        startIndex: 0,
        initialWindow: window,
        windowStartIndex: 0,
        startItemIdentity: '$startVolume:$startId',
        // Restoring a persisted queue must not start playback on app launch.
        autoPlay: false,
      );
      if (!_queueGenerationGate.isCurrent(restoreGeneration)) return;
      _activeSpec = spec;
      _activeContextId = newContextId;
      final committed = await _queuePrefsMutex.protect<bool>(() async {
        if (!_queueGenerationGate.isCurrent(restoreGeneration)) return false;
        await prefs.setString(_savedQueueSpecKey, jsonEncode(spec.toMap()));
        if (!_queueGenerationGate.isCurrent(restoreGeneration)) return false;
        await prefs.setString(_savedQueueContextIdKey, newContextId);
        if (!_queueGenerationGate.isCurrent(restoreGeneration)) return false;
        await prefs.setInt(_savedQueueAtKey, DateTime.now().millisecondsSinceEpoch);
        if (!_queueGenerationGate.isCurrent(restoreGeneration)) return false;
        await prefs.remove(_pendingQueueSpecKey);
        if (!_queueGenerationGate.isCurrent(restoreGeneration)) return false;
        await prefs.remove(_pendingQueueContextIdKey);
        if (!_queueGenerationGate.isCurrent(restoreGeneration)) return false;
        await prefs.remove(_pendingQueueAtKey);
        return true;
      });
      if (!committed) {
        if (_activeContextId == newContextId) {
          _activeSpec = null;
          _activeContextId = null;
        }
        return;
      }
    } catch (_) {
      // Keep the persisted descriptor for a later retry; a failed native
      // reconstruction must never turn a valid saved queue into success.
    }
  }

  /// Handles native→Dart calls from the sliding-window queue controller:
  /// `requestQueuePage`, made when playback nears either edge of the
  /// currently loaded native window and needs more of [_activeSpec]'s
  /// logical result set, and `cancelQueuePage` (FIX #4), a
  /// fire-and-forget notice that a previously made `requestQueuePage`
  /// call is no longer wanted because the native coroutine awaiting it
  /// was cancelled.
  Future<void> _scanFromNativeObserver(
    LibraryRepository repo,
    List<String> identities,
    bool unknown,
  ) async {
    try {
      await repo.handleMediaStoreChanged(
        identities: identities,
        unknown: unknown,
      );
    } catch (_) {
      // Native observer events are best-effort. A transient provider failure
      // must not become an unhandled Future error or permanently consume the
      // reconciliation request. Give the provider a short recovery interval
      // and retry once; LibraryRepository still coalesces concurrent scans.
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        await repo.scanAndPersist(
          forceFullIdentityReconcile: unknown || identities.isNotEmpty,
        );
      } catch (_) {
        // Leave the persistent cursor untouched; a later observer/manual
        // scan can retry from the last successful snapshot.
      }
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'mediaStoreChanged':
        final repo = _repo;
        if (repo != null) {
          final rawArgs = call.arguments;
          final isMap = rawArgs is Map;
          final rawIdentities = isMap ? rawArgs['identities'] : null;
          final rawUnknown = isMap ? rawArgs['unknown'] : null;

          // Native observer payloads are trusted only when their complete
          // shape is valid. Silently dropping malformed list entries could
          // turn a partial event into a falsely-targeted event and lose the
          // recovery path. Any malformed payload is therefore escalated to
          // an explicit unknown event.
          final identitiesValid = rawIdentities is List &&
              rawIdentities.every((entry) {
                if (entry is! String) return false;
                final separator = entry.indexOf(':');
                if (separator <= 0 || separator >= entry.length - 1) return false;
                final volume = entry.substring(0, separator).trim();
                final id = int.tryParse(entry.substring(separator + 1));
                return volume.isNotEmpty && id != null && id > 0;
              });
          final unknownValid = rawUnknown is bool;
          final payloadValid = isMap && identitiesValid && unknownValid;
          final identities = payloadValid
              ? List<String>.unmodifiable(rawIdentities.cast<String>())
              : const <String>[];
          final unknown = !payloadValid || rawUnknown == true;
          unawaited(_scanFromNativeObserver(repo, identities, unknown));
        }
        return null;

      case 'requestQueuePage':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final contextId = args['contextId'] as String?;
        final offset = (args['offset'] as num?)?.toInt() ?? 0;
        final limit = (args['limit'] as num?)?.toInt() ?? 0;
        final requestId = (args['requestId'] as num?)?.toInt();
        if (offset < 0 || limit <= 0 || limit > 240) {
          return {'items': const <Map<String, dynamic>>[], 'totalCount': 0, 'startIndex': offset, 'libraryGeneration': _repo?.libraryGeneration ?? 0};
        }

        // A response for a queue that's since been replaced — the
        // native side already discards these by contextId too, but
        // avoid doing a wasted DB query for it here as well.
        if (contextId != _activeContextId || _activeSpec == null) {
          return {'items': const <Map<String, dynamic>>[], 'totalCount': 0, 'libraryGeneration': _repo?.libraryGeneration ?? 0};
        }
        final repo = _repo;
        if (repo == null) {
          return {'items': const <Map<String, dynamic>>[], 'totalCount': 0, 'libraryGeneration': _repo?.libraryGeneration ?? 0};
        }

        if (requestId != null) _pendingRequestIds.add(requestId);
        try {
          final spec = _activeSpec!;
          // Isar does not expose a snapshot spanning multiple async query
          // calls. Read the page twice and only return it when the ordered
          // identity span is stable across both reads. This closes the
          // remaining window where an insert/delete/re-sort between a page
          // query and the native append could otherwise shift the logical
          // offset without necessarily overlapping the loaded window.
          for (var attempt = 0; attempt < 2; attempt++) {
            await repo.waitForStableSnapshot();
            if (requestId != null && _cancelledRequestIds.contains(requestId)) {
              return {'items': const <Map<String, dynamic>>[], 'totalCount': 0, 'libraryGeneration': repo.libraryGeneration};
            }
            final requestLibraryGeneration = repo.libraryGeneration;
            final page =
                await spec.resolvePage(repo, offset: offset, limit: limit);

            if (requestId != null && _cancelledRequestIds.contains(requestId)) {
              return {'items': const <Map<String, dynamic>>[], 'totalCount': 0, 'libraryGeneration': _repo?.libraryGeneration ?? 0};
            }

            final totalCount = await spec.resolveCount(repo);
            if (repo.scanInProgress || requestLibraryGeneration != repo.libraryGeneration) continue;
            if (totalCount < offset) {
              if (attempt == 1) {
                return {'items': const <Map<String, dynamic>>[], 'totalCount': totalCount, 'startIndex': offset, 'libraryGeneration': _repo?.libraryGeneration ?? 0};
              }
              continue;
            }

            final verification =
                await spec.resolvePage(repo, offset: offset, limit: limit);
            if (requestId != null && _cancelledRequestIds.contains(requestId)) {
              return {'items': const <Map<String, dynamic>>[], 'totalCount': totalCount, 'startIndex': offset, 'libraryGeneration': _repo?.libraryGeneration ?? 0};
            }

            bool sameIdentitySpan(
              List<Map<String, dynamic>> a,
              List<Map<String, dynamic>> b,
            ) {
              if (a.length != b.length) return false;
              for (var i = 0; i < a.length; i++) {
                if (a[i]['volume'] != b[i]['volume'] ||
                    a[i]['id'] != b[i]['id']) {
                  return false;
                }
              }
              return true;
            }

            if (sameIdentitySpan(page, verification) &&
                requestLibraryGeneration == repo.libraryGeneration &&
                !repo.scanInProgress) {
              return {
                'items': verification,
                'totalCount': totalCount,
                'startIndex': offset,
                'libraryGeneration': requestLibraryGeneration,
              };
            }
          }

          // The retry budget was exhausted without obtaining a stable
          // snapshot. This is NOT an authoritative empty queue: native must
          // treat it as an indeterminate page and keep the existing window.
          return {
            'status': 'indeterminate',
            'items': const <Map<String, dynamic>>[],
            'totalCount': 0,
            'startIndex': offset,
            'libraryGeneration': repo.libraryGeneration,
          };
        } finally {
          if (requestId != null) {
            _pendingRequestIds.remove(requestId);
            _cancelledRequestIds.remove(requestId);
          }
        }

      case 'requestQueuePageAround':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final contextId = args['contextId'] as String?;
        final volume = args['volume'] as String?;
        final mediaStoreId = (args['id'] as num?)?.toInt();
        final before = ((args['before'] as num?)?.toInt() ?? 20).clamp(0, 80).toInt();
        final after = ((args['after'] as num?)?.toInt() ?? 120).clamp(1, 160).toInt();
        final requestId = (args['requestId'] as num?)?.toInt();
        if (contextId != _activeContextId ||
            _activeSpec == null ||
            volume == null ||
            mediaStoreId == null) {
          return {
            'status': 'indeterminate',
            'items': const <Map<String, dynamic>>[],
            'totalCount': 0,
            'startIndex': 0,
            'libraryGeneration': _repo?.libraryGeneration ?? 0,
          };
        }
        final repo = _repo;
        if (repo == null) {
          return {'items': const <Map<String, dynamic>>[], 'totalCount': 0, 'startIndex': 0, 'libraryGeneration': _repo?.libraryGeneration ?? 0};
        }
        if (requestId != null) _pendingRequestIds.add(requestId);
        try {
          final spec = _activeSpec!;
          final targetIdentity = '$volume:$mediaStoreId';
          // Position, count and page are separate Isar operations. The
          // library can mutate between any two of them, so never hand native
          // a page merely because the old position query succeeded. Verify
          // that the exact identity is still at the expected logical slot.
          // A bounded retry turns a concurrent scan/delete into a harmless
          // re-resolution instead of a stale queue window.
          for (var attempt = 0; attempt < 3; attempt++) {
            final requestLibraryGeneration = await repo.waitForStableSnapshot();
            if (repo.scanInProgress || requestLibraryGeneration != repo.libraryGeneration) continue;
            final position = await spec.resolvePosition(
              repo,
              volume: volume,
              mediaStoreId: mediaStoreId,
            );
            if (position == null) {
              // The anchor disappeared; this is not proof that the logical
              // queue is empty. Return an indeterminate response so native
              // can fall back to a normal page/rebase.
              return {
                'status': 'indeterminate',
                'items': const <Map<String, dynamic>>[],
                'totalCount': 0,
                'startIndex': 0,
                'libraryGeneration': repo.libraryGeneration,
              };
            }
            if (requestId != null && _cancelledRequestIds.contains(requestId)) {
              return {'items': const <Map<String, dynamic>>[], 'totalCount': 0, 'startIndex': position, 'libraryGeneration': _repo?.libraryGeneration ?? 0};
            }

            final totalCount = await spec.resolveCount(repo);
            if (totalCount <= 0 || position >= totalCount) {
              if (totalCount == 0 && !repo.scanInProgress && requestLibraryGeneration == repo.libraryGeneration) {
                return {
                  'items': const <Map<String, dynamic>>[],
                  'totalCount': 0,
                  'startIndex': 0,
                  'libraryGeneration': requestLibraryGeneration,
                };
              }
              if (attempt == 2) {
                return {
                  'status': 'indeterminate',
                  'items': const <Map<String, dynamic>>[],
                  'totalCount': totalCount,
                  'startIndex': 0,
                  'libraryGeneration': repo.libraryGeneration,
                };
              }
              continue;
            }

            final start = (position - before).clamp(0, totalCount - 1).toInt();
            final limit = (before + after + 1).clamp(1, 240).toInt();
            final page = await spec.resolvePage(repo, offset: start, limit: limit);
            if (repo.scanInProgress || requestLibraryGeneration != repo.libraryGeneration) continue;
            if (requestId != null && _cancelledRequestIds.contains(requestId)) {
              return {'items': const <Map<String, dynamic>>[], 'totalCount': totalCount, 'startIndex': start, 'libraryGeneration': _repo?.libraryGeneration ?? 0};
            }

            final relative = position - start;
            final item = relative >= 0 && relative < page.length ? page[relative] : null;
            final itemIdentity = item == null
                ? null
                : '${item['volume'] as String?}:${(item['id'] as num?)?.toInt()}';
            if (itemIdentity == targetIdentity &&
                requestLibraryGeneration == repo.libraryGeneration) {
              return {
                'items': page,
                'totalCount': totalCount,
                'startIndex': start,
                'libraryGeneration': requestLibraryGeneration,
              };
            }

            if (attempt == 2) {
              return {
                'status': 'indeterminate',
                'items': const <Map<String, dynamic>>[],
                'totalCount': totalCount,
                'startIndex': start,
                'libraryGeneration': repo.libraryGeneration,
              };
            }
          }
          return {
            'status': 'indeterminate',
            'items': const <Map<String, dynamic>>[],
            'totalCount': 0,
            'startIndex': 0,
            'libraryGeneration': repo.libraryGeneration,
          };
        } finally {
          if (requestId != null) {
            _pendingRequestIds.remove(requestId);
            _cancelledRequestIds.remove(requestId);
          }
        }

      case 'cancelQueuePage':
        // Fire-and-forget notice that the native coroutine awaiting
        // [requestId] was cancelled (queue context changed, or the
        // player was released — see
        // `QueueWindowController.releaseContext`). Only remembered
        // while the matching request is actually still in flight (see
        // [_pendingRequestIds] doc) — an id that shows up here after
        // its request already finished, or that doesn't match anything
        // this session ever saw, is simply dropped, so this never
        // grows unbounded.
        final cancelArgs = (call.arguments as Map).cast<String, dynamic>();
        final cancelledId = (cancelArgs['requestId'] as num?)?.toInt();
        if (cancelledId != null && _pendingRequestIds.contains(cancelledId)) {
          _cancelledRequestIds.add(cancelledId);
        }
        return null;

      default:
        throw MissingPluginException();
    }
  }

  /// FIX #2 — "correctly handle tracks being deleted... while a queue
  /// is active": forwards deleted ids straight to native so a track
  /// that's playing or sitting in the loaded window right now is
  /// pruned immediately, rather than only being noticed the next time
  /// native happens to re-fetch the page it was on.
  void _onTracksDeleted(List<String> identities) {
    // This is intentionally fire-and-forget: deletion notifications must not
    // block the repository observer. Give the platform Future an explicit
    // error sink so lifecycle/channel failures never become unhandled async
    // errors. A later library event can request another refresh.
    unawaited(
      PlayerChannel.instance.removeQueueItems(identities).catchError((_) {}),
    );
  }

  void _onTracksChanged() {
    if (_activeContextId == null) return;
    // Same best-effort boundary as deletion pruning: the observer callback is
    // not an await point, but the Future still needs an explicit error sink.
    unawaited(
      PlayerChannel.instance.refreshQueueAfterLibraryChange().catchError((_) {}),
    );
  }

  Future<void> togglePlayPause() =>
      PlayerChannel.instance.togglePlayPause();

  Future<void> seek(Duration position) => PlayerChannel.instance.seekTo(position);
  Future<void> next() => PlayerChannel.instance.skipNext();
  Future<void> previous() => PlayerChannel.instance.skipPrevious();

  @override
  void dispose() {
    _queueGenerationGate.begin();
    _sub.cancel();
    _deletionsSub?.cancel();
    _changesSub?.cancel();
    _queueInvalidationsSub?.cancel();
    super.dispose();
  }
}

import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'playback_state.dart';

/// Dart-side wrapper around the native MethodChannel + EventChannel that
/// talk to the Kotlin PlaybackService / PlayerHolder / MediaStoreScanner.
/// Keep this the single choke point for platform calls so the rest of
/// the app never touches MethodChannel/EventChannel directly.
class PlayerChannel {
  PlayerChannel._();
  static final PlayerChannel instance = PlayerChannel._();

  static const MethodChannel _method =
      MethodChannel('com.example.musicplayer/player');
  static const EventChannel _events =
      EventChannel('com.example.musicplayer/player_events');

  Stream<PlaybackState>? _stateStream;

  /// Broadcast stream of playback state, emitted roughly every 500ms and
  /// on every native player event (play/pause/track change).
  Stream<PlaybackState> get stateStream {
    _stateStream ??= _events
        .receiveBroadcastStream()
        .map((raw) => PlaybackState.fromMap(raw as Map<dynamic, dynamic>));
    return _stateStream!;
  }

  /// FIX #2 (see also FIX #4): registers the handler for native→Dart
  /// calls — `requestQueuePage`, made by the native sliding-window
  /// queue controller (`PlayerHolder`/`QueueWindowController`) when it
  /// needs another page of the current [QueueSpec]'s logical result
  /// set, and `cancelQueuePage`, a fire-and-forget notice that a
  /// previous `requestQueuePage` call is no longer wanted. Only
  /// [PlaybackController] should call this (once, at construction) —
  /// `MethodChannel.setMethodCallHandler` only supports one handler at
  /// a time, so this is the single choke point for that direction too.
  void setNativeCallHandler(
    Future<dynamic> Function(MethodCall call) handler,
  ) {
    _method.setMethodCallHandler(handler);
  }

  /// Commits the deletion-observation baseline only if native Android has
  /// a confirmed complete MediaStore observer set at the exact commit point.
  /// Native also clears this durable baseline whenever observer coverage is
  /// lost, so a later observer retry cannot silently revalidate an old boundary.
  Future<bool> commitDeletionObservationBaseline(String epoch) async {
    final result = await _method.invokeMethod<bool>(
      'commitDeletionObservationBaseline',
      {'epoch': epoch},
    );
    return result == true;
  }

  /// Returns whether native observer coverage is missing or a recovery
  /// boundary has been invalidated. A channel/platform failure is treated as
  /// true (conservative) so the repository never mistakes an unknown native
  /// state for safe deletion observation.
  Future<bool> observerNeedsDeletionReconciliation() async {
    try {
      return await _method.invokeMethod<bool>(
            'observerNeedsDeletionReconciliation',
          ) ??
          true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }

  /// Triggers an incremental MediaStore scan on the native side.
  ///
  /// The public cursor arguments are Dart millisecond timestamps for the
  /// persisted scan clock. Android's `DATE_MODIFIED` is seconds, so the
  /// conversion happens at this single platform boundary. The upper bound is
  /// captured before the scan starts;
  /// this prevents a long multi-volume scan from advancing the cursor past
  /// changes that occur while the scan is already in progress.
  Future<List<Map<String, dynamic>>> scanLibraryPage({
    required String volume,
    int sinceTimestamp = 0,
    int untilTimestamp = 0,
    int cursorDateModifiedSeconds = 9223372036854775807,
    int cursorMediaStoreId = 9223372036854775807,
    int sinceGeneration = -1,
    int untilGeneration = -1,
    int cursorGeneration = 9223372036854775807,
    int limit = 500,
  }) async {
    final sinceSeconds = sinceTimestamp ~/ 1000;
    final untilSeconds = untilTimestamp <= 0
        ? 9223372036854775807
        : untilTimestamp ~/ 1000;
    final result = await _method.invokeMethod<List<dynamic>>(
      'scanLibraryPage',
      {
        'volume': volume,
        'sinceTimestampSeconds': sinceSeconds,
        'untilTimestampSeconds': untilSeconds,
        'cursorDateModifiedSeconds': cursorDateModifiedSeconds,
        'cursorMediaStoreId': cursorMediaStoreId,
        'sinceGeneration': sinceGeneration,
        'untilGeneration': untilGeneration,
        'cursorGeneration': cursorGeneration,
        'limit': limit,
      },
    );
    if (result == null) {
      throw StateError('MediaStore scan returned no result');
    }
    final rows = <Map<String, dynamic>>[];
    for (final raw in result) {
      if (raw is! Map) {
        throw StateError('MediaStore scan returned a malformed row');
      }
      rows.add(Map<String, dynamic>.fromEntries(
        raw.entries.map((entry) => MapEntry(entry.key.toString(), entry.value)),
      ));
    }
    return List.unmodifiable(rows);
  }

  Future<List<Map<String, dynamic>>> scanLibraryIdentities({
    required String volume,
    required List<int> ids,
  }) async {
    if (ids.isEmpty || ids.length > 500 || ids.any((id) => id <= 0)) {
      throw ArgumentError.value(ids, 'ids', 'must contain 1..500 positive IDs');
    }
    final result = await _method.invokeMethod<List<dynamic>>(
      'scanLibraryIdentities',
      {'volume': volume, 'ids': ids},
    );
    if (result == null) {
      throw StateError('MediaStore identity scan returned no result');
    }
    final rows = <Map<String, dynamic>>[];
    for (final raw in result) {
      if (raw is! Map) throw StateError('MediaStore identity scan returned a malformed row');
      rows.add(Map<String, dynamic>.fromEntries(
        raw.entries.map((entry) => MapEntry(entry.key.toString(), entry.value)),
      ));
    }
    return List.unmodifiable(rows);
  }

  Future<Map<String, Map<String, dynamic>>> getMediaStoreVolumeStates() async {
    final result = await _method.invokeMethod<List<dynamic>>('getMediaStoreVolumeStates');
    if (result == null) {
      throw StateError('MediaStore volume-state discovery returned no result');
    }
    final states = <String, Map<String, dynamic>>{};
    for (final raw in result) {
      if (raw is! Map) throw StateError('MediaStore volume-state response is malformed');
      final volume = raw['volume'];
      final generation = raw['generation'];
      final version = raw['version'];
      final generationSupported = raw['generationSupported'];
      final lifecycleGeneration = raw['lifecycleGeneration'];
      if (volume is! String || volume.trim().isEmpty ||
          generation is! num || generation < 0 ||
          generationSupported is! bool || version is! String ||
          lifecycleGeneration is! num || lifecycleGeneration < 0) {
        throw StateError('MediaStore volume-state response is malformed');
      }
      states[volume.trim()] = {
        'generation': generation.toInt(),
        'generationSupported': generationSupported,
        'version': version,
        'lifecycleGeneration': lifecycleGeneration.toInt(),
      };
    }
    return Map.unmodifiable(states);
  }

  Future<Set<String>> getMediaStoreVolumes() async {
    final result = await _method.invokeMethod<List<dynamic>>('getMediaStoreVolumes');
    if (result == null) {
      throw StateError('MediaStore volume discovery returned no result');
    }
    final volumes = <String>{};
    for (final raw in result) {
      if (raw is! String || raw.trim().isEmpty) {
        throw StateError('MediaStore volume discovery returned a malformed volume');
      }
      volumes.add(raw.trim());
    }
    if (volumes.isEmpty) {
      throw StateError('MediaStore volume discovery returned no volumes');
    }
    return Set.unmodifiable(volumes);
  }

  /// Returns the subset of [mediaStoreIds] that still exists in
  /// MediaStore. The native side queries only this bounded batch, so a
  /// 500,000-track library never crosses the platform channel as one
  /// giant ID list.
  Future<Set<String>> findExistingMediaStoreObserverIdentities(
    List<String> identities,
  ) async {
    if (identities.isEmpty) return const <String>{};
    if (identities.length > 500) {
      throw ArgumentError.value(identities.length, 'identities', 'maximum is 500');
    }
    final parsed = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final raw in identities) {
      final separator = raw.indexOf(':');
      if (separator <= 0 || separator >= raw.length - 1) {
        throw ArgumentError.value(raw, 'identities', 'invalid MediaStore identity');
      }
      final volume = raw.substring(0, separator).trim();
      final id = int.tryParse(raw.substring(separator + 1));
      if (volume.isEmpty || id == null || id <= 0) {
        throw ArgumentError.value(raw, 'identities', 'invalid MediaStore identity');
      }
      final key = '$volume:$id';
      if (!seen.add(key)) throw ArgumentError.value(raw, 'identities', 'duplicate identity');
      parsed.add({'volume': volume, 'id': id});
    }
    final result = await _method.invokeMethod<List<dynamic>>(
      'findExistingMediaStoreObserverIdentities',
      {'identities': parsed},
    );
    if (result == null) throw StateError('MediaStore observer query returned no result');
    final existing = <String>{};
    for (final raw in result) {
      if (raw is! String || !seen.contains(raw)) {
        throw StateError('MediaStore observer query returned a malformed identity');
      }
      existing.add(raw);
    }
    return Set.unmodifiable(existing);
  }

  Future<Set<String>> findExistingMediaStoreIdentities(
    List<Map<String, dynamic>> tracks,
  ) async {
    if (tracks.isEmpty) return const <String>{};
    if (tracks.length > 500) {
      throw ArgumentError.value(tracks.length, 'tracks', 'maximum is 500');
    }
    final result = await _method.invokeMethod<List<dynamic>>(
      'findExistingMediaStoreIdentities',
      {'tracks': tracks},
    );
    if (result == null) {
      throw StateError('MediaStore identity validation returned no result');
    }
    final requested = tracks.map((e) => '${e['volume']}:${e['id']}').toSet();
    final existing = <String>{};
    for (final raw in result) {
      if (raw is! String || !requested.contains(raw)) {
        throw StateError('MediaStore identity validation returned a malformed identity');
      }
      existing.add(raw);
    }
    return Set.unmodifiable(existing);
  }

  // -------------------------------------------------------------------
  // FIX #2 — query-backed playback queue
  // -------------------------------------------------------------------

  /// Establishes a new query-backed playback queue and starts playback
  /// at its [startIndex]. Unlike the old `setQueue`, this does NOT hand
  /// native the complete track list for [spec] — only [initialWindow],
  /// a small slice of [Track]s around [startIndex]. As playback nears
  /// either edge of what's loaded, native asks Dart for more via
  /// `requestQueuePage` (see [setNativeCallHandler] /
  /// `PlaybackController`), resolved against [spec] fresh each time —
  /// so a 10,000-track queue costs the same MethodChannel payload here
  /// as a 60-track one.
  ///
  /// [contextId] must be unique per `setQueueContext` call (e.g. an
  /// incrementing counter) — it lets native recognize and discard a
  /// `requestQueuePage` response that arrives after the queue it was
  /// for has already been replaced by a newer one.
  ///
  /// [windowStartIndex] is [initialWindow]'s own logical offset into
  /// the full [spec] result set (NOT necessarily 0 — see
  /// `PlaybackController.playQueue`, which centers the initial window
  /// on [startIndex] rather than always starting it at the top of the
  /// list, so tapping track #9,000 of 10,000 doesn't require loading
  /// the preceding 9,000 first).
  Future<void> setQueueContext({
    required String contextId,
    required int queueGeneration,
    required String queueGenerationEpoch,
    required int libraryGeneration,
    required Map<String, dynamic> spec,
    required int totalCount,
    required int startIndex,
    required List<Map<String, dynamic>> initialWindow,
    required int windowStartIndex,
    String? startItemIdentity,
    int startPositionMs = 0,
    bool autoPlay = true,
  }) {
    return _method.invokeMethod('setQueueContext', {
      'contextId': contextId,
      'queueGeneration': queueGeneration,
      'queueGenerationEpoch': queueGenerationEpoch,
      'libraryGeneration': libraryGeneration,
      'spec': spec,
      'totalCount': totalCount,
      'startIndex': startIndex,
      'window': initialWindow,
      'windowStartIndex': windowStartIndex,
      'startItemIdentity': startItemIdentity,
      'startPositionMs': startPositionMs,
      'autoPlay': autoPlay,
    });
  }

  /// Prunes any currently-loaded queue items matching [mediaStoreIds]
  /// — called when [LibraryRepository.tracksDeleted] reports tracks
  /// removed from device storage while a queue may be active, so a
  /// deleted track that's still resident in the native sliding window
  /// (playing or just queued) is dropped immediately rather than only
  /// being noticed the next time that page happens to be re-fetched.
  Future<void> removeQueueItems(List<String> identities) {
    if (identities.isEmpty) return Future.value();
    return _method.invokeMethod('removeQueueItems', {'identities': identities});
  }

  /// Invalidates the active query-backed queue after an insert/update scan.
  /// Native re-anchors on the current media identity, so logical offsets are
  /// rebuilt from the current Isar dataset rather than patched by index.
  Future<void> refreshQueueAfterLibraryChange() =>
      _method.invokeMethod('refreshQueueAfterLibraryChange');

  /// Publishes the current Dart library generation to native so a queue-page
  /// response validated against an older Isar snapshot cannot be committed.
  Future<void> updateLibraryGeneration(int generation) =>
      _method.invokeMethod('setLibraryGeneration', {'generation': generation});

  Future<String?> getQueueContextId() =>
      _method.invokeMethod<String>('getQueueContextId');

  Future<void> clearQueueContextIfMatches(String contextId) =>
      _method.invokeMethod<void>('clearQueueContextIfMatches', {
        'contextId': contextId,
      });

  Future<void> play() => _method.invokeMethod('play');
  Future<void> pause() => _method.invokeMethod('pause');
  Future<void> togglePlayPause() => _method.invokeMethod('togglePlayPause');
  Future<void> seekTo(Duration position) =>
      _method.invokeMethod('seekTo', {'positionMs': position.inMilliseconds});

  /// Advances the queue. Works across the FULL logical result set of
  /// the active [QueueSpec] (see `setQueueContext`), not just whatever
  /// window happens to be resident natively right now — if the next
  /// logical track isn't loaded yet, native awaits a `requestQueuePage`
  /// round-trip before completing (see native `PlayerHolder.skipNext`).
  Future<void> skipNext() => _method.invokeMethod('skipNext');

  /// Standard player semantics, implemented natively in
  /// `PlayerHolder.skipPrevious`: restarts the current track if more
  /// than ~3s in (or there's no previous track), otherwise jumps back.
  Future<void> skipPrevious() => _method.invokeMethod('skipPrevious');

  // -------------------------------------------------------------------
  // Lyrics
  // -------------------------------------------------------------------

  /// Resolves lyrics for a track: embedded metadata tags first (ID3
  /// USLT/COMM for MP3, a Vorbis "LYRICS"/"UNSYNCEDLYRICS" comment for
  /// FLAC/OGG, or the "©lyr" atom for M4A/AAC), falling back to a
  /// sidecar `.lrc` file in the same folder (matched by [relativePath]
  /// + [displayName] minus its extension) when the track has no
  /// embedded lyrics tag — see native `SidecarLyricsResolver` for how
  /// that fallback stays correct under Android 13+ Scoped Storage.
  ///
  /// [relativePath]/[displayName] come straight from [Track] — pass the
  /// track's own values so the sidecar lookup can require an exact
  /// same-folder, same-filename-stem match (never matching a
  /// same-named track in a different folder).
  ///
  /// Returns null if no lyrics were found via either source. The
  /// returned text may itself be `.lrc`-formatted — see
  /// `LibraryRepository.ensureLyrics`.
  Future<String?> getLyrics(
    String contentUri, {
    String? mediaStoreVolume,
    String? relativePath,
    String? displayName,
  }) {
    return _method.invokeMethod<String>('getLyrics', {
      'contentUri': contentUri,
      'mediaStoreVolume': mediaStoreVolume,
      'relativePath': relativePath,
      'displayName': displayName,
    });
  }

  /// Whether the user has usable SAF access for the supplied track folder.
  /// When [mediaStoreVolume]/[relativePath] are provided, native checks both
  /// the SAF tree volume and whether that tree is an ancestor of the track's
  /// relative path. Omitting them preserves the generic global permission
  /// query for callers that genuinely need it.
  Future<bool> supportsLyricsFolderRecovery() async {
    final result = await _method.invokeMethod<bool>('supportsLyricsFolderRecovery');
    return result ?? false;
  }

  Future<bool> hasLyricsFolderAccess({
    String? mediaStoreVolume,
    String? relativePath,
  }) async {
    final result = await _method.invokeMethod<bool>(
      'hasLyricsFolderAccess',
      {
        'mediaStoreVolume': mediaStoreVolume,
        'relativePath': relativePath,
      },
    );
    return result ?? false;
  }

  /// Launches the system folder picker (`ACTION_OPEN_DOCUMENT_TREE`) so
  /// the user can grant access to their music folder for sidecar
  /// `.lrc` lookups. Returns true if a folder was granted, false if the
  /// user cancelled. The permission is persisted natively (see
  /// `MainActivity`), so this only needs to be called once per folder.
  Future<bool> requestLyricsFolderAccess() async {
    final result =
        await _method.invokeMethod<bool>('requestLyricsFolderAccess');
    return result ?? false;
  }

  // -------------------------------------------------------------------
  // Album artwork
  // -------------------------------------------------------------------

  static int _nextAlbumArtRequestId = 0;

  /// Creates a unique consumer id for one Riverpod artwork subscription.
  /// The native loader uses this id for consumer-aware cancellation while
  /// still deduplicating the underlying (contentUri, size) operation.
  String newAlbumArtRequestId() {
    _nextAlbumArtRequestId++;
    return 'art-${_nextAlbumArtRequestId.toRadixString(36)}';
  }

  /// Embedded album artwork for a track, downsampled to roughly
  /// [size]x[size] px by the native thumbnail pipeline. Returns null if
  /// the track has no embedded artwork.
  Future<Uint8List?> getAlbumArt(
    String contentUri, {
    int size = 256,
    required String requestId,
    required int version,
  }) {
    final safeSize = size.clamp(32, 2048).toInt();
    return _method.invokeMethod<Uint8List>('getAlbumArt', {
      'contentUri': contentUri,
      'size': safeSize,
      'requestId': requestId,
      'version': version,
    });
  }

  // -------------------------------------------------------------------
  // Equalizer / BassBoost
  // -------------------------------------------------------------------

  /// `{supported, enabled, bands: [{index, centerFreqHz, levelMillibel,
  /// minMillibel, maxMillibel}], presets: [{index, name}],
  /// bassBoostSupported, bassBoostStrength}`.
  Future<Map<String, dynamic>> getEqualizerState() async {
    final result =
        await _method.invokeMethod<Map<dynamic, dynamic>>('getEqualizerState');
    return (result ?? {}).cast<String, dynamic>();
  }

  Future<void> setEqualizerBand(int band, int levelMillibel) {
    return _method.invokeMethod('setEqualizerBand', {
      'band': band,
      'levelMillibel': levelMillibel,
    });
  }

  /// Applies a built-in preset and returns the refreshed equalizer
  /// state so the UI can sync its sliders to whatever levels the preset
  /// actually set.
  Future<Map<String, dynamic>> setEqualizerPreset(int preset) async {
    final result = await _method
        .invokeMethod<Map<dynamic, dynamic>>('setEqualizerPreset', {'preset': preset});
    return (result ?? {}).cast<String, dynamic>();
  }

  Future<void> setBassBoost(int strengthPermille) {
    return _method
        .invokeMethod('setBassBoost', {'strengthPermille': strengthPermille});
  }

  Future<void> setEqualizerEnabled(bool enabled) {
    return _method.invokeMethod('setEqualizerEnabled', {'enabled': enabled});
  }

  /// Cancels a pending bounded retry for a valid ExoPlayer audio
  /// session (see native `EqualizerController.awaitAttached`). Call
  /// this from the Equalizer screen's `dispose()` so a retry started
  /// by [getEqualizerState] doesn't keep running after the user has
  /// already navigated away.
  Future<void> cancelEqualizerWait() =>
      _method.invokeMethod('cancelEqualizerWait');

  // -------------------------------------------------------------------
  // Album artwork cancellation
  // -------------------------------------------------------------------

  /// Releases this specific consumer's interest in an in-flight
  /// [getAlbumArt] request. Releasing one consumer does not cancel the
  /// shared operation while another consumer still needs it.
  Future<void> cancelAlbumArt(
    String contentUri, {
    int size = 256,
    required String requestId,
    required int version,
  }) {
    return _method.invokeMethod('cancelAlbumArt', {
      'contentUri': contentUri,
      'size': size,
      'requestId': requestId,
      'version': version,
    });
  }
}

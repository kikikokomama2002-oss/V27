import '../core/playlist_store.dart';
import '../data/db/track.dart';
import '../data/repositories/library_repository.dart';

/// FIX #2 — describes a logical, query-backed playback queue context:
/// "all tracks", "search results for X", or "tracks in group Y" —
/// instead of a concrete `List<Track>`.
///
/// The native ExoPlayer playlist only ever holds a sliding WINDOW of
/// [Track]s around the current playback position (see
/// `PlayerHolder`/`QueueWindowController` on the Kotlin side); this
/// spec is what lets both sides re-derive "what page N of this queue
/// actually contains" on demand, without Dart ever handing native (or
/// keeping in its own memory) the full track list for a
/// multi-thousand-track library.
///
/// [contextId] uniquely (enough) identifies one queue "session" so a
/// late-arriving async page response from a stale/replaced queue can
/// be recognized and dropped by the native side instead of corrupting
/// whatever queue replaced it.
sealed class QueueSpec {
  const QueueSpec();

  static const int maxQueryLength = LibraryRepository.maxSearchQueryLength;

  static String? _validText(dynamic value, String label) {
    if (value is! String) return null;
    if (value.trim().isEmpty || value.length > maxQueryLength) return null;
    return value;
  }

  static String _requireText(String value, String label) {
    if (value.trim().isEmpty) {
      throw ArgumentError('$label must not be empty');
    }
    if (value.length > maxQueryLength) {
      throw ArgumentError('$label is too long');
    }
    return value.trim();
  }

  static String _requireGroupName(String value) {
    if (value.trim().isEmpty) {
      throw ArgumentError('name must not be empty');
    }
    // Group names are persisted database keys, not free-form search queries.
    // Preserve the exact key, including intentional surrounding whitespace,
    // so the queue addresses the same value the grouping UI selected.
    return value;
  }

  static QueueSpec? fromMap(Map<dynamic, dynamic> raw) {
    final kind = raw['kind'] as String?;
    switch (kind) {
      case 'all':
        return const AllTracksQueueSpec();
      case 'search':
        final query = _validText(raw['query'], 'query');
        return query == null ? null : SearchQueueSpec(query);
      case 'playlist':
        final playlistId = raw['playlistId'];
        return playlistId is String && playlistId.isNotEmpty && playlistId.length <= 128
            ? PlaylistQueueSpec(playlistId)
            : null;
      case 'group':
        final fieldName = raw['field'] as String?;
        final rawName = raw['name'];
        final name = rawName is String && rawName.trim().isNotEmpty ? rawName : null;
        if (fieldName == null || name == null) return null;
        GroupField? field;
        for (final candidate in GroupField.values) {
          if (candidate.name == fieldName) {
            field = candidate;
            break;
          }
        }
        return field == null ? null : GroupQueueSpec(field!, name);
      default:
        return null;
    }
  }

  /// Serialized for the native `setQueueContext` call.
  Map<String, dynamic> toMap();

  /// A stable identity for this spec's *contents* (not a specific
  /// instance) — two `QueueSpec`s describing the same underlying query
  /// compare equal here, which `PlaybackController` uses to decide
  /// whether tapping another row in the same list can just re-seek the
  /// existing native queue instead of re-issuing `setQueueContext`.
  String get queryKey;

  Future<int> resolveCount(LibraryRepository repo);

  Future<List<Map<String, dynamic>>> resolvePage(
    LibraryRepository repo, {
    required int offset,
    required int limit,
  });

  Future<int?> resolvePosition(
    LibraryRepository repo, {
    required String volume,
    required int mediaStoreId,
    int? hintIndex,
  });
}

class AllTracksQueueSpec extends QueueSpec {
  const AllTracksQueueSpec();

  @override
  Map<String, dynamic> toMap() => {'kind': 'all'};

  @override
  String get queryKey => 'all';

  @override
  Future<int> resolveCount(LibraryRepository repo) => repo.tracksCount();

  @override
  Future<int?> resolvePosition(
    LibraryRepository repo, {
    required String volume,
    required int mediaStoreId,
    int? hintIndex,
  }) => repo.allTracksPosition(volume, mediaStoreId);

  @override
  Future<List<Map<String, dynamic>>> resolvePage(
    LibraryRepository repo, {
    required int offset,
    required int limit,
  }) async {
    final tracks = await repo.tracksPage(offset: offset, limit: limit);
    return tracks.map(_trackToQueueItem).toList();
  }
}

class SearchQueueSpec extends QueueSpec {
  SearchQueueSpec(String query) : query = QueueSpec._requireText(query, 'query');
  final String query;

  @override
  Map<String, dynamic> toMap() => {'kind': 'search', 'query': query};

  @override
  String get queryKey => 'search:$query';

  @override
  Future<int> resolveCount(LibraryRepository repo) =>
      repo.searchCount(query);

  @override
  Future<int?> resolvePosition(
    LibraryRepository repo, {
    required String volume,
    required int mediaStoreId,
    int? hintIndex,
  }) => repo.searchPosition(query, volume, mediaStoreId);

  @override
  Future<List<Map<String, dynamic>>> resolvePage(
    LibraryRepository repo, {
    required int offset,
    required int limit,
  }) async {
    final tracks = await repo.searchPage(query, offset: offset, limit: limit);
    return tracks.map(_trackToQueueItem).toList();
  }
}

/// A persisted playlist queue. Membership is stored as stable MediaStore
/// identities; pages resolve in playlist order and omit tracks which no longer
/// exist in the scanned library. Only one bounded membership chunk is resolved
/// at a time, so playback does not materialize the full Track library.
class PlaylistQueueSpec extends QueueSpec {
  const PlaylistQueueSpec(this.playlistId);

  final String playlistId;
  static const int _identityChunkSize = 240;

  @override
  Map<String, dynamic> toMap() => {'kind': 'playlist', 'playlistId': playlistId};

  @override
  String get queryKey => 'playlist:$playlistId';

  Future<UserPlaylist?> _playlist() => PlaylistStoreController.readById(playlistId);

  Future<List<Track>> _resolveChunk(
    LibraryRepository repo,
    List<PlaylistTrackIdentity> identities,
  ) {
    return repo.tracksForMediaStoreIdentities(
      identities
          .map((identity) => (volume: identity.volume, id: identity.mediaStoreId))
          .toList(growable: false),
    );
  }

  @override
  Future<int> resolveCount(LibraryRepository repo) async {
    final playlist = await _playlist();
    if (playlist == null || playlist.songs.isEmpty) return 0;
    var count = 0;
    for (var start = 0; start < playlist.songs.length; start += _identityChunkSize) {
      final end = (start + _identityChunkSize).clamp(0, playlist.songs.length).toInt();
      count += (await _resolveChunk(repo, playlist.songs.sublist(start, end))).length;
    }
    return count;
  }

  @override
  Future<int?> resolvePosition(
    LibraryRepository repo, {
    required String volume,
    required int mediaStoreId,
    int? hintIndex,
  }) async {
    final playlist = await _playlist();
    if (playlist == null || playlist.songs.isEmpty) return null;
    var logicalIndex = 0;
    var bestIndex = -1;
    var bestDistance = 1 << 62;
    for (var start = 0; start < playlist.songs.length; start += _identityChunkSize) {
      final end = (start + _identityChunkSize).clamp(0, playlist.songs.length).toInt();
      final tracks = await _resolveChunk(repo, playlist.songs.sublist(start, end));
      for (final track in tracks) {
        if (track.mediaStoreVolume == volume && track.mediaStoreId == mediaStoreId) {
          if (hintIndex == null) return logicalIndex;
          final distance = (logicalIndex - hintIndex).abs();
          if (distance < bestDistance) {
            bestDistance = distance;
            bestIndex = logicalIndex;
          }
        }
        logicalIndex++;
      }
    }
    return bestIndex < 0 ? null : bestIndex;
  }

  @override
  Future<List<Map<String, dynamic>>> resolvePage(
    LibraryRepository repo, {
    required int offset,
    required int limit,
  }) async {
    if (offset < 0 || limit <= 0) return const <Map<String, dynamic>>[];
    final playlist = await _playlist();
    if (playlist == null || playlist.songs.isEmpty) return const <Map<String, dynamic>>[];
    final result = <Map<String, dynamic>>[];
    var logicalIndex = 0;
    for (var start = 0; start < playlist.songs.length; start += _identityChunkSize) {
      final end = (start + _identityChunkSize).clamp(0, playlist.songs.length).toInt();
      final tracks = await _resolveChunk(repo, playlist.songs.sublist(start, end));
      for (final track in tracks) {
        if (logicalIndex >= offset && result.length < limit) {
          result.add(_trackToQueueItem(track));
        }
        logicalIndex++;
        if (result.length >= limit) break;
      }
      if (result.length >= limit) break;
    }
    return result;
  }
}

class GroupQueueSpec extends QueueSpec {
  GroupQueueSpec(this.field, String name) : name = QueueSpec._requireGroupName(name);
  final GroupField field;
  final String name;

  @override
  Map<String, dynamic> toMap() =>
      {'kind': 'group', 'field': field.name, 'name': name};

  @override
  String get queryKey => 'group:${field.name}:$name';

  @override
  Future<int> resolveCount(LibraryRepository repo) =>
      repo.countForGroup(field, name);

  @override
  Future<int?> resolvePosition(
    LibraryRepository repo, {
    required String volume,
    required int mediaStoreId,
    int? hintIndex,
  }) => repo.groupPosition(field, name, volume, mediaStoreId);

  @override
  Future<List<Map<String, dynamic>>> resolvePage(
    LibraryRepository repo, {
    required int offset,
    required int limit,
  }) async {
    final tracks = await repo.tracksForGroupPage(
      field,
      name,
      offset: offset,
      limit: limit,
    );
    return tracks.map(_trackToQueueItem).toList();
  }
}

Map<String, dynamic> _trackToQueueItem(Track t) =>
    {'id': t.mediaStoreId, 'contentUri': t.contentUri, 'volume': t.mediaStoreVolume};

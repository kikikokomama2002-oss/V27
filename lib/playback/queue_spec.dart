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

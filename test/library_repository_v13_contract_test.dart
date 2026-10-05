import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'source_contract_helpers.dart';

void main() {
  final source = File('lib/data/repositories/library_repository.dart').readAsStringSync();
  final trackSource = File('lib/data/db/track.dart').readAsStringSync();
  final trackClass = extractBlock(trackSource, 'class Track {', markerContainsOpeningBrace: true);

  test('search page/count/position share canonical term normalization and punctuation semantics', () {
    final searchTerms = extractBlock(source, 'static List<String>? _searchTerms(String query)');
    expect(searchTerms, contains('if (terms.isEmpty) {'));
    final searchPosition = extractBlock(source, 'Future<int?> allTracksPosition(');
    expect(searchPosition, contains('query.trim().isEmpty ? tracksCount() : Future<int>.value(0)'));
    expect(searchPosition, contains('if (terms == null) return null;'));
    expect(searchPosition, contains('if (query.trim().isNotEmpty) return null;'));
    expect(searchPosition, contains('return allTracksPosition(volume, mediaStoreId);'));
  });

  test('queue position uses the same case-sensitive title ordering as page queries', () {
    final position = extractBlock(source, 'Future<int?> allTracksPosition(');
    expect(position, contains('.anyTitle()'));
    expect(position, isNot(contains('.sortByTitle()')));
    expect(position, contains('titleLessThan(current.title, caseSensitive: true)'));
    expect(position, contains('titleEqualTo(current.title, caseSensitive: true)'));
    expect(position, isNot(contains('titleLessThan(current.title, caseSensitive: false)')));
    expect(position, isNot(contains('titleEqualTo(current.title, caseSensitive: false)')));
  });

  test('repository rejects pathological page/search inputs before database work', () {
    final pageArgs = extractBlock(source, 'static bool _validPageArgs(');
    final searchTerms = extractBlock(source, 'static List<String>? _searchTerms(');
    final page = extractBlock(source, 'Future<List<Track>> tracksPage(');
    final identityLookup = extractBlock(source, 'Future<Track?> trackByMediaStoreIdentity(');
    expect(pageArgs, contains('maxPageSize'));
    expect(pageArgs, contains('maxPageOffset'));
    expect(searchTerms, contains('maxSearchTerms'));
    expect(page, contains('if (!_validPageArgs(offset: offset, limit: limit) || limit == 0)'));
    expect(searchTerms, contains('if (query.length > maxSearchQueryLength) return null;'));
    expect(identityLookup, contains('if (volume.length > maxVolumeLength || id <= 0)'));
  });

  test('media store identity remains composite and title ordering index is composite', () {
    expect(trackClass, contains('@Index(unique: true, composite: [CompositeIndex(\'mediaStoreId\')])'));
    expect(trackClass, contains("CompositeIndex('mediaStoreVolume')"));
    expect(trackClass, contains("CompositeIndex('mediaStoreId')"));
  });

  test('no stale undefined legacy reconciliation field remains', () {
    expect(source, isNot(contains('_lastLegacyFullReconciliationCompletedAt')));
  });

  test('deletion compensation never restores a stale Track after MediaStore ID reuse', () {
    final deletion = extractBlock(source, 'Future<void> _syncDeletions(');
    expect(deletion, contains('final recreatedDeletedIdentities = recreated'));
    expect(deletion, contains('.where(deletedIdentities.contains)'));
    expect(deletion, contains('MediaStore identity reappeared but could not be re-read'));
    expect(deletion, contains('final recreatedRows = <Map<String, dynamic>>[];'));
    expect(deletion, contains('scanLibraryIdentities('));
    expect(deletion, isNot(contains('await _isar.tracks.put(row);')));
    expect(deletion, isNot(contains('final restoreRows = <Track>[]')));
  });

  test('group count batching does not approximate Isar Unicode collation', () {
    final body = extractBlock(source, 'Future<Map<String, int>> countsForGroups');
    expect(body, contains('final uniqueNames = names.toSet().toList(growable: false);'));
    expect(body, isNot(contains('value.toLowerCase()')));
  });

  test('identity lookups use the volume+MediaStore-ID composite index', () {
    final identityLookup = extractBlock(source, 'Future<Track?> trackByMediaStoreIdentity(');
    final deletion = extractBlock(source, 'Future<void> _syncDeletions(');
    final position = extractBlock(source, 'Future<int?> allTracksPosition(');
    expect(identityLookup, contains('mediaStoreVolumeMediaStoreIdEqualTo(normalizedVolume, id)'));
    expect(position, contains('mediaStoreVolumeMediaStoreIdEqualTo(volume, mediaStoreId)'));
    expect(deletion, contains('mediaStoreVolumeMediaStoreIdEqualTo(\n            track.mediaStoreVolume,\n            track.mediaStoreId,'));
  });

  test('position/group/deletion queries do not accidentally OR independent where clauses', () {
    final position = extractBlock(source, 'Future<int?> allTracksPosition(');
    final deletion = extractBlock(source, 'Future<void> _syncDeletions(');
    expect(position, contains('.titleEqualTo(current.title, caseSensitive: true)\n        .filter()'));
    expect(position, contains('.idGreaterThan(lastIsarId)\n          .filter()'));
    expect(position, contains('.titleLessThan(current.title, caseSensitive: true)\n            .filter()'));
    expect(source, isNot(contains('.mediaStoreVolumeEqualTo(volume)\n          .mediaStoreIdEqualTo(mediaStoreId)')));
    expect(deletion, isNot(contains('.mediaStoreVolumeEqualTo(group.key)\n            .anyOf(ids')));
  });

  test('search and group pages traverse canonical title ordering before filtering', () {
    final searchPage = extractBlock(source, 'Future<List<Track>> searchPage(');
    expect(searchPage, contains('.where()\n        .anyTitle()\n        .filter()\n        .anyOf('));
    final groupBody = extractBlock(source, 'Future<List<Track>> tracksForGroupPage');
    expect(groupBody, contains('.anyTitle()'));
    expect(groupBody, contains('.filter()'));
    expect(groupBody, isNot(contains('.sortByTitle()')));
  });
}

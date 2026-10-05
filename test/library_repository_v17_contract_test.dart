import 'dart:io';
import 'package:test/test.dart';

void main() {
  final source = File('lib/data/repositories/library_repository.dart').readAsStringSync();

  test('countsForGroups uses O(1)-memory indexed count() per name, never a materializing union query', () {
    final start = source.indexOf('Future<Map<String, int>> countsForGroups');
    final end = source.indexOf('Future<List<Track>> tracksForGroupPage');
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    // Must NOT materialize every matching track's grouping value — memory
    // proportional to group size, unbounded by a single common group name.
    expect(body, isNot(contains('.albumProperty()')));
    expect(body, isNot(contains('.artistProperty()')));
    expect(body, isNot(contains('.folderProperty()')));

    // Bounded-concurrency indexed count() per name instead: O(1) memory per
    // query, total queries bounded by maxPageSize.
    expect(body, contains('const maxConcurrent = 4;'));
    expect(body, contains('Future.wait(chunk.map('));
    expect(body, contains('.albumEqualTo(name, caseSensitive: false)\n              .count(),'));
    expect(body, contains('.artistEqualTo(name, caseSensitive: false)\n              .count(),'));
    expect(body, contains('.folderEqualTo(name, caseSensitive: true)\n              .count(),'));
  });

  test('legacy scan reconciliation treats an unavailable generation as neutral, not a mismatch', () {
    final scanStart = source.indexOf('Future<bool> _persistScanBatch');
    final scanEnd = source.indexOf('Future<void> _syncDeletions');
    expect(scanStart, greaterThanOrEqualTo(0));
    expect(scanEnd, greaterThan(scanStart));
    final body = source.substring(scanStart, scanEnd);

    // Both sides null (every API 24-29 track, every scan) must NOT force
    // cache invalidation on its own when observable metadata is unchanged.
    expect(body, contains('final generationMismatch ='));
    expect(body, contains('if (sameObservableIdentity && !generationMismatch && !invalidateDerivedCache) {'));
    expect(body, isNot(contains('if (sameObservableIdentity && samePhysicalGeneration) {')));
  });

  test('legacy full-reconciliation batches only write rows that are new or actually changed', () {
    final scanStart = source.indexOf('Future<bool> _persistScanBatch');
    final scanEnd = source.indexOf('Future<void> _syncDeletions');
    expect(scanStart, greaterThanOrEqualTo(0));
    expect(scanEnd, greaterThan(scanStart));
    final body = source.substring(scanStart, scanEnd);

    // putAll() must run over a filtered subset, not every track in the batch
    // — otherwise a full legacy enumeration rewrites every unchanged row on
    // every single scan.
    expect(body, contains('final rowsToWrite = <Track>[];'));
    expect(body, contains('final rowChanged ='));
    expect(body, contains('if (rowChanged) rowsToWrite.add(track);'));
    expect(body, contains('if (rowsToWrite.isNotEmpty) await _isar.tracks.putAll(rowsToWrite);'));
    expect(body, isNot(contains('if (tracks.isNotEmpty) await _isar.tracks.putAll(tracks);')));
  });
}

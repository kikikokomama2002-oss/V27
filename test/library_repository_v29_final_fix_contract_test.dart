import 'dart:io';

import 'package:test/test.dart';

String _source() => File('lib/data/repositories/library_repository.dart').readAsStringSync();

String _between(String source, String start, String end) {
  final a = source.indexOf(start);
  expect(a, isNonNegative, reason: 'Missing start marker: $start');
  final b = source.indexOf(end, a + start.length);
  expect(b, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(a, b);
}

void main() {
  test('record-return early exits always return the reconciliation record', () {
    final source = _source();
    final fn = _between(
      source,
      'Future<({int deleted, bool recreated})> _reconcileMediaStoreChangeIdentitiesLocked',
      '  /// Single entry point for native MediaStore observer hints.',
    );
    expect(fn, contains('if (candidates.isEmpty) return (deleted: 0, recreated: false);'));
    expect(fn, contains('if (stale.isEmpty) return (deleted: 0, recreated: false);'));
    expect(fn, isNot(contains('return 0;')));
  });

  test('targeted reconciliation publishes tracksChanged before follow-up scan', () {
    final source = _source();
    final start = source.indexOf(
      'Future<int> reconcileMediaStoreChangeIdentities(',
    );
    expect(start, isNonNegative);

    final end = source.indexOf(
      'Future<({int deleted, bool recreated})> _reconcileMediaStoreChangeIdentitiesLocked',
      start,
    );
    expect(end, isNonNegative);

    final publicPath = source.substring(start, end);
    expect(publicPath, contains('final targetedMutation = result.deleted > 0 || result.recreated;'));

    final publishPos = source.indexOf(
      '_tracksChangedController.add(null)',
      start,
    );
    final followUpScanPos = source.indexOf(
      'unawaited(scanAndPersist().catchError((_) {}));',
      start,
    );
    expect(publishPos, isNonNegative);
    expect(followUpScanPos, isNonNegative);
    expect(publishPos, lessThan(followUpScanPos));

    final observerPath = _between(
      source,
      'Future<void> handleMediaStoreChanged({',
      '  Track _trackFromMediaStoreMap(',
    );
        final observerPublishPos = observerPath.indexOf('_tracksChangedController.add(null)');
        final observerScanPos = observerPath.indexOf('scanAndPersist(');
        expect(observerPublishPos, isNonNegative);
        expect(observerScanPos, isNonNegative);
        expect(observerPublishPos, lessThan(observerScanPos));
    });

  test('committed targeted deletions are emitted from finally', () {
    final source = _source();
    final fn = _between(
      source,
      'Future<({int deleted, bool recreated})> _reconcileMediaStoreChangeIdentitiesLocked',
      '  /// Single entry point for native MediaStore observer hints.',
    );
    expect(fn, contains('await _isar.tracks.deleteAll(idsToDelete);'));
    expect(fn, contains('} finally {'));
    expect(fn, contains('_tracksDeletedController.add(List.unmodifiable(deletedIdentities));'));
  });

  test('committed deletion reconciliation emits in finally around every post-delete await', () {
    final source = _source();
    final fn = _between(
      source,
      'Future<void> _syncDeletions(',
      '  /// Total track count via an indexed `count()`',
    );
    final deletePos = fn.indexOf('await _isar.tracks.deleteAll(idsToDelete);');
    final finallyPos = fn.indexOf('} finally {', deletePos);
    expect(deletePos, isNonNegative);
    expect(finallyPos, greaterThan(deletePos));
    expect(fn.substring(deletePos, finallyPos), contains('getMediaStoreVolumeStates'));
    expect(fn.substring(deletePos, finallyPos), contains('scanLibraryIdentities'));
    expect(fn.substring(finallyPos), contains('_tracksDeletedController.add(List.unmodifiable(deletedIdentities));'));
  });

  test('targeted reconciliation queues one serialized follow-up scan', () {
    final source = _source();
    final publicPath = _between(
      source,
      'Future<int> reconcileMediaStoreChangeIdentities(',
      '  Future<({int deleted, bool recreated})>',
    );
    expect(publicPath, contains('unawaited(scanAndPersist().catchError((_) {}));'));
    expect(source, isNot(contains('_pendingForceIdentityReconcile')));
    expect(source, isNot(contains('_pendingDeletionReconcile')));
  });

  test('scan page helper uses the single bounded page reader', () {
    final source = _source();
    expect(source, isNot(contains('_readScanPageWithEmptyRetry')));
    expect(source, contains('Future<List<Map<String, dynamic>>> _readScanPage({'));
  });
}

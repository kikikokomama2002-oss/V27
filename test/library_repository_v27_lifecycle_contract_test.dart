import 'dart:io';

import 'package:test/test.dart';

import 'source_contract_helpers.dart';

String _readRepo() =>
    File('lib/data/repositories/library_repository.dart').readAsStringSync();

void main() {
  test('math.min compile blocker is removed without changing the import shape', () {
    final source = _readRepo();
    expect(source, contains("import 'dart:math';"));
    expect(source, contains('final index = min('));
    expect(source, isNot(contains('math.min(')));
  });

  test('repository sync work is visible before the queued worker starts', () {
    final source = _readRepo();
    final enqueue = extractBlock(source, 'Future<T> _enqueueSync<T>');
    final scanApi = extractBlock(source, 'Future<void> scanAndPersist({');
    final snapshot = extractBlock(source, 'Future<int> waitForStableSnapshot()');

    expect(enqueue, contains('_repositorySyncPendingCount++;'));
    expect(enqueue, contains('_repositorySyncPendingCount--;'));
    expect(snapshot, contains('_repositorySyncPendingCount == 0'));
    expect(snapshot, contains('_pendingScanRequests == 0'));
    expect(scanApi, contains('_pendingScanRequests++;'));
    expect(source, contains('_scanInFlight ?? _pendingScanDrain?.future'));
  });

  test('disposed periodic reconciliation cannot cross async boundaries into a scan', () {
    final source = _readRepo();
    final periodic = extractBlock(
      source,
      'Future<void> _runPeriodicDeletionReconciliation()',
    );

    expect(occursInOrder(periodic, [
      'if (_disposed || _periodicDeletionReconciliationInFlight) return;',
      'await SharedPreferences.getInstance();',
      'if (_disposed) return;',
      'await PlayerChannel.instance',
      'observerNeedsDeletionReconciliation();',
      'if (_disposed) return;',
      'if (_disposed || !due) return;',
      'await scanAndPersist(reconcileDeletions: true);',
    ]), isTrue);
  });

  test('failed coalesced scans preserve recovery requirements through the pending queue', () {
    final source = _readRepo();
    final drain = extractBlock(source, 'Future<void> _drainScanRequestQueue()');

    expect(occursInOrder(drain, [
      'final batch = _takePendingScanRequests();',
      'scan = _runCoalescedScan(',
      'await scan;',
      '_pendingScanRequestQueue.insert(',
      'forceFullIdentityReconcile: batch.forceFullIdentityReconcile,',
      'reconcileDeletions: batch.reconcileDeletions,',
    ]), isTrue);
    expect(source, isNot(contains('_pendingForceIdentityReconcile')));
    expect(source, isNot(contains('_pendingDeletionReconcile')));
    expect(source, isNot(contains('followUpGeneration')));
  });

  test('Track mapping is centralized and stale dead-code findings are removed', () {
    final source = _readRepo();
    expect(RegExp(r'\bTrack\(\)').allMatches(source).length, 1);
    expect(RegExp(r'_trackFromMediaStoreMap\(').allMatches(source).length, 4);
    expect(source, isNot(contains('var deletedCount = 0;')));
    expect(source, isNot(contains('return deletedCount;')));
    expect(source, contains('Future<void> _syncDeletions({'));
    expect(source, isNot(contains('maxTextInputLength')));
    expect(
      source,
      contains('if (normalizedQuery.isEmpty) {\n      return const <String>[];\n    }'),
    );
    expect(source, isNot(contains('return normalizedQuery.isEmpty ? const <String>[] : null;')));
  });
}

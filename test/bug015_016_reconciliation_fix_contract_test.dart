import 'dart:io';

import 'package:test/test.dart';

void main() {
  final root = Directory.current.path;
  final repo =
      File('$root/lib/data/repositories/library_repository.dart').readAsStringSync();
  final provider = File('$root/lib/core/providers.dart').readAsStringSync();
  final libraryScreen =
      File('$root/lib/features/library/library_screen.dart').readAsStringSync();

  test('normal scans do not request unconditional deletion reconciliation', () {
    final start = repo.indexOf('Future<void> scanAndPersist({');
    final end = repo.indexOf('Future<void> _drainScanRequestQueue()', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final publicApi = repo.substring(start, end);
    expect(publicApi, contains('bool reconcileDeletions = false'));
    expect(publicApi, isNot(contains('reconcileDeletions: true')));
    expect(libraryScreen, contains('scanAndPersist(reconcileDeletions: true)'));
  });

  test('missed observer deletions have durable periodic convergence', () {
    expect(repo, contains('last_deletion_reconciliation_timestamp_ms_v1'));
    expect(repo, contains('Timer.periodic('));
    expect(repo, contains('_deletionReconciliationCheckInterval'));
    expect(repo, contains('_deletionReconciliationInterval'));
    expect(repo, contains('scanAndPersist(reconcileDeletions: true)'));
    expect(repo, contains('prefs.setInt(_lastDeletionReconciliationKey, nowMs)'));
    expect(provider, contains('ref.onDispose(repo.dispose)'));
  });

  test('periodic deletion reconciliation is single-flight', () {
    expect(repo, contains('_periodicDeletionReconciliationInFlight'));
    expect(repo, contains('if (_periodicDeletionReconciliationInFlight) return;'));
    expect(repo, contains('_periodicDeletionReconciliationInFlight = true;'));
    expect(repo, contains('_periodicDeletionReconciliationInFlight = false;'));
    expect(repo, contains('finally {'));
  });
}

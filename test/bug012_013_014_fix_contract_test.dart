import 'dart:io';

import 'package:test/test.dart';

void main() {
  final root = Directory.current.path;
  final repository = File('$root/lib/data/repositories/library_repository.dart').readAsStringSync();
  final lyrics = File('$root/android/app/src/main/kotlin/com/example/musicplayer/lyrics/SidecarLyricsResolver.kt').readAsStringSync();

  test('BUG-012 observer deletion uses strict validation before destructive reconciliation', () {
    final observerStart = repository.indexOf('Future<({int deleted, bool recreated})> _reconcileMediaStoreChangeIdentitiesLocked');
    expect(observerStart, greaterThanOrEqualTo(0));
    final observer = repository.substring(observerStart);
    expect(observer, contains('findExistingMediaStoreIdentities(validationPayload)'));
    expect(observer, contains('findExistingMediaStoreObserverIdentities(payload)'));
    expect(observer, contains('!presentNow.contains'));
  });

  test('BUG-013 clean process restart is not gated by process-local completion flag', () {
    expect(repository, contains('final forceIdentityReconciliation ='));
    final start = repository.indexOf('final forceIdentityReconciliation =');
    final end = repository.indexOf(';', start);
    final expression = repository.substring(start, end);
    expect(expression, isNot(contains('_identityReconciliationCompletedForProcess')));
  });

  test('BUG-014 timed-out provider has bounded quarantine and releases active capacity', () {
    expect(lyrics, contains('PROVIDER_QUARANTINE_MAX'));
    expect(lyrics, contains('quarantinePermits'));
    expect(lyrics, contains('quarantinePermits.availablePermits() == 0'));
    expect(lyrics, contains('if (quarantined) releasePermit()'));
  });
}

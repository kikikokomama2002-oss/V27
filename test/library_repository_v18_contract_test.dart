import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'source_contract_helpers.dart';

void main() {
  test('modern deletion path is targeted instead of unconditional full reconciliation', () {
    final repo = File('lib/data/repositories/library_repository.dart').readAsStringSync();
    final controller = File('lib/playback/playback_controller.dart').readAsStringSync();
    final native = File(
      'android/app/src/main/kotlin/com/example/musicplayer/channels/PlayerChannel.kt',
    ).readAsStringSync();

    final reconciliation = extractBlock(repo, 'Future<({int deleted, bool recreated})> _reconcileMediaStoreChangeIdentitiesLocked');
    final scanImpl = extractBlock(repo, '  }) async {\n    var changedAny = false;', markerContainsOpeningBrace: true);
    final recovery = extractBlock(repo, 'if (effectiveReconcileDeletions || forceIdentityReconciliation)');
    final observerHandler = extractBlock(controller, 'if (repo != null) {', markerContainsOpeningBrace: true);
    final identityScanBranch = extractBlock(native, '"scanLibraryIdentities" -> {', markerContainsOpeningBrace: true);
    final observer = extractBlock(native, 'private fun newMediaStoreObserver()', markerContainsOpeningBrace: true);

    expect(reconciliation, contains('mediaStoreVolumeMediaStoreIdEqualTo'));
    expect(reconciliation, contains('reconcileMediaStoreChangeIdentities'));
    expect(observerHandler, contains("rawArgs['identities']"));
    expect(identityScanBranch, contains('MediaStoreScanner.scanAudioIdentities'));
    expect(observer, contains('ContentUris.parseId(uri)'));
    expect(observer, contains('uri.pathSegments.firstOrNull'));
    expect(observer, contains('Build.VERSION_CODES.Q'));
    expect(scanImpl, contains('final effectiveReconcileDeletions ='));
    expect(recovery, contains("currentVolumeStates[volume]?['generationSupported'] != true"));
    expect(recovery, contains('fullScanVolumes.add(volume);'));
    expect(scanImpl, isNot(contains('final modernReconciliationDue = false')));

    final syncBody = scanImpl;
    expect(occursInOrder(syncBody, [
      'await prefs.setBool(_syncInProgressKey, true);',
      'await prefs.setBool(_syncInProgressKey, false);',
    ]), isTrue);

    expect(observerHandler, contains('rawIdentities.every'));
    expect(observerHandler, contains('final unknown = !payloadValid || rawUnknown == true;'));
    expect(recovery, contains("if (currentVolumeStates[volume]?['generationSupported'] != true) {"));
  });
}

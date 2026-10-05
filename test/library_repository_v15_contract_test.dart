import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/data/repositories/library_repository.dart').readAsStringSync();

  test('legacy/non-generation volumes are forced onto full enumeration on every scan', () {
    final fullScanStart = source.indexOf('final fullScanVolumes = <String>{};');
    final guard = source.indexOf(
      "if (currentVolumeStates[volume]?['generationSupported'] != true) {",
      fullScanStart,
    );
    final volumeLoopState = source.indexOf(
      'final oldState = persistedVolumeStates[volume];',
      guard,
    );
    expect(fullScanStart, greaterThanOrEqualTo(0));
    expect(guard, greaterThan(fullScanStart));
    expect(volumeLoopState, greaterThan(guard));
    expect(source, contains('final forceIdentityReconciliation ='));
    expect(source, contains('if (effectiveReconcileDeletions || forceIdentityReconciliation) {'));
    expect(source, contains('deletionReconciliationVolumes.addAll(currentVolumes);'));
    expect(source, contains('DATE_MODIFIED is a filesystem timestamp, not an authoritative change'));
    expect(source, contains('fullScanVolumes.add(volume);'));
  });

  test('generation cursor is persisted only after end-of-scan stability check', () {
    final stableCheck = source.indexOf('MediaStore generation/version/lifecycle changed during scan');
    final cursorPersist = source.indexOf('prefs.setString(\n      _mediaStoreGenerationCursorsKey', stableCheck);
    expect(stableCheck, greaterThanOrEqualTo(0));
    expect(cursorPersist, greaterThan(stableCheck));
  });

  test('search page/count/position retain one shared zero-token contract', () {
    expect(source, contains('static List<String>? _searchTerms(String query)'));
    expect(source, contains('query.trim().isEmpty ? tracksCount() : Future<int>.value(0)'));
    expect(source, contains('if (query.trim().isNotEmpty) return null;'));
    expect(source, contains('return allTracksPosition(volume, mediaStoreId);'));
  });

  test('identity lookup stays volume-aware', () {
    expect(
      source,
      contains('mediaStoreVolumeMediaStoreIdEqualTo(normalizedVolume, id)'),
    );
  });

  test('repository page/resource guards remain in place', () {
    expect(source, contains('maxPageSize = 500'));
    expect(source, contains('maxPageOffset = 5000000'));
    expect(source, contains('maxSearchTerms = 128'));
    expect(source, contains('if (query.length > maxSearchQueryLength) return null;'));
    expect(source, contains('if (volume.length > maxVolumeLength || id <= 0)'));
  });
}

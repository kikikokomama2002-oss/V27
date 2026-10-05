import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('repository hot identity paths are index-backed, not collection filters', () {
    final source = File('lib/data/repositories/library_repository.dart').readAsStringSync();
    expect(source, contains('anyOf(\n              ids,\n              (q, id) =>\n                  q.mediaStoreVolumeMediaStoreIdEqualTo(group.key, id),\n            )'));
    expect(source, contains('mediaStoreVolumeMediaStoreIdEqualTo(normalizedVolume, id)'));
  });

  test('legacy reconciliation preserves derived state when observable identity matches and no generation contradicts it', () {
    final source = File('lib/data/repositories/library_repository.dart').readAsStringSync();
    // Generation absence on both sides (every API 24-29 scan) must be a
    // neutral signal, not treated the same as a mismatch — otherwise every
    // unchanged legacy track gets its derived cache wiped and rewritten on
    // every single scan, forever, with no actual change on disk.
    expect(source, contains('final generationMismatch ='));
    expect(source, contains('if (sameObservableIdentity && !generationMismatch && !invalidateDerivedCache) {'));
    expect(source, isNot(contains('samePhysicalGeneration')));
    // A genuine mismatch (only possible where a generation is available on
    // both sides — API 30+) must still invalidate derived state.
    expect(source, contains('track.embeddedLyricsText = null;'));
    expect(source, contains('track.lyricsChecked = false;'));
    expect(source, contains('track.derivedCacheEpoch = _libraryGeneration;'));
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'source_contract_helpers.dart';

void main() {
  test('V30 lyrics force contract', () {
  final source = File(
    'lib/data/repositories/library_repository.dart',
  ).readAsStringSync();

  contractExpect(
    source,
    "final key = '${r"${track.mediaStoreVolume}"}:${r"${track.mediaStoreId}"}:gen=${r"${track.mediaStoreGenerationModified ?? -1}"}:epoch=${r"${track.derivedCacheEpoch}"}:${r"${track.dateModified}"}:${r"${track.contentUri}"}:${r"${track.durationMs}"}:${r"${track.displayName}"}:${r"${track.relativePath ?? ''}"}:${r"${track.title}"}:${r"${track.artist}"}:${r"${track.album}"}:force=\$forceRefresh';",
    'ensureLyrics in-flight key must include forceRefresh',
  );

  contractExpect(
    source,
    'final inFlight = _lyricsInFlight[key];',
    'ensureLyrics must consult the force-aware key before joining an in-flight request',
  );

  contractExpect(
    source,
    'final future = _ensureLyricsInternal(track, forceRefresh: forceRefresh);',
    'ensureLyrics must preserve forceRefresh when starting the request',
  );

  contractExpectAbsent(
    source,
    'Force-refresh bypasses the cached value, but still joins an already',
    'old contract must not claim forced and non-forced requests share an in-flight key',
  );
  });
}

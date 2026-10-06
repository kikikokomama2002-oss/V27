import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'source_contract_helpers.dart';

void main() {
  test('V32 release contract', () {
  final source = readProjectFile('lib/data/repositories/library_repository.dart');
  final native = readProjectFile(
    'android/app/src/main/kotlin/com/example/musicplayer/scanner/MediaStoreScanner.kt',
  );
  final channel = readProjectFile(
    'android/app/src/main/kotlin/com/example/musicplayer/channels/PlayerChannel.kt',
  );

  // Full timestamp scans must use the same unbounded value as Kotlin
  // Long.MAX_VALUE. Native timestamp mode applies DATE_MODIFIED <= until;
  // zero is a real lower-than-all-media bound, not an "unbounded" sentinel.
  expectContains(
    source,
    'untilTimestamp: effectiveVolumeFullScan\n              ? 9223372036854775807',
  );
  expectNotContains(
    source,
    'untilTimestamp: effectiveVolumeFullScan\n              ? 0',
  );
  expectContains(native, 'untilTimestampSeconds: Long = Long.MAX_VALUE');
  expectContains(native, 'MediaStore.Audio.Media.DATE_MODIFIED} <= ?');
  expectContains(channel, 'argumentLong(call, "untilTimestampSeconds", Long.MAX_VALUE)');

  // Concurrent lyrics lookups: a stale row must suppress only the DB write,
  // not discard the text already loaded for the caller's Track snapshot.
  expectContains(source, 'return text;');
  expectNotContains(source, 'String? committedText;');
  expectNotContains(source, 'committedText = text;');

  // Scan operations are serialized by _enqueueSync, so the old in-flight
  // request-generation follow-up mechanism must not remain as dead code.
  expectNotContains(source, '_scanRequestGeneration');
  expectNotContains(source, '_scanCoveredRequestGeneration');
  expectNotContains(source, '_pendingForceIdentityReconcile');
  expectNotContains(source, '_pendingDeletionReconcile');
  expectNotContains(source, 'followUpGeneration');

  // A caught ordinary incremental failure is not a crash. Do not leave the
  // durable crash marker set and force every retry into O(N) recovery. Explicit
  // recovery/deletion passes and previously detected interrupted syncs remain
  // conservative.
  expectContains(source, 'if (!interruptedSync &&\n          !forceFullIdentityReconcile &&\n          !effectiveReconcileDeletions)');
  expectContains(source, 'await prefs.setBool(_syncInProgressKey, false);');
  });
}

import 'dart:io';

import 'package:test/test.dart';

import 'source_contract_helpers.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final root = Directory.current.path;

  test('legacy artwork threads cancellation into platform thumbnail APIs', () {
    final source = _read('$root/android/app/src/main/kotlin/com/example/musicplayer/scanner/AlbumArtLoader.kt');
    final body = extractBlock(source, 'private suspend fun loadViaThumbnail(');
    expect(body, contains('context.contentResolver.loadThumbnail('));
    expect(body, contains('onCancel = { cancellationSignal.cancel() }'));
    expect(body, contains('cancellationSignal,'));
    expect(body, contains('} ?: return null'));
    expect(body, isNot(contains('Legacy artwork provider returned an indeterminate null result')));
  });

  test('legacy null artwork is retried rather than immediately treated as definitive absence', () {
    final source = _read('$root/android/app/src/main/kotlin/com/example/musicplayer/scanner/AlbumArtLoader.kt');
    final legacy = extractBlock(source, 'private suspend fun loadLegacyAudioThumbnail');
    expect(legacy, contains('val retryBitmap = try'));
    expect(legacy, contains('MediaStore.Audio.Thumbnails.MINI_KIND'));
    expect(legacy, contains('retryBitmap ?: return@run null'));
    expect(legacy, isNot(contains('Legacy artwork provider returned an indeterminate null result')));
  });

  test('process-start recovery fully enumerates non-generation volumes', () {
    final source = _read('$root/lib/data/repositories/library_repository.dart');
    final recovery = extractBlock(source, 'if (effectiveReconcileDeletions || forceIdentityReconciliation)');
    expect(recovery, contains("currentVolumeStates[volume]?['generationSupported'] != true"));
    expect(recovery, contains('fullScanVolumes.add(volume)'));
  });

  test('observer identities have a targeted MediaStore upsert path', () {
    final dartSource = _read('$root/lib/playback/player_channel.dart');
    final repoSource = _read('$root/lib/data/repositories/library_repository.dart');
    final kotlinSource = _read('$root/android/app/src/main/kotlin/com/example/musicplayer/channels/PlayerChannel.kt');
    final dartIdentityCall = extractBlock(
      dartSource,
      'required List<int> ids,\n  }) async {',
      markerContainsOpeningBrace: true,
    );
    final repoIdentityUpsert = extractBlock(repoSource, 'Future<bool> _upsertMediaStoreChangeIdentitiesLocked(');
    final kotlinIdentityBranch = extractBlock(kotlinSource, '"scanLibraryIdentities" -> {', markerContainsOpeningBrace: true);
    expect(
      dartIdentityCall,
      contains("_method.invokeMethod<List<dynamic>>("),
    );
    expect(dartIdentityCall, contains("'scanLibraryIdentities'"));
    expect(repoIdentityUpsert, contains('_upsertMediaStoreChangeIdentitiesLocked'));
    expect(kotlinIdentityBranch, contains('"scanLibraryIdentities" ->'));
  });

  test('legacy volumes are not unconditionally full-scanned on every refresh', () {
    final repoSource = _read('$root/lib/data/repositories/library_repository.dart');
    final channelSource = _read('$root/lib/playback/player_channel.dart');
    final scanImpl = extractBlock(
      repoSource,
      'Future<void> _scanAndPersistInternalImpl({\n    bool forceFullIdentityReconcile = false,\n    bool reconcileDeletions = false,\n  }) async {',
      markerContainsOpeningBrace: true,
    );
    final scanPage = extractBlock(
      channelSource,
      'int limit = 500,\n  }) async {',
      markerContainsOpeningBrace: true,
    );
    expect(scanPage, contains('final sinceSeconds = sinceTimestamp ~/ 1000;'));
    expect(scanPage, contains('untilTimestamp <= 0'));
    expect(scanPage, contains("'sinceTimestampSeconds': sinceSeconds"));
    expect(scanPage, contains("'untilTimestampSeconds': untilSeconds"));
    expect(repoSource, isNot(contains('final legacyDeletionRequiresFullScan')));
    expect(repoSource, isNot(contains('if (legacyDeletionRequiresFullScan)')));
    expect(scanImpl, contains("currentVolumeStates[volume]?['generationSupported'] != true"));
    expect(scanImpl, contains('fullScanVolumes.add(volume)'));
  });

  test('storage lifecycle epoch advances only across availability loss', () {
    final source = _read('$root/android/app/src/main/kotlin/com/example/musicplayer/channels/PlayerChannel.kt');
    final lifecycle = extractBlock(source, 'private fun recordStorageState(');
    final playerChannelState = extractBlock(source, 'private val storageLifecycleStates = ConcurrentHashMap<String, String>()');
    expect(playerChannelState, contains('private val storageLifecycleStates'));
    expect(lifecycle, contains('val wasAvailable = previous == Environment.MEDIA_MOUNTED'));
    expect(lifecycle, contains('val isUnavailable = state == Environment.MEDIA_REMOVED'));
    expect(lifecycle, contains('(previous == null && isUnavailable) || (wasAvailable && isUnavailable)'));
    expect(lifecycle, isNot(contains('incrementStorageLifecycleGeneration(mediaStoreVolumeForStorageVolume(volume))')));
  });

  test('deletion identity comparison uses canonical metadata normalization', () {
    final source = _read('$root/android/app/src/main/kotlin/com/example/musicplayer/scanner/MediaStoreScanner.kt');
    final identityCheck = extractBlock(source, 'suspend fun findExistingMediaStoreIdentities(');
    expect(identityCheck, contains('canonicalIdentityText(expected.title, "Unknown Title")'));
    expect(identityCheck, contains('canonicalIdentityText(expected.artist, "Unknown Artist")'));
    expect(identityCheck, contains('canonicalIdentityText(expected.album, "Unknown Album")'));
  });

  test('lyrics Error path always terminates the MethodChannel result', () {
    final source = _read('$root/android/app/src/main/kotlin/com/example/musicplayer/channels/PlayerChannel.kt');
    final lyrics = extractBlock(source, '"getLyrics" -> {', markerContainsOpeningBrace: true);
    expect(lyrics, contains('catch (e: Error)'));
    expect(lyrics, contains('result.error("LYRICS_PROVIDER_UNAVAILABLE", e.message, null)'));
  });
}

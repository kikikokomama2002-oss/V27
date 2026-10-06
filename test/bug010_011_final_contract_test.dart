import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'source_contract_helpers.dart';

void main() {
  const albumArt = 'android/app/src/main/kotlin/com/example/musicplayer/scanner/AlbumArtLoader.kt';
  const embedded = 'android/app/src/main/kotlin/com/example/musicplayer/lyrics/EmbeddedLyricsReader.kt';
  const sidecar = 'android/app/src/main/kotlin/com/example/musicplayer/lyrics/SidecarLyricsResolver.kt';
  const channel = 'android/app/src/main/kotlin/com/example/musicplayer/channels/PlayerChannel.kt';

  test('BUG-010 preserves ResourceException before generic provider mapping', () {
    final source = File(albumArt).readAsStringSync();
    final body = extractBlock(source, 'private suspend fun loadViaThumbnail(');
    expect(occursInOrder(body, [
      'catch (e: ResourceException)',
      'catch (e: ProviderException)',
      'catch (e: Exception)',
    ]), isTrue);
  });

  test('BUG-010 channel preserves resource failures instead of provider-retrying them', () {
    final source = File(channel).readAsStringSync();
    final body = extractBlock(source, '"getAlbumArt" -> {', markerContainsOpeningBrace: true);
    expect(occursInOrder(body, [
      'catch (e: AlbumArtLoader.ResourceException)',
      'catch (e: AlbumArtLoader.ProviderException)',
    ]), isTrue);
    expect(body, contains('result.error("ARTWORK_RESOURCE_UNAVAILABLE", e.message, null)'));
  });

  test('BUG-011 embedded reader never converts generic read failure to null', () {
    final source = File(embedded).readAsStringSync();
    final reader = extractBlock(source, 'suspend fun read(context: Context, contentUri: String)');
    expect(source, contains('class ProviderException'));
    expect(reader, contains('throw ProviderException("Embedded lyrics provider failed", e)'));
    expect(reader, isNot(contains('Malformed tags, an unsupported container')));
  });

  test('BUG-011 MediaStore query failures remain typed failures', () {
    final source = File(sidecar).readAsStringSync();
    final resolver = extractBlock(source, 'private fun viaMediaStore(');
    expect(resolver, contains('throw ProviderException("MediaStore lyrics query returned null cursor")'));
    expect(resolver, contains('throw ProviderException("MediaStore lyrics provider failed", e)'));
  });

  test('BUG-011 SAF access absence is typed, not an authoritative no-lyrics result', () {
    final source = File(sidecar).readAsStringSync();
    final volumeResolver = extractBlock(source, 'private fun resolveTrackVolume(context: Context, volume: String?): String');
    final pathValidator = extractBlock(source, 'private fun validateRelativePath(relativePath: String?): String');
    final findBody = extractBlock(source, 'suspend fun find(');
    final safBody = extractBlock(source, 'private fun viaSaf(');
    final accessException = extractBlock(source, 'class AccessUnavailableException(');
    expect(accessException, contains('class AccessUnavailableException('));
    expect(safBody, contains('if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)'));
    expect(safBody, contains('throw AccessUnavailableException'));
    expect(safBody, isNot(contains('if (granted.isEmpty()) return null')));
    expect(pathValidator, contains('Track relative path is unavailable; sidecar lookup is indeterminate'));
    expect(pathValidator, contains('it == ".."'));
    expect(pathValidator, contains('it == "."'));
    expect(pathValidator, contains('Track relative path is invalid; sidecar lookup is indeterminate'));
    expect(findBody, contains('Track media volume is unavailable or invalid; sidecar lookup is indeterminate'));
    expect(volumeResolver, contains('MediaStore.getExternalVolumeNames(context)'));
    expect(volumeResolver, contains('normalized !in knownVolumes'));
    expect(volumeResolver, contains('else if (normalized != PRIMARY_VOLUME)'));
    expect(findBody, contains('Track media volume cannot be resolved on this Android version; sidecar lookup is indeterminate'));
    expect(findBody, contains("Before Android Q the app's scanner exposes only the legacy"));
    expect(findBody, contains('under the canonical external_primary identity'));
    expect(findBody, contains('Track media volume is not currently exposed by MediaStore; sidecar lookup is indeterminate'));
  });

  test('BUG-011 channel falls back after embedded provider failure but never caches it as null', () {
    final source = File(channel).readAsStringSync();
    final body = extractBlock(source, '"getLyrics" -> {', markerContainsOpeningBrace: true);
    expect(body, contains('EmbeddedLyricsReader.ProviderException?'));
    expect(body, contains('EmbeddedLyricsReader.TransientReadException?'));
    expect(body, contains('} catch (e: EmbeddedLyricsReader.ProviderException) {'));
    expect(body, contains('"LYRICS_PROVIDER_UNAVAILABLE"'));
    expect(body, contains('"LYRICS_ACCESS_UNAVAILABLE"'));
  });
}

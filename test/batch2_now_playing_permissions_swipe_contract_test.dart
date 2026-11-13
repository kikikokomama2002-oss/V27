import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current;

  String read(String path) => File('${root.path}/$path').readAsStringSync();

  test('Now Playing exposes the shared seven-action menu in approved order', () {
    final source = read('lib/features/player/now_playing_screen.dart');
    final menu = source.substring(source.indexOf("itemBuilder: (_) => ["), source.indexOf("],\n            ),", source.indexOf("itemBuilder: (_) => [")));
    final values = ["'set_as'", "'share'", "'delete'", "'details'", "'add_to_playlist'", "'album'", "'artist'"];
    var cursor = -1;
    for (final value in values) {
      final next = menu.indexOf(value);
      expect(next, greaterThan(cursor), reason: '$value should retain the shared context-menu order');
      cursor = next;
    }
    expect(source, contains('deleteMediaStoreTrack(track.contentUri)'));
    expect(source, contains('setTrackAsDefaultSound'));
    expect(source, contains('shareTrackFile'));
    expect(source, contains('store.addTrack(playlistId, track)'));
    for (final path in ['lib/features/library/library_screen.dart', 'lib/features/library/library_dashboard.dart']) {
      final librarySource = read(path);
      final menuStart = librarySource.indexOf("itemBuilder: (_) => [");
      expect(menuStart, greaterThanOrEqualTo(0), reason: '$path should expose the same track menu');
      final menuEnd = librarySource.indexOf('],', menuStart);
      final menu = librarySource.substring(menuStart, menuEnd);
      var previous = -1;
      for (final value in values) {
        final next = menu.indexOf(value);
        expect(next, greaterThan(previous), reason: '$path menu order mismatch at $value');
        previous = next;
      }
    }
  });

  test('Library tab view uses responsive page swipe physics', () {
    final source = read('lib/features/library/library_screen.dart');
    expect(source, contains('physics: const _LibraryTabScrollPhysics()'));
    expect(source, contains('double get minFlingDistance => 7'));
    expect(source, contains('double get minFlingVelocity => 70'));
  });

  test('Android deletion stays scoped to MediaStore user confirmation', () {
    final native = read('android/app/src/main/kotlin/com/example/musicplayer/channels/PlayerChannel.kt');
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    expect(native, contains('MediaStore.createDeleteRequest(context.contentResolver, listOf(uri))'));
    expect(native, contains('Only MediaStore content URIs can be deleted'));
    expect(manifest, contains('android.permission.READ_MEDIA_AUDIO'));
    expect(manifest, isNot(contains('MANAGE_EXTERNAL_STORAGE')));
    final permissions = read('lib/core/permissions.dart');
    final startup = read('lib/main.dart');
    expect(permissions, contains('Permission.audio.request()'));
    expect(permissions, contains('Permission.notification.request()'));
    expect(startup, contains('await PermissionsHelper.requestAudioPermission()'));
    expect(startup, contains('await PermissionsHelper.requestNotificationPermission()'));
  });
}

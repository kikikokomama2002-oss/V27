import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;
  final screen = File('$root/lib/features/library/library_screen.dart').readAsStringSync();
  final dashboard = File('$root/lib/features/library/library_dashboard.dart').readAsStringSync();
  final playerChannel = File('$root/lib/playback/player_channel.dart').readAsStringSync();
  final nativeChannel = File('$root/android/app/src/main/kotlin/com/example/musicplayer/channels/PlayerChannel.kt').readAsStringSync();
  final activity = File('$root/android/app/src/main/kotlin/com/example/musicplayer/MainActivity.kt').readAsStringSync();
  final manifest = File('$root/android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final pubspec = File('$root/pubspec.yaml').readAsStringSync();

  test('Quick picks sample distinct random positions from the whole library', () {
    expect(File('$root/lib/core/providers.dart').readAsStringSync(), contains('Random.secure()'));
    expect(File('$root/lib/core/providers.dart').readAsStringSync(), contains('positions.add(random.nextInt(count))'));
    expect(File('$root/lib/core/providers.dart').readAsStringSync(), contains('queueIndex: queueIndexes[index]'));
    expect(dashboard, contains('startIndex: pick.queueIndex'));
  });

  test('Playlist selection opens a lazy detail page instead of autoplaying', () {
    expect(dashboard, contains('class LibraryPlaylistDetailPage'));
    expect(dashboard, contains("'Here it is, your playlist!'"));
    expect(dashboard, contains('ListView.builder('));
    expect(dashboard, contains('playlistTrackAtProvider'));
    expect(dashboard, contains('_openPlaylistDetail(context, playlist)'));
    expect(dashboard, contains('startTrack: track'));
  });

  test('Library entry presents the split-logo opening animation', () {
    expect(screen, contains('class _OpeningAnimationOverlay'));
    expect(screen, contains('AnimationController('));
    expect(screen, contains("'assets/v27_icon.png'"));
    expect(pubspec, contains('- assets/v27_icon.png'));
  });

  test('Track overflow menu includes every requested action and keeps playlist add', () {
    expect(screen, contains("Text('Add to playlist')"));
    for (final label in ['Delete', 'Share', 'Track details', 'Album', 'Artist', 'Set as']) {
      expect(screen, contains("label: '$label'"));
    }
    expect(screen, contains('_deleteTrackFromDevice'));
    expect(screen, contains('_shareTrackFile'));
    expect(screen, contains('_showTrackDetails'));
    expect(screen, contains('LibraryGroupDetailPage'));
    expect(screen, contains('_showSetAsOptions'));
  });

  test('Native file actions use MediaStore confirmation and system sound settings', () {
    expect(playerChannel, contains("'shareTrackFile'"));
    expect(playerChannel, contains("'deleteMediaStoreTrack'"));
    expect(playerChannel, contains("'setTrackAsDefaultSound'"));
    expect(nativeChannel, contains('MediaStore.createDeleteRequest'));
    expect(nativeChannel, contains('Intent.FLAG_GRANT_READ_URI_PERMISSION'));
    expect(nativeChannel, contains('Settings.System.canWrite(context)'));
    expect(nativeChannel, contains('RingtoneManager.setActualDefaultRingtoneUri'));
    expect(activity, contains('StartIntentSenderForResult'));
    expect(manifest, contains('android.permission.WRITE_SETTINGS'));
  });
}

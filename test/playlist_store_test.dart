import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lib/core/playlist_store.dart';
import '../lib/data/db/track.dart';
import '../lib/playback/queue_spec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('playlist identity survives JSON serialization', () {
    const identity = PlaylistTrackIdentity(
      volume: 'external_primary',
      mediaStoreId: 42,
    );

    final restored = PlaylistTrackIdentity.fromJson(identity.toJson());

    expect(restored.volume, 'external_primary');
    expect(restored.mediaStoreId, 42);
    expect(restored.key, 'external_primary:42');
  });

  test('playlist queue spec survives queue descriptor serialization', () {
    const spec = PlaylistQueueSpec('playlist_abc');

    final restored = QueueSpec.fromMap(spec.toMap());

    expect(restored, isA<PlaylistQueueSpec>());
    final playlistSpec = restored! as PlaylistQueueSpec;
    expect(playlistSpec.playlistId, 'playlist_abc');
    expect(playlistSpec.queryKey, 'playlist:playlist_abc');
  });

  test('playlist names are case-insensitively unique and persisted', () async {
    final store = PlaylistStoreController();
    await store.ready;

    final created = await store.createPlaylist('Favorites');
    expect(created, isNotNull);
    final playlist = created!;
    expect(await store.createPlaylist('favorites'), isNull);

    final track = Track()..mediaStoreId = 42;
    expect(await store.addTrack(playlist.id, track), isTrue);
    expect(await store.addTrack(playlist.id, track), isFalse);

    await store.setAvoidDuplicateSongs(false);
    expect(store.state.avoidDuplicateSongs, isFalse);
    expect(await store.addTrack(playlist.id, track), isTrue);
    store.dispose();

    final restored = PlaylistStoreController();
    await restored.ready;
    expect(restored.state.playlists, hasLength(1));
    expect(restored.state.playlists.single.name, 'Favorites');
    expect(restored.state.playlists.single.songs, hasLength(2));
    expect(restored.state.avoidDuplicateSongs, isFalse);
    restored.dispose();
  });
}

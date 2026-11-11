import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;
  final tabs = File('$root/lib/core/library_tab_settings.dart').readAsStringSync();
  final screen = File('$root/lib/features/library/library_screen.dart').readAsStringSync();
  final dashboard = File('$root/lib/features/library/library_dashboard.dart').readAsStringSync();
  final providers = File('$root/lib/core/providers.dart').readAsStringSync();
  final repository = File('$root/lib/data/repositories/library_repository.dart').readAsStringSync();

  test('Library opens on the dashboard and keeps all collection destinations', () {
    expect(tabs, contains('home(\'Home\''));
    expect(tabs, contains('tracks(\'Tracks\''));
    expect(tabs, contains('albums(\'Albums\''));
    expect(tabs, contains('artists(\'Artists\''));
    expect(tabs, contains('folders(\'Folders\''));
    expect(tabs, contains('playlists(\'Playlists\''));
    expect(screen, contains('TabController(length: _visibleTabs.length'));
    expect(screen, contains('LibraryTab.home => LibraryDashboard'));
    expect(screen, contains('LibraryTab.playlists => const LibraryPlaylistsTab()'));
  });

  test('Dashboard contains local-library shelves matching the reference layout', () {
    expect(dashboard, contains("'Speed dial'"));
    expect(dashboard, contains("title: 'Quick picks'"));
    expect(dashboard, contains("title: 'Albums in your library'"));
    expect(dashboard, contains("title: 'Explore artists'"));
    expect(dashboard, contains("title: 'Your playlists'"));
    expect(dashboard, contains("title: 'Browse folders'"));
    expect(dashboard, contains('CustomScrollView('));
    expect(dashboard, contains('ListView.builder('));
  });

  test('Dashboard queries are bounded and independent from Tracks search', () {
    expect(providers, contains('tracksPage(offset: 0, limit: 5)'));
    expect(providers, contains('firstTrackForGroup(key.field, key.name)'));
    expect(repository, contains('Future<Track?> firstTrackForGroup('));
    expect(repository, contains('.where().albumEqualTo(name).findFirst()'));
    expect(repository, contains('.where().artistEqualTo(name).findFirst()'));
    expect(repository, contains('.where().folderEqualTo(name).findFirst()'));
    expect(providers, contains('tracksCount()'));
    expect(providers, contains('repo.completeInitialLibraryRead()'));
    expect(dashboard, isNot(contains('searchQueryProvider')));
  });

  test('Dashboard playback uses the existing logical queue specifications', () {
    expect(dashboard, contains('const AllTracksQueueSpec()'));
    expect(dashboard, contains('GroupQueueSpec(field, group.name)'));
    expect(dashboard, contains('PlaylistQueueSpec(playlist.id)'));
    expect(dashboard, contains('repo.waitForStableSnapshot()'));
    expect(dashboard, contains('repo.libraryGeneration'));
    expect(dashboard, contains('startVolume:'));
    expect(dashboard, contains('startMediaStoreId:'));
  });

  test('Existing Library safety-critical controls remain mounted', () {
    expect(screen, contains('_manualRescan'));
    expect(screen, contains('const MiniPlayer()'));
    expect(screen, contains('SettingsScreen()'));
    expect(screen, contains('tracksPagingProvider'));
    expect(screen, contains('groupsPagingProvider'));
    expect(screen, contains('searchQueryProvider'));
  });
}

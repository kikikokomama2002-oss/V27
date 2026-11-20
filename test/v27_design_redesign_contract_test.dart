import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;
  final main = File('$root/lib/main.dart').readAsStringSync();
  final navigation = File(
    '$root/lib/core/widgets/v27_bottom_navigation.dart',
  ).readAsStringSync();
  final library = File('$root/lib/features/library/library_screen.dart')
      .readAsStringSync();
  final dashboard = File('$root/lib/features/library/library_dashboard.dart')
      .readAsStringSync();
  final player = File('$root/lib/features/player/now_playing_screen.dart')
      .readAsStringSync();
  final settings = File('$root/lib/features/settings/settings_screen.dart')
      .readAsStringSync();

  test('The four main destinations share the same navigation routes', () {
    expect(main, contains("'/now-playing': (_) => const NowPlayingScreen()"));
    expect(main, contains("'/settings': (_) => const SettingsScreen()"));
    expect(main, contains("'/equalizer': (_) => const EqualizerScreen()"));
    expect(navigation, contains("strings.text('home')"));
    expect(navigation, contains("strings.text('all_tracks')"));
    expect(navigation, contains("strings.text('now_playing')"));
    expect(navigation, contains("strings.text('settings')"));
    expect(library, contains('V27BottomNavigation('));
    expect(player, contains('V27BottomNavigation('));
    expect(settings, contains('V27BottomNavigation('));
  });

  test('Home dashboard actions use the real local library and playlists', () {
    expect(dashboard, contains('_HomeHeroSection(trackCount: trackCount)'));
    expect(dashboard, contains('strings.text(\'offline_library\')'));
    expect(dashboard, contains('_createPlaylist(context, ref)'));
    expect(dashboard, contains('playlistPreviewTrackProvider'));
    expect(dashboard, contains('const AllTracksQueueSpec()'));
  });

  test('Tracks redesign preserves indexed paging and full logical queues', () {
    expect(library, contains('tracksPagingProvider'));
    expect(library, contains('notifier.itemAt(index)'));
    expect(library, contains('final QueueSpec spec'));
    expect(library, contains('startIndex: index'));
    expect(library, contains("text('offline_library')"));
  });

  test('Now Playing controls are connected to existing playback operations', () {
    expect(player, contains('getRepeatCurrentTrackEnabled()'));
    expect(player, contains('setRepeatCurrentTrackEnabled(enabled)'));
    expect(player, contains('setPlaybackSpeed(speed)'));
    expect(player, contains('showSleepTimerSheet(context)'));
    expect(player, contains('_InlineLyricsPanel(track: track)'));
    expect(player, contains('_UpcomingQueuePanel()'));
    expect(player, contains("'add_to_playlist'"));
    final order = [
      player.indexOf("PopupMenuItem(value: 'set_as'"),
      player.indexOf("PopupMenuItem(value: 'share'"),
      player.indexOf("PopupMenuItem(value: 'delete'"),
      player.indexOf("PopupMenuItem(value: 'details'"),
      player.indexOf("PopupMenuItem(value: 'add_to_playlist'"),
      player.indexOf("PopupMenuItem(value: 'album'"),
      player.indexOf("PopupMenuItem(value: 'artist'"),
    ];
    expect(order.every((index) => index >= 0), isTrue);
    for (var i = 1; i < order.length; i++) {
      expect(order[i - 1], lessThan(order[i]));
    }
  });

  test('Settings redesign keeps all seven real accent themes and preferences', () {
    expect(settings, contains('accentOptions.map((option)'));
    expect(settings, contains('accentColorProvider.notifier).select(option.id)'));
    expect(settings, contains('languageProvider'));
    expect(settings, contains('themeModeProvider.notifier).setDarkMode(value)'));
    expect(settings, contains('const _QueueSettingsSetting()'));
    expect(settings, contains('const _PermissionsSetting()'));
    expect(settings, contains('const _CrossfadeSetting()'));
  });
}

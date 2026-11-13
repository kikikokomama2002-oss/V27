import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;
  final localization = File('$root/lib/core/localization.dart').readAsStringSync();
  final main = File('$root/lib/main.dart').readAsStringSync();
  final library = File('$root/lib/features/library/library_screen.dart').readAsStringSync();
  final dashboard = File('$root/lib/features/library/library_dashboard.dart').readAsStringSync();
  final settings = File('$root/lib/features/settings/settings_screen.dart').readAsStringSync();
  final player = File('$root/lib/features/player/now_playing_screen.dart').readAsStringSync();
  final miniPlayer = File('$root/lib/features/player/mini_player.dart').readAsStringSync();
  final equalizer = File('$root/lib/features/equalizer/equalizer_screen.dart').readAsStringSync();
  final lyrics = File('$root/lib/features/lyrics/lyrics_screen.dart').readAsStringSync();
  final tabs = File('$root/lib/core/library_tab_settings.dart').readAsStringSync();

  test('All nine locales contain the app-wide core translation keys', () {
    final screenMap = localization.split('static const _screenTranslations').last;
    for (final code in ['en', 'ar', 'fr', 'es', 'de', 'pt', 'tr', 'ja', 'ar_MA']) {
      final match = RegExp("'$code': \\{([^\\n]*)").firstMatch(screenMap);
      expect(match, isNotNull, reason: 'Missing screen translations for $code');
      final block = match!.group(1)!;
      for (final key in [
        'your_music', 'all_tracks', 'albums', 'artists', 'folders', 'playlists',
        'playback', 'general', 'privacy', 'lock_screen_controls',
        'external_device_playback', 'your_equalizer_active', 'no_lyrics_title',
        'empty_library_body', 'allowed', 'blocked_in_settings',
        'crossfade_explanation', 'added_to_playlist', 'track_options',
        'accent_teal', 'accent_blue', 'accent_green', 'accent_orange',
        'accent_red', 'accent_amber', 'accent_pink', 'preset_normal',
        'preset_classical', 'preset_dance', 'preset_flat', 'preset_folk',
        'preset_heavy_metal', 'preset_hip_hop', 'preset_jazz', 'preset_pop',
        'preset_rock', 'detail_title', 'duration', 'file_name', 'storage_volume',
        'media_store_id', 'equalizer_unsupported_detail', 'lyrics_load_error_detail',
      ]) {
        expect(block, contains("'$key':"), reason: '$code is missing $key');
      }
    }
  });

  test('Arabic and Moroccan Arabic use Flutter RTL locale support', () {
    expect(main, contains('GlobalWidgetsLocalizations.delegate'));
    expect(main, contains('locale: localeForLanguage(languageCode)'));
    expect(localization, contains("Locale('ar', 'MA')"));
    expect(localization, contains("'ar_MA': {"));
  });

  test('Language choice is persisted and all nine locales are exposed to MaterialApp', () {
    expect(localization, contains("'v27_language_code_v1'"));
    expect(localization, contains('prefs.setString(_languagePreferenceKey, code)'));
    expect(main, contains('supportedLocales: v27Languages.map'));
  });

  test('Opening animation uses the extended duration', () {
    expect(library, contains('Duration(milliseconds: 2600)'));
    expect(library, contains('_OpeningAnimationOverlay'));
  });

  test('Main user-facing surfaces are wired to localization', () {
    expect(library, contains("strings.text('your_music')"));
    expect(library, contains("V27Strings.of(context).text('track_options')"));
    expect(dashboard, contains("V27Strings.of(context).text('quick_picks')"));
    expect(settings, contains("V27Strings.of(context).text('play_speed')"));
    expect(settings, contains("V27Strings.of(context).text('queue_settings')"));
    expect(player, contains("strings.text('previous_track')"));
    expect(miniPlayer, contains("V27Strings.of(context).text('previous')"));
    expect(equalizer, contains("V27Strings.of(context).text('frequency_bands')"));
    expect(equalizer, contains('_localizedPresetName(context'));
    expect(lyrics, contains("V27Strings.of(context).text('embedded_lyrics_missing')"));
    expect(tabs, contains('localizedLabel(BuildContext context)'));
    expect(tabs, contains("LibraryTab.playlists => 'playlists'"));
  });
}

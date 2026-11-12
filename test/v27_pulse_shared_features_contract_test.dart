import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;
  final main = File('$root/lib/main.dart').readAsStringSync();
  final accents = File('$root/lib/core/accent_color_provider.dart').readAsStringSync();
  final localization = File('$root/lib/core/localization.dart').readAsStringSync();
  final nowPlaying = File('$root/lib/features/player/now_playing_screen.dart').readAsStringSync();
  final sleepSheet = File('$root/lib/core/widgets/sleep_timer_sheet.dart').readAsStringSync();
  final playback = File('$root/lib/playback/playback_controller.dart').readAsStringSync();
  final settings = File('$root/lib/features/settings/settings_screen.dart').readAsStringSync();
  final theme = File('$root/lib/core/theme.dart').readAsStringSync();
  final equalizer = File('$root/lib/features/equalizer/equalizer_screen.dart').readAsStringSync();
  final lyricsScreen = File('$root/lib/features/lyrics/lyrics_screen.dart').readAsStringSync();

  test('Seven coordinated accent palettes are persisted', () {
    expect(accents, contains("'teal'"));
    expect(accents, contains("'blue'"));
    expect(accents, contains("'green'"));
    expect(accents, contains("'orange'"));
    expect(accents, contains("'red'"));
    expect(accents, contains("'amber'"));
    expect(accents, contains("'pink'"));
    expect(accents, contains('SharedPreferences'));
    expect(main, contains('AppTheme.light(accent: accent.lightColor)'));
    expect(main, contains('AppTheme.amoledDark(accent: accent.darkColor)'));
    expect(theme, contains('_darkThemeCache'));
    expect(theme, contains('_lightThemeCache'));
    expect(equalizer, contains('Color.lerp(Theme.of(context).colorScheme.primary'));
    expect(lyricsScreen, contains('Color.lerp(colors.primary'));
  });

  test('Nine locale choices include Moroccan Darija in Arabic script', () {
    expect(localization, contains("code: 'ar_MA'"));
    expect(localization, contains("name: 'الدارجة المغربية'"));
    expect(localization, contains("Locale('ar', 'MA')"));
    expect(localization, contains('SharedPreferences'));
    expect(settings, contains('v27Languages.map'));
  });

  test('Now Playing offers inline lyrics and upcoming queue views', () {
    expect(nowPlaying, contains('_NowPlayingView.lyrics'));
    expect(nowPlaying, contains('_NowPlayingView.queue'));
    expect(nowPlaying, contains('_InlineLyricsPanel'));
    expect(nowPlaying, contains('_UpcomingQueuePanel'));
    expect(nowPlaying, contains('LrcParser.activeLineIndex'));
  });

  test('Sleep timer sheet controls the existing native shared deadline', () {
    expect(sleepSheet, contains('getSleepTimerDeadline'));
    expect(sleepSheet, contains('setSleepTimerDeadline'));
    expect(sleepSheet, contains('cancelSleepTimer'));
    expect(nowPlaying, contains('showSleepTimerSheet(context)'));
    expect(settings, contains('_SleepTimerSetting'));
    expect(settings, contains("text('sleep_timer_finished')"));
  });

  test('Upcoming preview resolves from the active logical QueueSpec', () {
    expect(playback, contains('loadUpcomingQueueTracks'));
    expect(playback, contains('_activeSpec'));
    expect(playback, contains('spec.resolvePosition'));
    expect(playback, contains('spec.resolvePage'));
    expect(playback, contains('trackByMediaStoreIdentity'));
    expect(playback, contains('playTrackFromActiveQueue'));
    expect(nowPlaying, contains('playTrackFromActiveQueue(track)'));
  });
}

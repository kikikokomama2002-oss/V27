import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_music_player/features/lyrics/lrc_parser.dart';

void main() {
  final root = Directory.current.path;

  final playbackService = File(
    '$root/android/app/src/main/kotlin/com/example/musicplayer/playback/PlaybackService.kt',
  ).readAsStringSync();
  final queueWindow = File(
    '$root/android/app/src/main/kotlin/com/example/musicplayer/playback/QueueWindowController.kt',
  ).readAsStringSync();
  final lyricsScreen = File(
    '$root/lib/features/lyrics/lyrics_screen.dart',
  ).readAsStringSync();
  final main = File('$root/lib/main.dart').readAsStringSync();
  final theme = File('$root/lib/core/theme.dart').readAsStringSync();

  test('notification advertises the standard Next commands Media3 requires', () {
    expect(playbackService, contains('commands.add(Player.COMMAND_SEEK_TO_NEXT)'));
    expect(playbackService, contains('commands.add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)'));
    expect(playbackService, contains('PlayerHolder.dispatchMediaSessionSkipNext()'));
    expect(playbackService, isNot(contains('setMediaButtonPreferences(listOf(nextButton))')));
    final refreshStart = playbackService.indexOf('private fun refreshLogicalQueueState()');
    final refreshEnd = playbackService.indexOf('private fun applyNotificationCommands(', refreshStart);
    expect(refreshStart, greaterThanOrEqualTo(0));
    expect(refreshEnd, greaterThan(refreshStart));
    final refreshMethod = playbackService.substring(refreshStart, refreshEnd);
    expect(refreshMethod, contains('sessionPlayer.refreshLogicalQueueState()'));
    expect(refreshMethod, contains('applyNotificationCommands()'));
    expect(refreshMethod, isNot(contains('triggerNotificationUpdate()')));
  });

  test('logical Next is resolved from the current stable MediaItem identity', () {
    final start = queueWindow.indexOf('fun hasLogicalNext(): Boolean?');
    final end = queueWindow.indexOf('\n    /** Clears only', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final method = queueWindow.substring(start, end);
    expect(method, contains('p.currentMediaItem?.mediaId'));
    expect(method, contains('loadedIds.indexOf(currentMediaId)'));
    expect(method, contains('logicalIndexOf(relativeIndex) + 1 < totalCount'));
    expect(method, isNot(contains('p.currentMediaItemIndex')));
  });

  test('lyrics scroll geometry uses the actual rendered text width and row extent', () {
    expect(lyricsScreen, contains('constraints.maxWidth'));
    expect(lyricsScreen, contains('_listHorizontalPadding * 2'));
    expect(lyricsScreen, contains('_itemHorizontalPadding * 2'));
    expect(lyricsScreen, contains('textScaler: MediaQuery.textScalerOf(context)'));
    expect(lyricsScreen, contains('locale: Localizations.maybeLocaleOf(context)'));
    expect(lyricsScreen, contains('(verticalPadding * 2)'));
    expect(lyricsScreen, contains('(_itemVerticalMargin * 2)'));
    expect(lyricsScreen, contains('textScaler.scale(16)'));
    expect(lyricsScreen, contains('textScaler.scale(22)'));
  });

  test('lyrics do not mark a line followed until a real scroll can be issued', () {
    final start = lyricsScreen.indexOf('void _maybeAutoScroll(');
    final end = lyricsScreen.indexOf('\n  }', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final method = lyricsScreen.substring(start, end);
    final clientsCheck = method.indexOf('if (!_scrollController.hasClients');
    final scrollCall = method.indexOf('_scrollController.animateTo(');
    final markHandled = method.indexOf('_lastActiveIndex = activeIndex;');
    expect(clientsCheck, greaterThanOrEqualTo(0));
    expect(scrollCall, greaterThan(clientsCheck));
    expect(markHandled, greaterThan(scrollCall));
    expect(method, contains('hasContentDimensions'));
    expect(method, contains('_cachedGeometryWidth != maxWidth'));
  });

  test('LRC active line advances as playback time moves forward', () {
    final lines = LrcParser.parse(
      '[00:00.00]First line\n'
      '[00:05.00]Second line\n'
      '[00:10.00]Third line',
    );

    expect(LrcParser.activeLineIndex(lines, Duration.zero), 0);
    expect(LrcParser.activeLineIndex(lines, const Duration(seconds: 4)), 0);
    expect(LrcParser.activeLineIndex(lines, const Duration(seconds: 5)), 1);
    expect(LrcParser.activeLineIndex(lines, const Duration(seconds: 10)), 2);
  });

  test('theme switches reuse prebuilt themes without animated interpolation', () {
    expect(theme, contains('_lightThemeCache'));
    expect(theme, contains('_darkThemeCache'));
    expect(theme, contains('_lightThemeCache.putIfAbsent(accent'));
    expect(theme, contains('_darkThemeCache.putIfAbsent(accent'));
    expect(main, contains('theme: AppTheme.light(accent: accent.lightColor)'));
    expect(main, contains('darkTheme: AppTheme.amoledDark(accent: accent.darkColor)'));
    expect(main, contains('themeAnimationDuration: Duration.zero'));
    expect(main.replaceAll(RegExp(r'//.*'), ''), isNot(contains('AnimatedTheme')));
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current;
  String read(String path) => File('${root.path}/$path').readAsStringSync();

  test('all app page routes use lightweight slide/fade transitions', () {
    final theme = read('lib/core/theme.dart');
    expect(theme, contains('class V27SlidePageTransitionsBuilder'));
    expect(theme, contains('SlideTransition('));
    expect(theme, contains('FadeTransition(opacity: opacity, child: child)'));
    expect(theme, contains('MediaQuery.maybeOf(context)?.disableAnimations'));
    expect(
      theme,
      contains('pageTransitionsTheme: const PageTransitionsTheme('),
    );
  });

  test('album artwork decoding is bounded to requested thumbnail size', () {
    final artwork = read('lib/core/widgets/track_artwork.dart');
    expect(artwork, contains('cacheWidth: widget.artSize'));
    expect(artwork, contains('cacheHeight: widget.artSize'));
    expect(artwork, contains('gaplessPlayback: true'));
    expect(artwork, contains('return RepaintBoundary('));
  });

  test('library tab animation does not rebuild on every controller tick', () {
    final library = read('lib/features/library/library_screen.dart');
    expect(library, contains('if (nextIndex == _selectedTabIndex) return;'));
    expect(
      library,
      contains('animationDuration: const Duration(milliseconds: 280)'),
    );
    expect(library, contains('PageScrollPhysics('));
    expect(library, contains('Curves.easeOutCubic'));
  });
}

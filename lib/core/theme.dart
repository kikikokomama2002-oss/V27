import 'package:flutter/material.dart';

/// True AMOLED dark theme (pure #000000 background, not dark gray) plus
/// a light theme fallback. Accent color is a parameter so the settings
/// screen can swap it at runtime.
class AppTheme {
  static ThemeData amoledDark({Color accent = const Color(0xFF1DB954)}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(
      surface: Colors.black,
      background: Colors.black,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.black,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.black,
        elevation: 0,
        centerTitle: false,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.black,
      ),
      cardColor: const Color(0xFF0A0A0A),
      dividerColor: const Color(0xFF1A1A1A),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.black,
        indicatorColor: accent.withOpacity(0.25),
      ),
    );
  }

  static ThemeData light({Color accent = const Color(0xFF1DB954)}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
    );
  }
}

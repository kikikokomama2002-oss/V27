import 'package:flutter/material.dart';

/// Shared visual identity for V27 PULSE.
abstract final class V27Palette {
  static const violet = Color(0xFF8B5CF6);
  static const cyan = Color(0xFF43D9E8);

  static const darkBackground = Color(0xFF080B14);
  static const darkSurface = Color(0xFF111827);
  static const darkSurfaceElevated = Color(0xFF192235);
  static const darkBorder = Color(0xFF273247);

  static const lightBackground = Color(0xFFF5F6FA);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightBorder = Color(0xFFE5E7EF);
}

class AppTheme {
  static ThemeData amoledDark({
    Color accent = V27Palette.violet,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(
      primary: accent,
      secondary: V27Palette.cyan,
      surface: V27Palette.darkSurface,
      onSurface: const Color(0xFFF4F5FA),
      outline: V27Palette.darkBorder,
      error: const Color(0xFFFF6B7A),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: V27Palette.darkBackground,
      canvasColor: V27Palette.darkBackground,
      cardColor: V27Palette.darkSurface,
      dividerColor: V27Palette.darkBorder,
      appBarTheme: const AppBarTheme(
        backgroundColor: V27Palette.darkBackground,
        foregroundColor: Color(0xFFF4F5FA),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: V27Palette.darkSurface,
        hintStyle: const TextStyle(color: Color(0xFF8993A7)),
        prefixIconColor: const Color(0xFF9AA5BA),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: V27Palette.darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: V27Palette.darkBackground,
        indicatorColor: accent.withValues(alpha: 0.22),
        elevation: 0,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: V27Palette.darkBackground,
      ),
      dividerTheme: const DividerThemeData(
        color: V27Palette.darkBorder,
        thickness: 0.7,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: V27Palette.darkSurfaceElevated,
        contentTextStyle: const TextStyle(color: Color(0xFFF4F5FA)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: const BorderSide(color: V27Palette.darkBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }

  static ThemeData light({
    Color accent = V27Palette.violet,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
    ).copyWith(
      primary: accent,
      secondary: const Color(0xFF087F91),
      surface: V27Palette.lightSurface,
      onSurface: const Color(0xFF171A25),
      outline: V27Palette.lightBorder,
      error: const Color(0xFFBA2638),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: V27Palette.lightBackground,
      canvasColor: V27Palette.lightBackground,
      cardColor: V27Palette.lightSurface,
      dividerColor: V27Palette.lightBorder,
      appBarTheme: const AppBarTheme(
        backgroundColor: V27Palette.lightBackground,
        foregroundColor: Color(0xFF171A25),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: V27Palette.lightSurface,
        hintStyle: const TextStyle(color: Color(0xFF858B9A)),
        prefixIconColor: const Color(0xFF707789),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: V27Palette.lightBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: V27Palette.lightSurface,
        indicatorColor: accent.withValues(alpha: 0.13),
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(
        color: V27Palette.lightBorder,
        thickness: 0.7,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF202435),
        contentTextStyle: const TextStyle(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: const BorderSide(color: V27Palette.lightBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}

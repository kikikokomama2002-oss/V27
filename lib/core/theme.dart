import 'package:flutter/material.dart';

/// Canonical design tokens for V27 PULSE.
///
/// Brand identity: Midnight + Electric Teal. Light mode intentionally uses
/// Deep Teal for primary actions because Electric Teal does not provide
/// sufficient contrast against light surfaces.
abstract final class V27Palette {
  // Brand.
  static const midnight = Color(0xFF080B10);
  static const graphite = Color(0xFF151C25);
  static const electricTeal = Color(0xFF38D6D0);
  static const deepTeal = Color(0xFF0B7571);
  static const silver = Color(0xFFA7B5C5);

  // Dark surfaces and content.
  static const darkBackground = midnight;
  static const darkSurface = graphite;
  static const darkSurfaceElevated = Color(0xFF1D2733);
  static const darkBorder = Color(0xFF26313E);
  static const darkText = Color(0xFFF2F6F8);
  static const darkSecondaryText = silver;
  static const darkMuted = Color(0xFF8496A9);

  // Light surfaces and content.
  static const lightBackground = Color(0xFFF3F6F8);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceElevated = Color(0xFFE9EEF2);
  static const lightBorder = Color(0xFFD9E2E9);
  static const lightText = Color(0xFF0D141B);
  static const lightSecondaryText = Color(0xFF4E6172);

  // Semantic colors are not brand accents.
  static const darkError = Color(0xFFFF6B7A);
  static const lightError = Color(0xFFBA2638);

}

abstract final class V27Spacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
}

abstract final class V27Radius {
  static const sm = 10.0;
  static const md = 14.0;
  static const lg = 18.0;
  static const xl = 22.0;
}

abstract final class V27Motion {
  static const fast = Duration(milliseconds: 150);
  static const standard = Duration(milliseconds: 250);
  static const deliberate = Duration(milliseconds: 350);
  static const curve = Curves.easeOutCubic;
}

class AppTheme {
  static final Map<Color, ThemeData> _darkThemeCache = <Color, ThemeData>{};
  static final Map<Color, ThemeData> _lightThemeCache = <Color, ThemeData>{};

  static ThemeData amoledDark({Color accent = V27Palette.electricTeal}) =>
      _darkThemeCache.putIfAbsent(accent, () => _buildAmoledDark(accent));

  static ThemeData _buildAmoledDark(Color accent) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(
      primary: accent,
      onPrimary: const Color(0xFF062524),
      secondary: V27Palette.silver,
      onSecondary: V27Palette.midnight,
      surface: V27Palette.darkSurface,
      onSurface: V27Palette.darkText,
      onSurfaceVariant: V27Palette.darkSecondaryText,
      outline: V27Palette.darkBorder,
      error: V27Palette.darkError,
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
        foregroundColor: V27Palette.darkText,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: V27Palette.darkSurface,
        hintStyle: const TextStyle(color: V27Palette.darkMuted),
        prefixIconColor: V27Palette.darkSecondaryText,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: V27Spacing.lg + 2,
          vertical: V27Spacing.lg,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V27Radius.lg),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V27Radius.lg),
          borderSide: const BorderSide(color: V27Palette.darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V27Radius.lg),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: V27Palette.darkBackground,
        indicatorColor: accent.withValues(alpha: 0.20),
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
        contentTextStyle: const TextStyle(color: V27Palette.darkText),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V27Radius.md),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(V27Radius.md),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: const BorderSide(color: V27Palette.darkBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(V27Radius.md),
          ),
        ),
      ),
    );
  }

  static ThemeData light({Color accent = V27Palette.deepTeal}) =>
      _lightThemeCache.putIfAbsent(accent, () => _buildLight(accent));

  static ThemeData _buildLight(Color accent) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
    ).copyWith(
      primary: accent,
      onPrimary: Colors.white,
      secondary: V27Palette.lightSecondaryText,
      onSecondary: Colors.white,
      surface: V27Palette.lightSurface,
      onSurface: V27Palette.lightText,
      onSurfaceVariant: V27Palette.lightSecondaryText,
      outline: V27Palette.lightBorder,
      error: V27Palette.lightError,
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
        foregroundColor: V27Palette.lightText,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: V27Palette.lightSurface,
        hintStyle: const TextStyle(color: V27Palette.lightSecondaryText),
        prefixIconColor: V27Palette.lightSecondaryText,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: V27Spacing.lg + 2,
          vertical: V27Spacing.lg,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V27Radius.lg),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V27Radius.lg),
          borderSide: const BorderSide(color: V27Palette.lightBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V27Radius.lg),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: V27Palette.lightSurface,
        indicatorColor: accent.withValues(alpha: 0.12),
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(
        color: V27Palette.lightBorder,
        thickness: 0.7,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: V27Palette.darkSurfaceElevated,
        contentTextStyle: const TextStyle(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V27Radius.md),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(V27Radius.md),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: const BorderSide(color: V27Palette.lightBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(V27Radius.md),
          ),
        ),
      ),
    );
  }


  /// Reused immutable theme objects; rebuilding MaterialApp must not
  /// regenerate both complete ThemeData trees on every mode switch.
  static final ThemeData lightTheme = light();
  static final ThemeData darkTheme = amoledDark();
}

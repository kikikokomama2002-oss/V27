import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _darkModePreferenceKey = 'v27_dark_mode_enabled_v1';

final themeModeProvider = StateNotifierProvider<ThemeModeController, ThemeMode>(
  (ref) => ThemeModeController(),
);

class ThemeModeController extends StateNotifier<ThemeMode> {
  bool _changedByUser = false;

  ThemeModeController() : super(ThemeMode.dark) {
    _loadSavedMode();
  }

  Future<void> _loadSavedMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_darkModePreferenceKey);
      if (enabled != null && !_changedByUser) {
        state = enabled ? ThemeMode.dark : ThemeMode.light;
      }
    } catch (_) {
      // Keep the default dark theme if preferences cannot be read.
    }
  }

  Future<void> setDarkMode(bool enabled) async {
    _changedByUser = true;
    state = enabled ? ThemeMode.dark : ThemeMode.light;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_darkModePreferenceKey, enabled);
    } catch (_) {
      // Keep the current session usable if saving preferences fails.
    }
  }
}

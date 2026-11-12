import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _accentPreferenceKey = 'v27_accent_color_v1';

class AccentOption {
  const AccentOption(this.id, this.name, this.darkColor, this.lightColor);
  final String id;
  final String name;
  final Color darkColor;
  final Color lightColor;
}

const accentOptions = <AccentOption>[
  AccentOption('teal', 'Electric Teal', Color(0xFF38D6D0), Color(0xFF0B7571)),
  AccentOption('blue', 'Ocean Blue', Color(0xFF3997F5), Color(0xFF1767B7)),
  AccentOption('green', 'Emerald Green', Color(0xFF27C58B), Color(0xFF087B55)),
  AccentOption('orange', 'Sunset Orange', Color(0xFFFF914D), Color(0xFFB95016)),
  AccentOption('red', 'Ruby Red', Color(0xFFF05B70), Color(0xFFB52D46)),
  AccentOption('amber', 'Golden Amber', Color(0xFFE8B94F), Color(0xFF9A6A08)),
  AccentOption('pink', 'Rose Pink', Color(0xFFE879B5), Color(0xFFAD397C)),
];

final accentColorProvider = StateNotifierProvider<AccentColorController, String>(
  (ref) => AccentColorController(),
);

AccentOption accentOptionFor(String id) => accentOptions.firstWhere(
      (option) => option.id == id,
      orElse: () => accentOptions.first,
    );

class AccentColorController extends StateNotifier<String> {
  AccentColorController() : super('teal') { _load(); }
  bool _changed = false;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_accentPreferenceKey);
      if (!_changed && accentOptions.any((option) => option.id == saved)) {
        state = saved!;
      }
    } catch (_) {}
  }

  Future<void> select(String id) async {
    if (!accentOptions.any((option) => option.id == id)) return;
    _changed = true;
    state = id;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_accentPreferenceKey, id);
    } catch (_) {}
  }
}

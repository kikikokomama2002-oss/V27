import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LibraryTab {
  tracks('Tracks', Icons.music_note_outlined),
  albums('Albums', Icons.album_outlined),
  artists('Artists', Icons.person_outline),
  folders('Folders', Icons.folder_outlined);

  const LibraryTab(this.label, this.icon);

  final String label;
  final IconData icon;

  static LibraryTab? parse(String name) {
    for (final tab in values) {
      if (tab.name == name) return tab;
    }
    return null;
  }
}

class LibraryTabConfig {
  LibraryTabConfig({required List<LibraryTab> order, required Set<LibraryTab> visible})
    : order = List<LibraryTab>.unmodifiable(order),
      visible = Set<LibraryTab>.unmodifiable(visible);

  factory LibraryTabConfig.defaults() => LibraryTabConfig(
    order: LibraryTab.values,
    visible: LibraryTab.values.toSet(),
  );

  final List<LibraryTab> order;
  final Set<LibraryTab> visible;

  List<LibraryTab> get visibleTabs =>
      List<LibraryTab>.unmodifiable(order.where(visible.contains));

  LibraryTabConfig copyWith({List<LibraryTab>? order, Set<LibraryTab>? visible}) =>
      LibraryTabConfig(
        order: order ?? this.order,
        visible: visible ?? this.visible,
      );
}

const _orderKey = 'v27_library_tab_order_v1';
const _visibleKey = 'v27_library_visible_tabs_v1';

final libraryTabSettingsProvider = StateNotifierProvider<
  LibraryTabSettingsController,
  LibraryTabConfig
>((ref) => LibraryTabSettingsController());

class LibraryTabSettingsController extends StateNotifier<LibraryTabConfig> {
  bool _changedByUser = false;

  LibraryTabSettingsController() : super(LibraryTabConfig.defaults()) {
    unawaited(_load());
  }

  Future<void> _saveTail = Future<void>.value();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final defaultOrder = LibraryTab.values.toList(growable: false);
      final storedOrder = prefs.getStringList(_orderKey) ?? const <String>[];
      final order = <LibraryTab>[];
      for (final raw in storedOrder) {
        final tab = LibraryTab.parse(raw);
        if (tab != null && !order.contains(tab)) order.add(tab);
      }
      for (final tab in defaultOrder) {
        if (!order.contains(tab)) order.add(tab);
      }

      final storedVisible = prefs.getStringList(_visibleKey);
      final visible = storedVisible == null
          ? LibraryTab.values.toSet()
          : storedVisible.map(LibraryTab.parse).whereType<LibraryTab>().toSet();
      // A valid app state must always leave at least one library tab visible.
      if (visible.isEmpty) visible.add(LibraryTab.tracks);

      if (!_changedByUser) {
        state = LibraryTabConfig(order: order, visible: visible);
      }
    } catch (_) {
      // Keep the complete default tab set if storage is unavailable.
    }
  }

  void setVisible(LibraryTab tab, bool isVisible) {
    final nextVisible = Set<LibraryTab>.of(state.visible);
    if (isVisible) {
      nextVisible.add(tab);
    } else {
      if (nextVisible.length <= 1) return;
      nextVisible.remove(tab);
    }
    _changedByUser = true;
    state = state.copyWith(visible: nextVisible);
    _persist();
  }

  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= state.order.length) return;
    if (newIndex < 0 || newIndex > state.order.length) return;
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex == newIndex) return;
    _changedByUser = true;
    final nextOrder = List<LibraryTab>.of(state.order);
    final tab = nextOrder.removeAt(oldIndex);
    nextOrder.insert(newIndex, tab);
    state = state.copyWith(order: nextOrder);
    _persist();
  }

  void _persist() {
    final snapshot = state;
    // Serialize persistence so rapid drag/toggle gestures cannot leave an
    // older asynchronous write as the final saved configuration.
    _saveTail = _saveTail.catchError((_) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _orderKey,
        snapshot.order.map((tab) => tab.name).toList(growable: false),
      );
      await prefs.setStringList(
        _visibleKey,
        snapshot.order
            .where(snapshot.visible.contains)
            .map((tab) => tab.name)
            .toList(growable: false),
      );
    });
  }
}

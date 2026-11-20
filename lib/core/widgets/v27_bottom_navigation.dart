import 'package:flutter/material.dart';

import '../localization.dart';

/// Shared four-destination navigation used by the main library, Now Playing,
/// and Settings surfaces.
class V27BottomNavigation extends StatelessWidget {
  const V27BottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final strings = V27Strings.of(context);
    return NavigationBar(
      selectedIndex: selectedIndex < 0 ? 0 : (selectedIndex > 3 ? 3 : selectedIndex),
      onDestinationSelected: onDestinationSelected,
      height: 68,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home_rounded),
          label: strings.text('home'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.library_music_outlined),
          selectedIcon: const Icon(Icons.library_music_rounded),
          label: strings.text('all_tracks'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.graphic_eq_outlined),
          selectedIcon: const Icon(Icons.graphic_eq_rounded),
          label: strings.text('now_playing'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings_rounded),
          label: strings.text('settings'),
        ),
      ],
    );
  }
}

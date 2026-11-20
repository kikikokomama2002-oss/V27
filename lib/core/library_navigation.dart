import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library_tab_settings.dart';

/// Shared selected library page so the bottom navigation can return from
/// Now Playing or Settings to the correct Home / Tracks destination.
final libraryTabSelectionProvider = StateProvider<LibraryTab>(
  (ref) => LibraryTab.home,
);

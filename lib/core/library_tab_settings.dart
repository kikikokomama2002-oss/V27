import 'package:flutter/material.dart';

enum LibraryTab {
  home('Home', Icons.home_outlined),
  tracks('Tracks', Icons.music_note_outlined),
  albums('Albums', Icons.album_outlined),
  artists('Artists', Icons.person_outline),
  folders('Folders', Icons.folder_outlined),
  playlists('Playlists', Icons.queue_music_outlined);

  const LibraryTab(this.label, this.icon);

  final String label;
  final IconData icon;
}

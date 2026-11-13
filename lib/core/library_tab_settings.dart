import 'package:flutter/material.dart';
import 'localization.dart';

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

  String localizedLabel(BuildContext context) =>
      V27Strings.of(context).text(switch (this) {
        LibraryTab.home => 'home',
        LibraryTab.tracks => 'all_tracks',
        LibraryTab.albums => 'albums',
        LibraryTab.artists => 'artists',
        LibraryTab.folders => 'folders',
        LibraryTab.playlists => 'playlists',
      });
}

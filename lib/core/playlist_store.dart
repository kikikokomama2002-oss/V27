import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/db/track.dart';

const String _playlistsKey = 'v27_playlists_v1';
const String _avoidDuplicateSongsKey = 'v27_avoid_duplicate_playlist_songs_v1';

/// Stable MediaStore identity. Isar's local auto-increment ID is deliberately
/// not stored because a library rescan can recreate an Isar row.
class PlaylistTrackIdentity {
  const PlaylistTrackIdentity({required this.volume, required this.mediaStoreId});

  final String volume;
  final int mediaStoreId;

  factory PlaylistTrackIdentity.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('Invalid playlist track');
    final volume = raw['volume'];
    final id = raw['id'];
    if (volume is! String || volume.trim().isEmpty || id is! num ||
        id <= 0 || id.toInt() != id) {
      throw const FormatException('Invalid playlist track identity');
    }
    return PlaylistTrackIdentity(volume: volume.trim(), mediaStoreId: id.toInt());
  }

  factory PlaylistTrackIdentity.fromTrack(Track track) => PlaylistTrackIdentity(
    volume: track.mediaStoreVolume,
    mediaStoreId: track.mediaStoreId,
  );

  Map<String, Object> toJson() => {'volume': volume, 'id': mediaStoreId};

  String get key => '$volume:$mediaStoreId';
}

class UserPlaylist {
  UserPlaylist({
    required this.id,
    required this.name,
    required List<PlaylistTrackIdentity> songs,
  }) : songs = List<PlaylistTrackIdentity>.unmodifiable(songs);

  final String id;
  final String name;
  final List<PlaylistTrackIdentity> songs;

  factory UserPlaylist.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('Invalid playlist');
    final id = raw['id'];
    final name = raw['name'];
    final songsRaw = raw['songs'];
    if (id is! String || id.isEmpty || name is! String || name.trim().isEmpty || songsRaw is! List) {
      throw const FormatException('Invalid playlist fields');
    }
    return UserPlaylist(
      id: id,
      name: name.trim(),
      songs: songsRaw.map(PlaylistTrackIdentity.fromJson).toList(growable: false),
    );
  }

  UserPlaylist copyWith({String? name, List<PlaylistTrackIdentity>? songs}) => UserPlaylist(
    id: id,
    name: name ?? this.name,
    songs: songs ?? this.songs,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'songs': songs.map((song) => song.toJson()).toList(growable: false),
  };
}

class PlaylistStoreState {
  PlaylistStoreState({
    required this.isLoading,
    required List<UserPlaylist> playlists,
    required this.avoidDuplicateSongs,
  }) : playlists = List<UserPlaylist>.unmodifiable(playlists);

  final bool isLoading;
  final List<UserPlaylist> playlists;
  final bool avoidDuplicateSongs;

  PlaylistStoreState copyWith({
    bool? isLoading,
    List<UserPlaylist>? playlists,
    bool? avoidDuplicateSongs,
  }) => PlaylistStoreState(
    isLoading: isLoading ?? this.isLoading,
    playlists: playlists ?? this.playlists,
    avoidDuplicateSongs: avoidDuplicateSongs ?? this.avoidDuplicateSongs,
  );
}

final playlistStoreProvider = StateNotifierProvider<PlaylistStoreController, PlaylistStoreState>(
  (ref) => PlaylistStoreController(),
);

class PlaylistStoreController extends StateNotifier<PlaylistStoreState> {
  PlaylistStoreController()
    : super(PlaylistStoreState(isLoading: true, playlists: const [], avoidDuplicateSongs: true)) {
    ready = _load();
  }

  late final Future<void> ready;
  Future<void> _saveTail = Future<void>.value();

  static Future<List<UserPlaylist>> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_playlistsKey);
    if (encoded == null || encoded.isEmpty) return const <UserPlaylist>[];
    try {
      final raw = jsonDecode(encoded);
      if (raw is! List) return const <UserPlaylist>[];
      final playlists = <UserPlaylist>[];
      final seenIds = <String>{};
      for (final item in raw) {
        try {
          final playlist = UserPlaylist.fromJson(item);
          if (seenIds.add(playlist.id)) playlists.add(playlist);
        } on FormatException {
          // Ignore one damaged entry rather than hiding every valid playlist.
        }
      }
      return List<UserPlaylist>.unmodifiable(playlists);
    } catch (_) {
      return const <UserPlaylist>[];
    }
  }

  static Future<UserPlaylist?> readById(String playlistId) async {
    final playlists = await readAll();
    for (final playlist in playlists) {
      if (playlist.id == playlistId) return playlist;
    }
    return null;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final playlists = await readAll();
      state = PlaylistStoreState(
        isLoading: false,
        playlists: playlists,
        avoidDuplicateSongs: prefs.getBool(_avoidDuplicateSongsKey) ?? true,
      );
    } catch (_) {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<UserPlaylist?> createPlaylist(String rawName) async {
    await ready;
    final name = rawName.trim();
    if (name.isEmpty || name.length > 60) return null;
    if (state.playlists.any((playlist) => playlist.name.toLowerCase() == name.toLowerCase())) {
      return null;
    }
    final baseId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    var id = 'playlist_$baseId';
    var suffix = 1;
    while (state.playlists.any((playlist) => playlist.id == id)) {
      id = 'playlist_${baseId}_${suffix++}';
    }
    final playlist = UserPlaylist(id: id, name: name, songs: const []);
    state = state.copyWith(playlists: [...state.playlists, playlist]);
    await _persist();
    return playlist;
  }

  Future<bool> renamePlaylist(String playlistId, String rawName) async {
    await ready;
    final name = rawName.trim();
    if (name.isEmpty || name.length > 60) return false;
    if (state.playlists.any((playlist) => playlist.id != playlistId && playlist.name.toLowerCase() == name.toLowerCase())) {
      return false;
    }
    var found = false;
    final next = state.playlists.map((playlist) {
      if (playlist.id != playlistId) return playlist;
      found = true;
      return playlist.copyWith(name: name);
    }).toList(growable: false);
    if (!found) return false;
    state = state.copyWith(playlists: next);
    await _persist();
    return true;
  }

  Future<void> deletePlaylist(String playlistId) async {
    await ready;
    state = state.copyWith(
      playlists: state.playlists.where((playlist) => playlist.id != playlistId).toList(growable: false),
    );
    await _persist();
  }

  /// Returns false only when the setting prevents a duplicate membership or
  /// the playlist no longer exists.
  Future<bool> addTrack(String playlistId, Track track) async {
    await ready;
    final identity = PlaylistTrackIdentity.fromTrack(track);
    var added = false;
    final next = state.playlists.map((playlist) {
      if (playlist.id != playlistId) return playlist;
      if (state.avoidDuplicateSongs && playlist.songs.any((song) => song.key == identity.key)) {
        return playlist;
      }
      added = true;
      return playlist.copyWith(songs: [...playlist.songs, identity]);
    }).toList(growable: false);
    if (added) {
      state = state.copyWith(playlists: next);
      await _persist();
    }
    return added;
  }

  Future<void> removeTrackAt(String playlistId, int index) async {
    await ready;
    var changed = false;
    final next = state.playlists.map((playlist) {
      if (playlist.id != playlistId || index < 0 || index >= playlist.songs.length) return playlist;
      final songs = List<PlaylistTrackIdentity>.of(playlist.songs)..removeAt(index);
      changed = true;
      return playlist.copyWith(songs: songs);
    }).toList(growable: false);
    if (changed) {
      state = state.copyWith(playlists: next);
      await _persist();
    }
  }

  Future<void> removeFirstTrack(String playlistId, String volume, int mediaStoreId) async {
    await ready;
    var changed = false;
    final targetKey = '$volume:$mediaStoreId';
    final next = state.playlists.map((playlist) {
      if (playlist.id != playlistId) return playlist;
      final index = playlist.songs.indexWhere((song) => song.key == targetKey);
      if (index < 0) return playlist;
      final songs = List<PlaylistTrackIdentity>.of(playlist.songs)..removeAt(index);
      changed = true;
      return playlist.copyWith(songs: songs);
    }).toList(growable: false);
    if (changed) {
      state = state.copyWith(playlists: next);
      await _persist();
    }
  }

  Future<void> setAvoidDuplicateSongs(bool enabled) async {
    await ready;
    state = state.copyWith(avoidDuplicateSongs: enabled);
    await _persist();
  }

  Future<void> _persist() {
    final snapshot = state;
    _saveTail = _saveTail.catchError((_) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _playlistsKey,
        jsonEncode(snapshot.playlists.map((playlist) => playlist.toJson()).toList(growable: false)),
      );
      await prefs.setBool(_avoidDuplicateSongsKey, snapshot.avoidDuplicateSongs);
    }).catchError((_) {});
    return _saveTail;
  }
}

import 'package:isar_community/isar.dart';

part 'track.g.dart'; // generated via `flutter pub run build_runner build`

/// Local reactive DB record for a scanned audio track.
@collection
class Track {
  Id id = Isar.autoIncrement;

  /// MediaStore storage-volume name (for example `external_primary` or
  /// a removable volume such as `1234-ABCD`). The pair
  /// (`mediaStoreVolume`, `mediaStoreId`) is the stable MediaStore identity.
  @Index(unique: true, composite: [CompositeIndex('mediaStoreId')])
  String mediaStoreVolume = 'external_primary';

  /// MediaStore.Audio.Media._ID. IDs are only unique within a MediaStore
  /// volume, so this index is intentionally non-unique; the composite
  /// unique index above provides the actual identity.
  @Index()
  late int mediaStoreId; // MediaStore.Audio.Media._ID, used for delta scans

  @Index(type: IndexType.value, caseSensitive: true)
  late String title;

  @Index(type: IndexType.value, caseSensitive: false)
  late String artist;

  @Index(type: IndexType.value, caseSensitive: false)
  late String album;

  /// Indexed full-text search corpus built from title, artist and album words.
  /// This deliberately changes search matching from arbitrary substring
  /// matching to Unicode-aware word-prefix matching so queries can use the
  /// multi-entry value index instead of scanning every Track.
  @Index(type: IndexType.value, caseSensitive: false)
  List<String> get searchWords => <String>[
    ...Isar.splitWords(title),
    ...Isar.splitWords(artist),
    ...Isar.splitWords(album),
  ];

  late int durationMs;

  /// `content://media/external/audio/media/{id}` URI — always use this
  /// for playback (ExoPlayer/MediaItem.setUri).
  late String contentUri;

  /// MediaStore's `RELATIVE_PATH` (e.g. "Music/MyAlbum/"). Null on
  /// API < 29, where the column doesn't exist. This — not a raw
  /// filesystem path — is the scoped-storage-safe source for grouping
  /// tracks by folder; it's for display/grouping only, never for
  /// opening a file directly.
  String? relativePath;

  /// MediaStore's `DISPLAY_NAME` (the file's own name, e.g.
  /// "01 Track.mp3"), available on every API level. Display/grouping
  /// only, never used to open a file directly.
  late String displayName;

  late int dateModified;

  /// MediaStore API 30+ row-generation version. Unlike DATE_MODIFIED, this
  /// changes whenever MediaProvider reports a row mutation and therefore is
  /// the preferred artwork/cache invalidation token on Android 11+. Null on
  /// legacy Android where the provider does not expose it.
  int? mediaStoreGenerationModified;

  /// Application-level derived-cache epoch. Legacy Android cannot provide an
  /// immutable MediaStore row identity, so uncertain scan/recreation cases
  /// advance this value to prevent stale artwork/lyrics caches from crossing
  /// an ID-reuse boundary.
  late int derivedCacheEpoch;

  /// Stored, indexed grouping key for the Folders tab — computed once
  /// at write time by [computeFolder] and persisted as a real column
  /// (see [LibraryRepository]) rather than derived on every read.
  ///
  /// A getter can't carry an `@Index`, and Isar's `sortBy`/`distinctBy`/
  /// `filter` queries used for large-library grouping (see
  /// `LibraryRepository.distinctGroupNamesPage` /
  /// `LibraryRepository.tracksForGroupPage`) need an indexed column to
  /// stay index-backed instead of falling back to an in-memory scan.
  @Index(type: IndexType.value, caseSensitive: true)
  late String folder;

  /// Cached lyrics text for this track, populated lazily on first visit
  /// to the lyrics screen so the scan step stays fast. Resolved from
  /// this track's own embedded tags (ID3 USLT/COMM, a Vorbis "LYRICS"/
  /// "UNSYNCEDLYRICS" comment, or the MP4 "©lyr" atom) first, falling
  /// back to a sidecar `.lrc` file in the same folder — see
  /// `LibraryRepository.ensureLyrics` / native `SidecarLyricsResolver`.
  /// The field name predates the sidecar fallback and is kept as-is to
  /// avoid an Isar schema migration; it may now hold sidecar-sourced
  /// text too. May itself be `.lrc`-formatted; `LrcParser` decides
  /// synced vs. plain-text display.
  String? embeddedLyricsText;

  /// Whether lyrics extraction has already run for this track — set
  /// even when nothing was found, so a track confirmed to have no
  /// lyrics tag doesn't re-run the (non-trivial) metadata extraction on
  /// every visit to the lyrics screen.
  bool lyricsChecked = false;

  /// Timestamp of the last negative/positive lyrics lookup, in Dart
  /// milliseconds since epoch. A negative result is only trusted for a
  /// short period so a sidecar `.lrc` added later can eventually be
  /// discovered without forcing an expensive embedded-metadata lookup on
  /// every lyrics-screen open. Positive and negative results are both
  /// short-lived so sidecar lyrics can change without the audio file's
  /// MediaStore timestamp changing.
  int lyricsCheckedAtMs = 0;

  /// Best-effort grouping value for [folder], derived from
  /// [relativePath]. Falls back to [album] on API < 29 (or for any
  /// track MediaStore didn't report a relative path for), since
  /// there's no raw path to fall back to. Called once by
  /// `LibraryRepository` when building a `Track` from a scan result,
  /// so the value is persisted rather than recomputed on every read.
  static String computeFolder({required String? relativePath, required String album, required String volume}) {
    final rel = relativePath;
    final path = (rel == null || rel.isEmpty)
        ? album
        : (rel.endsWith('/') ? rel.substring(0, rel.length - 1) : rel);
    // Folder paths are only unique within a MediaStore volume. Prefixing the
    // persisted grouping key prevents identical paths on primary storage and
    // an SD card from collapsing into one logical folder.
    return '$volume::$path';
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../../data/db/track.dart';
import '../../playback/player_channel.dart';
import 'lrc_parser.dart';

/// Full-screen lyrics view for [track]. Resolves and caches the track's
/// embedded lyrics tag (via `LibraryRepository.ensureLyrics`), then
/// either shows a synced, auto-scrolling/highlighted view (when the tag
/// content parses as timestamped `.lrc` lines) or a plain scrollable
/// text view (when it's unsynced prose — common for embedded lyrics,
/// which are frequently stored without timestamps).
class LyricsScreen extends ConsumerStatefulWidget {
  const LyricsScreen({super.key, required this.track});
  final Track track;

  @override
  ConsumerState<LyricsScreen> createState() => _LyricsScreenState();
}

/// Result of a lyrics load: either [lines] is non-empty (synced display)
/// or [plainText] is set (unsynced fallback display) — never both.
class _LyricsResult {
  const _LyricsResult({
    this.lines = const [],
    this.plainText,
    this.canRequestFolderAccess = false,
  });
  final List<LyricLine> lines;
  final String? plainText;

  /// True when nothing was found AND the user hasn't granted SAF
  /// folder access yet — the "no lyrics" screen offers a way to grant
  /// it and retry, since that path (sidecar .lrc on Android 13+)
  /// hasn't actually been tried yet in that case.
  final bool canRequestFolderAccess;
}

class _LyricsScreenState extends ConsumerState<LyricsScreen> {
  late Future<_LyricsResult> _lyricsFuture;
  final _scrollController = ScrollController();
  int _lastActiveIndex = -1;
  bool _requestingFolderAccess = false;
  String? _folderAccessError;
  final List<double> _inactiveLineOffsets = <double>[0.0];
  double? _cachedGeometryWidth;

  @override
  void initState() {
    super.initState();
    _lyricsFuture = _loadLyrics();
  }

  Future<_LyricsResult> _loadLyrics({bool forceRefresh = false}) async {
    final repo = ref.read(libraryRepositoryProvider);
    String? rawText;
    try {
      rawText = repo == null
          ? null
          : await repo.ensureLyrics(widget.track, forceRefresh: forceRefresh);
    } on PlatformException catch (e) {
      // On Android 13+, a missing/unusable SAF grant is an access problem,
      // not evidence that the track has no lyrics. Keep the lookup
      // uncached and surface the existing folder-access recovery action.
      if (e.code == 'LYRICS_ACCESS_UNAVAILABLE' &&
          Platform.isAndroid &&
          await PlayerChannel.instance.supportsLyricsFolderRecovery()) {
        return const _LyricsResult(canRequestFolderAccess: true);
      }
      rethrow;
    }
    if (rawText == null || rawText.trim().isEmpty) {
      // No lyrics via embedded tags or a reachable sidecar .lrc. If the
      // user hasn't granted SAF folder access yet, offer that as a next
      // step — MediaStore.Files can't see a sidecar .lrc on Android 13+
      // without it (see native SidecarLyricsResolver).
      // Sidecar resolution requires MediaStore RELATIVE_PATH, which does
      // not exist before Android 10. Do not offer a SAF recovery action on
      // those devices because granting a folder cannot make the resolver
      // address the track.
      if (!Platform.isAndroid ||
          !await PlayerChannel.instance.supportsLyricsFolderRecovery()) {
        return const _LyricsResult();
      }
      final hasFolderAccess = await PlayerChannel.instance.hasLyricsFolderAccess(
        mediaStoreVolume: widget.track.mediaStoreVolume,
        relativePath: widget.track.relativePath,
      );
      return _LyricsResult(canRequestFolderAccess: !hasFolderAccess);
    }

    final lines = LrcParser.parse(rawText);
    // Embedded lyrics are frequently stored as plain unsynced text (no
    // `[mm:ss.xx]` tags) — LrcParser.parse then correctly yields no
    // lines, and we fall back to showing the raw text instead of an
    // empty "no lyrics" screen.
    return lines.isNotEmpty
        ? _LyricsResult(lines: lines)
        : _LyricsResult(plainText: rawText.trim());
  }

  Future<void> _grantFolderAccessAndRetry() async {
    if (!mounted) return;
    setState(() {
      _requestingFolderAccess = true;
      _folderAccessError = null;
    });
    try {
      final granted = await PlayerChannel.instance.requestLyricsFolderAccess();
      if (!mounted) return;
      if (granted) {
        // The cached "no lyrics" result predates folder access — force
        // a fresh lookup instead of trusting it.
        setState(() {
          _lastActiveIndex = -1;
          _inactiveLineOffsets
            ..clear()
            ..add(0.0);
          _cachedGeometryWidth = null;
          _lyricsFuture = _loadLyrics(forceRefresh: true);
        });
      } else {
        setState(() {
          _folderAccessError = 'Folder access was cancelled or not granted.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _folderAccessError = 'Could not open folder access: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _requestingFolderAccess = false);
      }
    }
  }

  double _lineHeight(
    String text,
    double maxWidth,
    TextStyle style,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    return painter.height + 12.0;
  }

  double _offsetBefore(
    List<LyricLine> lines,
    int index,
    double maxWidth,
    TextStyle style,
  ) {
    if (_cachedGeometryWidth != maxWidth || _inactiveLineOffsets.length > lines.length + 1) {
      _inactiveLineOffsets
        ..clear()
        ..add(0.0);
      _cachedGeometryWidth = maxWidth;
    }
    while (_inactiveLineOffsets.length <= index) {
      final i = _inactiveLineOffsets.length - 1;
      _inactiveLineOffsets.add(
        _inactiveLineOffsets.last + _lineHeight(lines[i].text, maxWidth, style),
      );
    }
    return _inactiveLineOffsets[index];
  }

  void _maybeAutoScroll(List<LyricLine> lines, Duration position, double maxWidth) {
    if (lines.isEmpty) return;
    final activeIndex = LrcParser.activeLineIndex(lines, position);
    if (activeIndex == _lastActiveIndex || activeIndex < 0) return;
    _lastActiveIndex = activeIndex;

    if (!_scrollController.hasClients) return;
    final theme = Theme.of(context);
    final inactiveStyle = (theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16))
        .copyWith(fontSize: 16, height: 1.0);
    final before = _offsetBefore(lines, activeIndex, maxWidth, inactiveStyle);
    final activeStyle = inactiveStyle.copyWith(fontSize: 20, fontWeight: FontWeight.w700);
    final activeHeight = _lineHeight(lines[activeIndex].text, maxWidth, activeStyle);
    const verticalPadding = 24.0;
    final target = verticalPadding + before + activeHeight / 2 -
        (_scrollController.position.viewportDimension / 2);
    _scrollController.animateTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent).toDouble(),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }


  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = ref.watch(playbackControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: FutureBuilder<_LyricsResult>(
        future: _lyricsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 40),
                    const SizedBox(height: 12),
                    Text(
                      'Could not load lyrics: ${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () {
                        setState(() {
                          _lastActiveIndex = -1;
                          _inactiveLineOffsets
                            ..clear()
                            ..add(0.0);
                          _cachedGeometryWidth = null;
                          _lyricsFuture = _loadLyrics(forceRefresh: true);
                        });
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final result = snapshot.data ?? const _LyricsResult();
          final lines = result.lines;

          if (lines.isEmpty && result.plainText == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      result.canRequestFolderAccess
                          ? 'No embedded lyrics found for this track.\nIf you have a matching .lrc file next to it, grant folder access to find it.'
                          : 'No lyrics found for this track (checked embedded tags and a sidecar .lrc file).\nAdd lyrics via a tag editor, or place a matching .lrc file next to the song.',
                      textAlign: TextAlign.center,
                    ),
                    if (_folderAccessError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _folderAccessError!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                    if (result.canRequestFolderAccess) ...[
                      const SizedBox(height: 16),
                      FilledButton.tonal(
                        onPressed: _requestingFolderAccess
                            ? null
                            : _grantFolderAccessAndRetry,
                        child: _requestingFolderAccess
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Grant folder access'),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }

          if (lines.isEmpty) {
            // Unsynced lyrics: no timeline to drive auto-scroll or
            // highlighting, so just show the raw text.
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
              child: Text(
                result.plainText!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, height: 1.5),
              ),
            );
          }

          final activeIndex = LrcParser.activeLineIndex(lines, playback.position);
          final maxWidth = (MediaQuery.sizeOf(context).width - 40).clamp(1.0, double.infinity);
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _maybeAutoScroll(lines, playback.position, maxWidth),
          );

          return ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final isActive = index == activeIndex;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  lines[index].text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: isActive ? 20 : 16,
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                    color: isActive
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).textTheme.bodyLarge?.color?.withOpacity(0.5),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
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
  String? _cachedTextScaleSignature;
  TextDirection? _cachedTextDirection;
  Locale? _cachedLocale;

  static const double _listHorizontalPadding = 24;
  static const double _itemHorizontalPadding = 12;
  static const double _itemVerticalMargin = 9;
  static const double _inactiveVerticalPadding = 5;
  static const double _activeVerticalPadding = 10;
  static const double _listTopPadding = 30;

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
          _cachedTextScaleSignature = null;
          _cachedTextDirection = null;
          _cachedLocale = null;
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
    TextStyle style, {
    required double verticalPadding,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout(maxWidth: maxWidth);

    // Match the actual ListView row: Text + vertical item padding +
    // the AnimatedContainer's top/bottom margins.
    return painter.height +
        (verticalPadding * 2) +
        (_itemVerticalMargin * 2);
  }

  double _offsetBefore(
    List<LyricLine> lines,
    int index,
    double maxWidth,
    TextStyle style,
  ) {
    if (_inactiveLineOffsets.length > lines.length + 1) {
      _inactiveLineOffsets
        ..clear()
        ..add(0.0);
    }
    while (_inactiveLineOffsets.length <= index) {
      final i = _inactiveLineOffsets.length - 1;
      _inactiveLineOffsets.add(
        _inactiveLineOffsets.last +
            _lineHeight(
              lines[i].text,
              maxWidth,
              style,
              verticalPadding: _inactiveVerticalPadding,
            ),
      );
    }
    return _inactiveLineOffsets[index];
  }

  void _maybeAutoScroll(
    List<LyricLine> lines,
    Duration position,
    double maxWidth,
  ) {
    if (!mounted || lines.isEmpty) return;

    // TextScaler can be nonlinear, so cache both text sizes actually used
    // by inactive and active lyric rows rather than only scale(1.0).
    final textScaler = MediaQuery.textScalerOf(context);
    final scaleSignature =
        '${textScaler.scale(16).toStringAsPrecision(7)}|'
        '${textScaler.scale(22).toStringAsPrecision(7)}';
    final textDirection = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final geometryChanged = _cachedGeometryWidth != maxWidth ||
        _cachedTextScaleSignature != scaleSignature ||
        _cachedTextDirection != textDirection ||
        _cachedLocale != locale;
    if (geometryChanged) {
      _inactiveLineOffsets
        ..clear()
        ..add(0.0);
      _cachedGeometryWidth = maxWidth;
      _cachedTextScaleSignature = scaleSignature;
      _cachedTextDirection = textDirection;
      _cachedLocale = locale;
      _lastActiveIndex = -1;
    }

    final activeIndex = LrcParser.activeLineIndex(lines, position);
    if (activeIndex == _lastActiveIndex || activeIndex < 0) return;

    // A post-frame callback may run before the ListView attaches its
    // ScrollPosition. Do not mark this line as handled until a scroll can
    // actually be issued, or the current lyric can be skipped permanently.
    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      return;
    }

    final theme = Theme.of(context);
    final inactiveStyle =
        (theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16)).copyWith(
      fontSize: 16,
      height: 1.35,
      fontWeight: FontWeight.w500,
    );
    final before = _offsetBefore(lines, activeIndex, maxWidth, inactiveStyle);
    final activeStyle = inactiveStyle.copyWith(
      fontSize: 22,
      height: 1.35,
      fontWeight: FontWeight.w800,
    );
    final activeHeight = _lineHeight(
      lines[activeIndex].text,
      maxWidth,
      activeStyle,
      verticalPadding: _activeVerticalPadding,
    );
    final target = _listTopPadding +
        before +
        activeHeight / 2 -
        (_scrollController.position.viewportDimension / 2);

    _scrollController.animateTo(
      target
          .clamp(0.0, _scrollController.position.maxScrollExtent)
          .toDouble(),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    _lastActiveIndex = activeIndex;
  }


  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final position = ref.watch(
      playbackControllerProvider.select((state) => state.position),
    );

    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('LYRICS'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 18),
            child: Center(
              child: Icon(Icons.music_note_rounded,
                  color: colors.primary, size: 23),
            ),
          ),
        ],
      ),
      body: FutureBuilder<_LyricsResult>(
        future: _lyricsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Center(
              child: CircularProgressIndicator(color: colors.primary),
            );
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: _LyricsInfoPanel(
                  icon: Icons.cloud_off_rounded,
                  title: 'Could not load lyrics',
                  message: '${snapshot.error}',
                  action: FilledButton.icon(
                    onPressed: () {
                      setState(() {
                        _lastActiveIndex = -1;
                        _inactiveLineOffsets
                          ..clear()
                          ..add(0.0);
                        _cachedGeometryWidth = null;
                        _cachedTextScaleSignature = null;
                        _cachedTextDirection = null;
                        _cachedLocale = null;
                        _lyricsFuture = _loadLyrics(forceRefresh: true);
                      });
                    },
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try again'),
                  ),
                ),
              ),
            );
          }

          final result = snapshot.data ?? const _LyricsResult();
          final lines = result.lines;

          if (lines.isEmpty && result.plainText == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: _LyricsInfoPanel(
                  icon: Icons.lyrics_outlined,
                  title: 'No lyrics found',
                  message: result.canRequestFolderAccess
                      ? 'No embedded lyrics found for this track. If you have a matching .lrc file next to it, grant folder access to find it.'
                      : 'We checked embedded tags and a sidecar .lrc file. Add lyrics with a tag editor, or place a matching .lrc file next to the song.',
                  error: _folderAccessError,
                  action: result.canRequestFolderAccess
                      ? FilledButton.icon(
                          onPressed: _requestingFolderAccess
                              ? null
                              : _grantFolderAccessAndRetry,
                          icon: _requestingFolderAccess
                              ? const SizedBox(
                                  width: 17,
                                  height: 17,
                                  child: CircularProgressIndicator(strokeWidth: 2)
                                )
                              : const Icon(Icons.folder_open_rounded),
                          label: Text(_requestingFolderAccess
                              ? 'Opening folder…'
                              : 'Grant folder access'),
                        )
                      : null,
                ),
              ),
            );
          }

          if (lines.isEmpty) {
            // Unsynced lyrics: no timeline to drive auto-scroll or highlighting.
            return _PlainLyricsView(track: widget.track, text: result.plainText!);
          }

          final activeIndex = LrcParser.activeLineIndex(lines, position);

          return Column(
            children: [
              _LyricsTrackHeader(track: widget.track, synced: true),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Match the exact horizontal space available to each lyric
                    // Text after the ListView and row paddings are applied.
                    final maxWidth = (constraints.maxWidth -
                            (_listHorizontalPadding * 2) -
                            (_itemHorizontalPadding * 2))
                        .clamp(1.0, double.infinity)
                        .toDouble();
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _maybeAutoScroll(lines, position, maxWidth),
                    );
                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(
                        _listHorizontalPadding,
                        _listTopPadding,
                        _listHorizontalPadding,
                        100,
                      ),
                      itemCount: lines.length,
                      itemBuilder: (context, index) {
                        final isActive = index == activeIndex;
                        final distance = (index - activeIndex).abs();
                        return AnimatedContainer(
                          duration: V27Motion.standard,
                          curve: Curves.easeOut,
                          margin: const EdgeInsets.symmetric(
                            vertical: _itemVerticalMargin,
                          ),
                          padding: EdgeInsets.symmetric(
                            horizontal: _itemHorizontalPadding,
                            vertical: isActive
                                ? _activeVerticalPadding
                                : _inactiveVerticalPadding,
                          ),
                          decoration: BoxDecoration(
                            color: isActive
                                ? colors.primary.withValues(
                                    alpha: dark ? 0.16 : 0.10,
                                  )
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                            border: isActive
                                ? Border.all(
                                    color: colors.primary.withValues(
                                      alpha: 0.24,
                                    ),
                                  )
                                : null,
                          ),
                          child: AnimatedDefaultTextStyle(
                            duration: V27Motion.standard,
                            curve: Curves.easeOut,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: isActive ? 22 : 16,
                              height: 1.35,
                              fontWeight: isActive
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              color: isActive
                                  ? colors.primary
                                  : theme.textTheme.bodyLarge?.color?.withValues(
                                      alpha: distance == 1 ? 0.58 : 0.32,
                                    ),
                            ),
                            child: Text(lines[index].text),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}


class _LyricsTrackHeader extends StatelessWidget {
  const _LyricsTrackHeader({required this.track, required this.synced});

  final Track track;
  final bool synced;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 8, 18, 0),
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: Theme.of(context).brightness == Brightness.dark
              ? [
                  V27Palette.midnight,
                  Color.lerp(colors.primary, V27Palette.midnight, 0.72)!,
                ]
              : [
                  Color.lerp(colors.primary, Colors.white, 0.84)!,
                  const Color(0xFFE9EEF2),
                ],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: colors.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 45,
            height: 45,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.music_note_rounded,
                color: colors.primary, size: 25),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        )),
                const SizedBox(height: 4),
                Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).hintColor,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            children: [
              Icon(Icons.graphic_eq_rounded,
                  color: synced ? colors.secondary : colors.primary),
              const SizedBox(height: 3),
              Text(
                synced ? 'SYNCED' : 'LYRICS',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontSize: 9,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlainLyricsView extends StatelessWidget {
  const _PlainLyricsView({required this.track, required this.text});

  final Track track;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _LyricsTrackHeader(track: track, synced: false),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(26, 28, 26, 48),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontSize: 17,
                    height: 1.85,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LyricsInfoPanel extends StatelessWidget {
  const _LyricsInfoPanel({
    required this.icon,
    required this.title,
    required this.message,
    this.error,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? error;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(25),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(icon, color: colors.primary, size: 31),
          ),
          const SizedBox(height: 17),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 9),
          Text(message, textAlign: TextAlign.center),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 19),
            action!,
          ],
        ],
      ),
    );
  }
}

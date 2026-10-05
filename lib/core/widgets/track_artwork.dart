import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';

/// Shows a track's embedded album art (fetched + cached via
/// [albumArtProvider]), falling back to a music-note placeholder while
/// loading or when the track has no embedded artwork.
///
/// RESILIENCE / SMOOTH SCROLLING: while the enclosing list is flinging
/// fast (`Scrollable.recommendDeferredLoadingForContext`), this skips
/// starting the fetch entirely and shows the placeholder instead — a
/// fling can pass over hundreds of rows in well under a second, and
/// eagerly kicking off a platform-channel thumbnail load
/// load for every one of them (most never even settling on screen long
/// enough to matter) is exactly the kind of burst that backs up the
/// native decode pipeline and shows up as jank. Once scrolling settles,
/// a short retry timer lets the row re-check and load normally.
class TrackArtwork extends ConsumerStatefulWidget {
  const TrackArtwork({
    super.key,
    required this.contentUri,
    required this.version,
    this.size,
    this.artSize = 256,
    this.borderRadius,
  });

  /// The track's `content://` URI (see [Track.contentUri]).
  final String contentUri;

  /// Cache version derived from MediaStore row generation on API 30+ and
  /// metadata/date fields on legacy Android. It must change whenever the
  /// scanner can prove that the MediaStore row changed.
  final int version;

  /// Fixed square side length to render at. Null fills whatever space
  /// the parent gives it (e.g. inside an `AspectRatio` box on the Now
  /// Playing screen).
  final double? size;

  /// Pixel size requested from the native thumbnail loader — kept
  /// separate from [size] (the widget's *rendered* logical size) so a
  /// small list thumbnail and the large Now Playing artwork cache (and
  /// decode) independently at sizes appropriate to each, instead of one
  /// oversized bitmap being fetched for every use site.
  final int artSize;

  final BorderRadius? borderRadius;

  @override
  ConsumerState<TrackArtwork> createState() => _TrackArtworkState();
}

class _TrackArtworkState extends ConsumerState<TrackArtwork> {
  static const _deferredRetryDelay = Duration(milliseconds: 250);

  Timer? _deferredRetryTimer;

  @override
  void dispose() {
    _deferredRetryTimer?.cancel();
    // The artwork provider is autoDispose. Its onDispose callback releases
    // this widget's specific native artwork consumer, while allowing any
    // other widget/provider consumer of the same artwork to keep the shared
    // operation alive.
    super.dispose();
  }

  void _scheduleDeferredRetry() {
    if (_deferredRetryTimer?.isActive ?? false) return;

    _deferredRetryTimer = Timer.periodic(_deferredRetryDelay, (timer) {
      if (!mounted) {
        timer.cancel();
        _deferredRetryTimer = null;
        return;
      }
      if (!Scrollable.recommendDeferredLoadingForContext(context)) {
        timer.cancel();
        _deferredRetryTimer = null;
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? BorderRadius.circular((widget.size ?? 64) / 5);

    if (Scrollable.recommendDeferredLoadingForContext(context)) {
      _scheduleDeferredRetry();
      return _sized(radius, _placeholder(context));
    }

    final art = ref
        .watch(albumArtProvider((contentUri: widget.contentUri, size: widget.artSize, version: widget.version)));

    final child = art.when(
      data: (bytes) => bytes == null
          ? _placeholder(context)
          : Image.memory(bytes, fit: BoxFit.cover),
      loading: () => _placeholder(context),
      error: (_, __) => _placeholder(context),
    );

    return _sized(radius, child);
  }

  Widget _sized(BorderRadius radius, Widget child) {
    return ClipRRect(
      borderRadius: radius,
      child: widget.size == null
          ? SizedBox.expand(child: child)
          : SizedBox(width: widget.size, height: widget.size, child: child),
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.primary.withOpacity(0.15),
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note,
        size: (widget.size ?? 64) * 0.45,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

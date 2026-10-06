/// A single timestamped lyric line.
class LyricLine {
  const LyricLine(this.timestamp, this.text);
  final Duration timestamp;
  final String text;
}

/// Parses standard `.lrc` synced lyric files, including metadata-prefixed
/// lines such as `[ar:Artist][ti:Title][00:12.34]Lyrics`.
class LrcParser {
  static final _tokenExp = RegExp(r'^\[([^\]]*)\]');
  static final _timestampExp =
      RegExp(r'^(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?$');
  static final _offsetExp = RegExp(r'^offset:([+-]?\d+)$', caseSensitive: false);
  static const _metadataKeys = <String>{
    'ar', 'al', 'ti', 'by', 're', 've', 'length', 'offset',
  };

  /// Offsets beyond one day are treated as malformed/untrusted metadata.
  static const int _maxOffsetMs = 24 * 60 * 60 * 1000;

  static List<LyricLine> parse(String raw) {
    final lines = <LyricLine>[];
    var offsetMs = 0;

    for (final rawLine in (raw.startsWith('\uFEFF') ? raw.substring(1) : raw).split(RegExp(r'\r?\n'))) {
      var remaining = rawLine.trim();
      final timestamps = <Duration>[];
      var lyricPrefix = '';

      // Metadata may precede the first timestamp, while multiple timestamps
      // may be chained before the lyric text. Once a timestamp has been seen,
      // stop consuming non-timestamp bracket tokens so lyric text such as
      // `[Intro] Hello` is preserved verbatim.
      while (remaining.startsWith('[')) {
        final token = _tokenExp.firstMatch(remaining);
        if (token == null) break;

        final body = token.group(1)!;
        final timestampMatch = _timestampExp.firstMatch(body);
        if (timestampMatch != null) {
          final minutes = int.parse(timestampMatch.group(1)!);
          final seconds = int.parse(timestampMatch.group(2)!);
          if (seconds >= 60) break;
          final fraction = timestampMatch.group(3);
          final millis = fraction == null
              ? 0
              : int.parse(fraction.padRight(3, '0').substring(0, 3));
          timestamps.add(Duration(
            minutes: minutes,
            seconds: seconds,
            milliseconds: millis,
          ));
          remaining = remaining.substring(token.end).trimLeft();
          continue;
        }

        // After a timestamp, non-timestamp brackets belong to lyric text.
        if (timestamps.isNotEmpty) break;

        final offsetMatch = _offsetExp.firstMatch(body);
        final colon = body.indexOf(':');
        final metadataKey = colon > 0 ? body.substring(0, colon).toLowerCase() : '';
        if (offsetMatch != null) {
          final parsed = int.tryParse(offsetMatch.group(1)!);
          if (parsed != null && parsed.abs() <= _maxOffsetMs) {
            offsetMs = parsed;
          }
        } else if (_metadataKeys.contains(metadataKey)) {
          // Recognized LRC metadata is consumed before the first timestamp.
        } else {
          // An unknown bracketed token is lyric text, not metadata. Preserve
          // it while continuing to locate a later timestamp on the same line.
          // This prevents arbitrary `[Intro]`/`[Verse]`-style text from being
          // silently discarded while still allowing `[Intro][00:12]Hello`.
          lyricPrefix += remaining.substring(0, token.end);
          remaining = remaining.substring(token.end);
          final whitespace = RegExp(r'^\s+').firstMatch(remaining);
          if (whitespace != null) {
            lyricPrefix += whitespace.group(0)!;
            remaining = remaining.substring(whitespace.end);
          }
          continue;
        }

        remaining = remaining.substring(token.end).trimLeft();
      }

      if (timestamps.isEmpty) continue;
      final lyricText = remaining.trim();
      final separator = lyricPrefix.isNotEmpty && lyricText.isNotEmpty &&
              !RegExp(r'\s$').hasMatch(lyricPrefix)
          ? ' '
          : '';
      final text = '$lyricPrefix$separator$lyricText'.trim();
      if (text.isEmpty) continue;

      for (final timestamp in timestamps) {
        final adjustedMs = timestamp.inMilliseconds + offsetMs;
        lines.add(
          LyricLine(
            Duration(milliseconds: adjustedMs < 0 ? 0 : adjustedMs),
            text,
          ),
        );
      }
    }

    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return lines;
  }

  static int activeLineIndex(List<LyricLine> lines, Duration position) {
    var low = 0;
    var high = lines.length - 1;
    var active = -1;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      if (lines[mid].timestamp <= position) {
        active = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return active;
  }
}

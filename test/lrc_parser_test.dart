import 'package:flutter_test/flutter_test.dart';
import 'package:offline_music_player/features/lyrics/lrc_parser.dart';

void main() {
  test('parses multiple timestamps on one LRC line', () {
    final lines = LrcParser.parse('[00:12.34][00:25.10]Same lyric\n[01:02.5]Next');
    expect(lines.length, 3);
    expect(lines[0].timestamp, const Duration(seconds: 12, milliseconds: 340));
    expect(lines[1].timestamp, const Duration(seconds: 25, milliseconds: 100));
    expect(lines[2].timestamp, const Duration(minutes: 1, seconds: 2, milliseconds: 500));
    expect(lines[0].text, 'Same lyric');
    expect(lines[1].text, 'Same lyric');
  });

  test('accepts metadata before a timestamp', () {
    final lines = LrcParser.parse('[ar:Artist][ti:Title][00:12.34]Lyrics');
    expect(lines.single.timestamp, const Duration(seconds: 12, milliseconds: 340));
    expect(lines.single.text, 'Lyrics');
  });

  test('preserves bracketed lyric text after a timestamp', () {
    final lines = LrcParser.parse('[00:12] [Intro] Hello');
    expect(lines.single.timestamp, const Duration(seconds: 12));
    expect(lines.single.text, '[Intro] Hello');
  });

  test('metadata-only tags produce no lyric lines', () {
    expect(LrcParser.parse('[ar:Artist][ti:Title][al:Album]'), isEmpty);
  });

  test('applies positive and negative offsets', () {
    expect(
      LrcParser.parse('[offset:+150]\n[00:01.00]Hello').single.timestamp,
      const Duration(milliseconds: 1150),
    );
    expect(
      LrcParser.parse('[offset:-2000]\n[00:01.00]Hello').single.timestamp,
      Duration.zero,
    );
  });

  test('ignores absurd offsets', () {
    expect(
      LrcParser.parse('[offset:+999999999]\n[00:01.00]Hello').single.timestamp,
      const Duration(seconds: 1),
    );
  });

  test('rejects malformed timestamps and invalid seconds', () {
    expect(LrcParser.parse('[00:99.00]bad'), isEmpty);
    expect(LrcParser.parse('[xx:12.00]bad'), isEmpty);
    expect(LrcParser.parse('[00:01.9999]bad'), isEmpty);
  });

  test('strips a UTF-8 BOM', () {
    final lines = LrcParser.parse('\uFEFF[00:01.00]Hello');
    expect(lines.single.text, 'Hello');
  });
}

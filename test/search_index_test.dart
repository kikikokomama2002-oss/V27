import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';

import '../lib/data/db/track.dart';

void main() {
  final isUnsupportedLinuxArm64 = Abi.current() == Abi.linuxArm64;

  test(
    'searchWords contains Unicode-aware words from title, artist and album',
    () {
      final track = Track()
        ..title = 'The Blue Café'
        ..artist = 'José & The Kids'
        ..album = 'Live, Vol. 2';

      expect(track.searchWords, contains('The'));
      expect(track.searchWords, contains('Blue'));
      expect(track.searchWords, contains('Café'));
      expect(track.searchWords, contains('José'));
      expect(track.searchWords, contains('Kids'));
      expect(track.searchWords, contains('Live'));
      expect(track.searchWords, contains('Vol'));
    },
    skip: isUnsupportedLinuxArm64,
  );

  test(
    'punctuation-only input has no searchable tokens',
    () {
      expect(Isar.splitWords('!!! ??? ---').isEmpty, isTrue);
    },
    skip: isUnsupportedLinuxArm64,
  );

  test(
    'searchWords does not depend on arbitrary substring fragments',
    () {
      final track = Track()
        ..title = 'Sunshine'
        ..artist = 'Example'
        ..album = 'Album';

      expect(track.searchWords, contains('Sunshine'));
      expect(track.searchWords, isNot(contains('unsh')));
    },
    skip: isUnsupportedLinuxArm64,
  );
}

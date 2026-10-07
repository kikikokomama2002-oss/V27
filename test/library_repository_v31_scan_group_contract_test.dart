import 'dart:io';

import 'package:test/test.dart';

void main() {
  final source = File('lib/data/repositories/library_repository.dart').readAsStringSync();

  test('full scans have no timestamp upper bound', () {
    expect(
      source,
      contains('''untilTimestamp: effectiveVolumeFullScan\n              ? 9223372036854775807\n              : (useGenerationCursor ? 0 : scanUntilSeconds),'''),
    );
    expect(
      source,
      isNot(contains('''untilTimestamp: effectiveVolumeFullScan || useGenerationCursor\n              ? (useGenerationCursor ? 0 : scanUntilSeconds)''')),
    );
  });

  test('countsForGroups matches countForGroup blank-name semantics', () {
    final start = source.indexOf('Future<Map<String, int>> countsForGroups');
    expect(start, greaterThanOrEqualTo(0));
    final end = source.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final body = source.substring(start, end);
    expect(body, isNot(contains("throw ArgumentError.value(name, 'names', 'invalid group name')")));
    expect(body, contains('final counts = <String, int>{for (final name in names) name: 0};'));
  });
}

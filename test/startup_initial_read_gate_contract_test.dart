import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('repository exposes a bounded initial library read gate', () {
    final source = File(
      'lib/data/repositories/library_repository.dart',
    ).readAsStringSync();

    expect(source, contains('final Completer<void> _initialLibraryReadCompleter'));
    expect(source, contains('Future<void> waitForInitialLibraryRead()'));
    expect(source, contains('Duration(seconds: 5)'));
    expect(source, contains('_initialLibraryReadCompleter.isCompleted'));
  });

  test('unfiltered tracks paging releases the initial read gate', () {
    final source = File('lib/core/providers.dart').readAsStringSync();
    final start = source.indexOf('class TracksPagingNotifier');
    final end = source.indexOf('class GroupsPagingNotifier', start);

    expect(start, isNonNegative);
    expect(end, greaterThan(start));

    final tracks = source.substring(start, end);
    expect(tracks, contains('if (_query.isEmpty) repo.completeInitialLibraryRead();'));
    expect(
      tracks,
      contains('if (_query.isEmpty && count == 0)'),
    );
  });

  test('startup waits for the first read and preserves reconciliation', () {
    final source = File('lib/main.dart').readAsStringSync();
    final gate = source.indexOf('await repository.waitForInitialLibraryRead();');
    final frame = source.indexOf('await WidgetsBinding.instance.endOfFrame;', gate);
    final scan = source.indexOf('await repository.scanAndPersist();', frame);
    final reconcile = source.indexOf(
      'await repository.requestStartupDeletionReconciliation();',
      scan,
    );

    expect(gate, isNonNegative);
    expect(frame, greaterThan(gate));
    expect(scan, greaterThan(frame));
    expect(reconcile, greaterThan(scan));
  });
}

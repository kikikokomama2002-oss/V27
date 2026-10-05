import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_music_player/core/paging/windowed_paging.dart';

class _FakePager extends WindowedPagingNotifier<int> {
  _FakePager() : super(pageSize: 2, maxPagesInMemory: 2);

  final Map<int, Completer<List<int>>> requests = {};

  @override
  Future<List<int>> fetchPage({required int offset, required int limit}) {
    final c = Completer<List<int>>();
    requests[offset] = c;
    return c.future;
  }

  @override
  Future<int> fetchCount() async => 10;
}

void main() {
  test('page completion updates provider state', () async {
    final pager = _FakePager();
    addTearDown(pager.dispose);

    pager.itemAt(0);
    await Future<void>.delayed(Duration.zero);
    pager.requests[0]!.complete([10, 11]);
    await Future<void>.delayed(Duration.zero);

    expect(pager.state.pages[0], [10, 11]);
    expect(pager.itemAt(1), 11);
  });

  test('stale page result is discarded after reset', () async {
    final pager = _FakePager();
    addTearDown(pager.dispose);

    pager.itemAt(0);
    await Future<void>.delayed(Duration.zero);
    final request = pager.requests[0]!;
    pager.reset();
    request.complete([10, 11]);
    await Future<void>.delayed(Duration.zero);

    expect(pager.state.pages, isEmpty);
  });


  test('reset chains a fresh page query after the stale request completes', () async {
    final pager = _FakePager();
    addTearDown(pager.dispose);

    pager.itemAt(0);
    await Future<void>.delayed(Duration.zero);
    final first = pager.requests[0]!;
    pager.reset();
    pager.itemAt(0);
    await Future<void>.delayed(Duration.zero);

    // The stale query remains the only physical query until it completes;
    // the new generation owns a chained replacement rather than receiving
    // the stale Future forever.
    expect(pager.requests.length, 1);
    first.complete([20, 21]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(pager.requests.length, 1);
    final fresh = pager.requests[0]!;
    expect(fresh.isCompleted, isFalse);
    fresh.complete([30, 31]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(pager.state.pages[0], [30, 31]);
  });


  test('stale generation requests do not consume the pending admission budget', () async {
    final pager = _FakePager();
    addTearDown(pager.dispose);

    // Fill the pending budget with distinct pages in generation 0.
    for (var page = 0; page < 32; page++) {
      pager.itemAt(page * pager.pageSize);
    }
    await Future<void>.delayed(Duration.zero);
    expect(pager.requests.length, 4); // physical concurrency is still capped.

    pager.reset();
    // A fresh-generation page must still be admitted even though stale
    // generation-0 requests remain physically in flight.
    pager.itemAt(100); // offset 100 -> page 50
    await Future<void>.delayed(Duration.zero);
    // It is chained behind the stale request for the same admission slot, but
    // must exist in the scheduler rather than being rejected by the 32-pending
    // guard. Complete one old request to let the fresh chain advance.
    pager.requests[0]!.complete([1, 2]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(pager.requests.keys, contains(100));
  });

  test('failed page remains explicitly retryable', () async {
    final pager = _FakePager();
    addTearDown(pager.dispose);

    pager.itemAt(0);
    await Future<void>.delayed(Duration.zero);
    pager.requests[0]!.completeError(StateError('boom'));
    await Future<void>.delayed(Duration.zero);

    expect(pager.pageErrorAt(0), isA<StateError>());
  });
}

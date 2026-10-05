import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('scan requests are serialized through the pending request queue', () {
    final source = File('lib/data/repositories/library_repository.dart').readAsStringSync();
    expect(source, contains('_pendingScanRequestQueue.add(request);'));
    expect(source, contains('_takePendingScanRequests();'));
    expect(source, contains('reconcileDeletions |= request.reconcileDeletions;'));
    expect(source, isNot(contains('_scanRequestGeneration')));
    expect(source, isNot(contains('_scanCoveredRequestGeneration')));
  });
}

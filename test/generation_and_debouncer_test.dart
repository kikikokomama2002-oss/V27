import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_music_player/core/debouncer.dart';
import 'package:offline_music_player/core/generation_gate.dart';

void main() {
  test('older queue generation can never become current after B starts', () {
    final gate = GenerationGate();
    final a = gate.begin();
    final b = gate.begin();

    expect(gate.isCurrent(a), isFalse);
    expect(gate.isCurrent(b), isTrue);
  });

  test('rapid search changes coalesce to the newest query', () async {
    final debouncer = Debouncer(Duration.zero);
    addTearDown(debouncer.dispose);
    final published = <String>[];

    debouncer.call(() => published.add('a'));
    debouncer.call(() => published.add('ab'));
    debouncer.call(() => published.add('abc'));

    await Future<void>.delayed(Duration.zero);
    expect(published, ['abc']);
  });
}

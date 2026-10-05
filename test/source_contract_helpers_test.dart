import 'package:test/test.dart';

import 'source_contract_helpers.dart';

void main() {
  test('extractBlock ignores markers inside comments and strings', () {
    const source = '''
// void target() { fake }
final fake = "void target() { also fake }";
void target() {
  /* void target() { nested fake } */
  final value = "}";
  if (value.isNotEmpty) { print(value); }
}
''';
    final body = extractBlock(source, 'void target()');
    expect(body, contains('final value = "}";'));
    expect(body, contains('if (value.isNotEmpty)'));
    expect(body, isNot(contains('also fake')));
  });

  test('extractBlock handles triple-quoted strings before structural braces', () {
    const source = '''
String fake = """void target() { not code }""";
void target() {
  final text = """{ still text }""";
}
''';
    final body = extractBlock(source, 'void target()');
    expect(body, contains('final text = """{ still text }""";'));
  });
  test('extractBlock uses a structural brace already contained in the marker', () {
    const source = '''
class Track {
  /// content://media/external/audio/media/{id}
  static String computeFolder(String value) {
    return value;
  }
  String title = 'Track';
}
''';
    final body = extractBlock(source, 'class Track {', markerContainsOpeningBrace: true);
    expect(body, contains("String title = 'Track';"));
    expect(body, contains('static String computeFolder'));
    expect(body, isNot(contains('class Other')));
  });

  test('extractBlock does not use a brace from a comment after a marker', () {
    const source = '''
void target({
  String value = 'x',
}) {
  /* fake { comment brace */
  if (value.isNotEmpty) {
    print(value);
  }
}
''';
    final body = extractBlock(source, 'void target({', markerContainsOpeningBrace: true);
    expect(body, contains('if (value.isNotEmpty)'));
    expect(body, contains('print(value);'));
  });

}


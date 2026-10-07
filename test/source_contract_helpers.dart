import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

int _findCodeMarker(String source, String marker, [int from = 0]) {
  var lineComment = false;
  var blockComment = false;
  var quote = '';
  var tripleQuote = false;
  var escaped = false;

  for (var i = from; i < source.length; i++) {
    final c = source[i];
    final n = i + 1 < source.length ? source[i + 1] : '';
    final n2 = i + 2 < source.length ? source.substring(i, i + 3) : '';

    if (lineComment) {
      if (c == '\n') lineComment = false;
      continue;
    }

    if (blockComment) {
      if (c == '*' && n == '/') {
        blockComment = false;
        i++;
      }
      continue;
    }

    if (tripleQuote) {
      if (n2 == '$quote$quote$quote') {
        tripleQuote = false;
        quote = '';
        i += 2;
      }
      continue;
    }

    if (quote.isNotEmpty) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == quote) {
        quote = '';
      }
      continue;
    }

    if (c == '/' && n == '/') {
      lineComment = true;
      i++;
      continue;
    }

    if (c == '/' && n == '*') {
      blockComment = true;
      i++;
      continue;
    }

    // Contract markers may intentionally start with a quote,
    // e.g. `"getAlbumArt" -> {`.
    if (source.startsWith(marker, i)) return i;

    if ((c == '"' || c == "'") && n2 == '$c$c$c') {
      quote = c;
      tripleQuote = true;
      i += 2;
      continue;
    }

    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }
  }

  return -1;
}

int _findStructuralOpeningBrace(String source, int start, int markerEnd, {required bool markerContainsOpeningBrace}) {
  var quote = '';
  var tripleQuote = false;
  var escaped = false;
  var lineComment = false;
  var blockComment = false;
  int? markerBrace;

  for (var i = start; i < source.length; i++) {
    final c = source[i];
    final n = i + 1 < source.length ? source[i + 1] : '';
    final n2 = i + 2 < source.length ? source.substring(i, i + 3) : '';

    if (lineComment) {
      if (c == '\n') lineComment = false;
      continue;
    }
    if (blockComment) {
      if (c == '*' && n == '/') {
        blockComment = false;
        i++;
      }
      continue;
    }
    if (tripleQuote) {
      if (n2 == '$quote$quote$quote') {
        tripleQuote = false;
        quote = '';
        i += 2;
      }
      continue;
    }
    if (quote.isNotEmpty) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == quote) {
        quote = '';
      }
      continue;
    }

    if (c == '/' && n == '/') {
      lineComment = true;
      i++;
      continue;
    }
    if (c == '/' && n == '*') {
      blockComment = true;
      i++;
      continue;
    }
    if ((c == '"' || c == "'") && n2 == '$c$c$c') {
      quote = c;
      tripleQuote = true;
      i += 2;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }

    if (c == '{') {
      if (i < markerEnd) {
        if (markerContainsOpeningBrace) {
          markerBrace = i;
        }
      } else {
        return i;
      }
    }

    if (i + 1 == markerEnd && markerContainsOpeningBrace && markerBrace != null) {
      return markerBrace;
    }
  }

  return markerBrace ?? -1;
}

String extractBlock(String source, String marker, {bool markerContainsOpeningBrace = false}) {
  final start = _findCodeMarker(source, marker);
  if (start < 0) throw StateError('Missing source marker: $marker');

  final markerEnd = start + marker.length;
  final open = _findStructuralOpeningBrace(
    source,
    start,
    markerEnd,
    markerContainsOpeningBrace: markerContainsOpeningBrace,
  );
  if (open < 0) throw StateError('Missing opening brace after: $marker');

  var depth = 0;
  var quote = '';
  var tripleQuote = false;
  var escaped = false;
  var lineComment = false;
  var blockComment = false;

  for (var i = open; i < source.length; i++) {
    final c = source[i];
    final n = i + 1 < source.length ? source[i + 1] : '';
    final n2 = i + 2 < source.length ? source.substring(i, i + 3) : '';

    if (lineComment) {
      if (c == '\n') lineComment = false;
      continue;
    }
    if (blockComment) {
      if (c == '*' && n == '/') {
        blockComment = false;
        i++;
      }
      continue;
    }
    if (tripleQuote) {
      if (n2 == '$quote$quote$quote') {
        tripleQuote = false;
        quote = '';
        i += 2;
      }
      continue;
    }
    if (quote.isNotEmpty) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == quote) {
        quote = '';
      }
      continue;
    }

    if (c == '/' && n == '/') {
      lineComment = true;
      i++;
      continue;
    }
    if (c == '/' && n == '*') {
      blockComment = true;
      i++;
      continue;
    }
    if ((c == '"' || c == "'") && n2 == '$c$c$c') {
      quote = c;
      tripleQuote = true;
      i += 2;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }

    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  throw StateError('Unclosed source block: $marker');
}

bool occursInOrder(String source, List<String> markers) {
  var cursor = -1;
  for (final marker in markers) {
    final next = source.indexOf(marker, cursor + 1);
    if (next < 0) return false;
    cursor = next;
  }
  return true;
}

void expectContains(String source, String expected, [String? reason]) {
  expect(source, contains(expected), reason: reason);
}

void expectNotContains(String source, String unexpected, [String? reason]) {
  expect(source, isNot(contains(unexpected)), reason: reason);
}

String readProjectFile(String path) => File(path).readAsStringSync();

void contractExpect(String source, String expected, [String? reason]) {
  expect(source, contains(expected), reason: reason);
}

void contractExpectAbsent(String source, String unexpected, [String? reason]) {
  expect(source, isNot(contains(unexpected)), reason: reason);
}

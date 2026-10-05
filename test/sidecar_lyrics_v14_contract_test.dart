import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('android/app/src/main/kotlin/com/example/musicplayer/lyrics/SidecarLyricsResolver.kt').readAsStringSync();

  test('MediaStore sidecar lookup restores RELATIVE_PATH trailing slash', () {
    expect(source, contains("val mediaStoreRelativePath = \"\${relativePath.trimEnd('/')}/\""));
    expect(source, contains('val args = arrayOf(mediaStoreRelativePath, escapeLike(expectedName))'));
    expect(source, contains('MediaStore stores RELATIVE_PATH as a directory path with a terminal'));
  });

  test('SAF continues to use slash-free relative path identity', () {
    expect(source, contains("val targetPath = relativePath.trim('/').trim()"));
  });
}

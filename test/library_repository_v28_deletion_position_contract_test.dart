import 'dart:io';

import 'package:test/test.dart';

import 'source_contract_helpers.dart';

String _readRepo() =>
    File('lib/data/repositories/library_repository.dart').readAsStringSync();

void main() {
  test('deletion reconciliation protects metadata-changed identities before delete', () {
    final source = _readRepo();
    final deletion = extractBlock(source, 'Future<void> _syncDeletions({');

    expect(
      occursInOrder(deletion, [
        'if (!existing.contains(key)) {',
        'final stillPresent = await PlayerChannel.instance',
        'findExistingMediaStoreObserverIdentities(staleIdentities);',
        'staleIsarIds',
        'await _isar.writeTxn(() async {',
      ]),
      isTrue,
    );
  });

    test('committed deletions are published when deletion reconciliation fails', () {
      final source = _readRepo();
      final deletion = extractBlock(source, 'Future<void> _syncDeletions({');
      final unstable = deletion.indexOf(
        "throw StateError('MediaStore volume set changed before deletion commit');",
      );
      expect(unstable, greaterThan(0));
      expect(deletion, contains('_tracksDeletedController.add('));
      expect(deletion, contains('List.unmodifiable(deletedIdentities)'));
    });

  test('deletion events are always exposed as immutable lists', () {
    final source = _readRepo();
    expect(source, isNot(contains('_tracksDeletedController.add(deletedIdentities);')));
    expect(
      source,
      contains('_tracksDeletedController.add(List.unmodifiable(deletedIdentities));'),
    );
  });

  test('position queries use the normalized identity volume', () {
    final source = _readRepo();
    final search = extractBlock(source, 'Future<int?> searchPosition(');
    final group = extractBlock(source, 'Future<int?> groupPosition(');

    expect(
      search,
      contains('.mediaStoreVolumeEqualTo(current.mediaStoreVolume)'),
    );
    expect(
      group,
      contains(
        '.mediaStoreVolumeMediaStoreIdEqualTo(current.mediaStoreVolume, mediaStoreId)',
      ),
    );
  });


test('generation payload fields tolerate omitted native values', () {
  final source = _readRepo();
    expect(source, contains("(currentVolumeStates[entry.key]?['generation'] as num?)?.toInt() ?? 0"));
    expect(source, contains("(entry.value['lifecycleGeneration'] as num?)?.toInt() ?? 0"));
    expect(source, isNot(contains("(currentVolumeStates[entry.key]?['generation'] as num).toInt()")));
    expect(source, isNot(contains("(entry.value['lifecycleGeneration'] as num).toInt()")));
});

test('recreated targeted rows count as a tracksChanged mutation', () {
  final source = _readRepo();
  final handler = extractBlock(source, 'Future<void> handleMediaStoreChanged({');
  expect(occursInOrder(handler, [
    'final reconciliation =',
    'await _reconcileMediaStoreChangeIdentitiesLocked(identities);',
    'reconciliation.recreated',
    "_tracksChangedController.add(null);",
  ]), isTrue);
  expect(source, contains('final recreatedUpserted ='));
  expect(source, contains('recreatedMutation = recreatedMutation || recreatedUpserted;'));
});

test('sync crash marker is written only after native generation succeeds', () {
  final source = _readRepo();
  final scan = extractBlock(source, 'Future<void> _scanAndPersistInternalImpl({');
  expect(occursInOrder(scan, [
    'final prefs = await SharedPreferences.getInstance();',
      '_libraryGeneration = _libraryGeneration + 1;',
    'await PlayerChannel.instance.updateLibraryGeneration(_libraryGeneration);',
    'await prefs.setBool(_syncInProgressKey, true);',
  ]), isTrue);
});

test('dispose closes repository streams and scan page has no empty-page retry loop', () {
  final source = _readRepo();
  final dispose = extractBlock(source, 'void dispose()');
  final page = extractBlock(source, 'Future<List<Map<String, dynamic>>> _readScanPage({');
  expect(dispose, contains('disposeStreams();'));
  expect(page, isNot(contains('for (var attempt = 0; attempt < 3; attempt++)')));
  expect(page, isNot(contains('lastError')));
});

}

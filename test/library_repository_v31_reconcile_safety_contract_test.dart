import 'dart:io';

void main() {
  final source = File('lib/data/repositories/library_repository.dart').readAsStringSync();

  // Routine full enumeration/reconciliation must not invalidate every
  // derived cache entry. Only version/lifecycle boundaries may do so.
  final persistCall = RegExp(
    r'invalidateDerivedCache:\s*versionChanged\s*\|\|\s*lifecycleChanged',
  );
  assert(
    persistCall.hasMatch(source),
    'Routine full scans must not invalidate all derived caches',
  );
  assert(
    !source.contains('invalidateDerivedCache: effectiveVolumeFullScan || versionChanged'),
    'Legacy/recovery full scans must not force derived-cache invalidation',
  );

  // Malformed observer identities are untrusted hints and must not abort the
  // entire event or prevent the valid identities from being processed.
  assert(
    source.contains('if (separator <= 0 || separator >= raw.length - 1) continue;'),
    'Invalid observer identities must be skipped',
  );
  assert(
    source.contains('if (volume.isEmpty || id == null || id <= 0) continue;'),
    'Invalid parsed observer identities must be skipped',
  );
  assert(
    source.contains('if (parsed.isEmpty) return (deleted: 0, recreated: false);'),
    'All-invalid reconciliation input must be a safe no-op',
  );
}

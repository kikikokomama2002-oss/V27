import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'package:permission_handler/permission_handler.dart';
import 'core/permissions.dart';
import 'core/providers.dart';
import 'core/theme.dart';
import 'features/library/library_screen.dart';
import 'headless_main.dart';

// MobileAds.instance.initialize() removed for the pure offline MVP
// release — see lib/ads_iap/README.md to reintroduce.

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: OfflineMusicPlayerApp()));
}

class OfflineMusicPlayerApp extends StatelessWidget {
  const OfflineMusicPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline Music Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.amoledDark(),
      themeMode: ThemeMode.dark,
      home: const _StartupGate(),
    );
  }
}

/// Requests permissions and triggers the first library scan before
/// showing the library screen, so the user never sees a blank/broken
/// list on first launch.
class _StartupGate extends ConsumerStatefulWidget {
  const _StartupGate();

  @override
  ConsumerState<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends ConsumerState<_StartupGate> {
  bool _ready = false;
  bool _permissionDenied = false;
  bool _permissionPermanentlyDenied = false;
  String? _startupError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    if (!mounted) return;
    setState(() {
      _startupError = null;
      _permissionDenied = false;
      _permissionPermanentlyDenied = false;
    });

    try {
      final permission = await PermissionsHelper.requestAudioPermission();
      await PermissionsHelper.requestNotificationPermission();

      if (!permission.granted) {
        if (!mounted) return;
        setState(() {
          _permissionDenied = true;
          _permissionPermanentlyDenied = permission.permanentlyDenied;
        });
        return;
      }

      // Ensure Isar is open before triggering the first scan.
      await ref.read(isarProvider.future);
      final repository = ref.read(libraryRepositoryProvider);
      if (repository == null) {
        throw StateError('Library database is not available yet.');
      }

      // Never block the first frame on a full MediaStore reconciliation.
      // Existing Isar data can render immediately; the bounded background
      // scan progressively refreshes it and emits one coalesced invalidation
      // when finished. This keeps large libraries usable at startup.
      if (!mounted) return;
      setState(() {
        _ready = true;
        _startupError = null;
      });
      unawaited(() async {
        try {
          // First establish the fast incremental library state. A new process
          // never inherits deletion-observation coverage from the previous
          // process, so once this scan succeeds, immediately enqueue the
          // existing serialized deletion-reconciliation pipeline. The second
          // phase is intentionally not awaited by the startup gate.
          await repository.scanAndPersist();
          await repository.requestStartupDeletionReconciliation();
        } catch (error, stack) {
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Initial library scan failed: $error')),
              );
            });
          }
          // Existing Isar data remains usable; the repository's durable crash
          // marker/baseline state ensures a later retry cannot falsely claim
          // deletion convergence.
        }
      }());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _startupError = 'Could not start the music library: $e';
        _ready = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_startupError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                Text(_startupError!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _bootstrap,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_permissionDenied) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Audio permission is required to scan and play your local music.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _bootstrap,
                  child: const Text('Try again'),
                ),
                if (_permissionPermanentlyDenied) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: openAppSettings,
                    child: const Text('Open app settings'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return const LibraryScreen();
  }
}

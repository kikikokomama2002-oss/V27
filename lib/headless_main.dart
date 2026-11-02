import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers.dart';
import 'playback/playback_controller.dart';
import 'package:flutter/services.dart';

/// Retain the Riverpod container for the lifetime of this headless isolate.
ProviderContainer? _headlessContainer;

/// Headless Dart entry point used by the Android playback service when the
/// foreground Flutter engine is detached. It recreates the same query-backed
/// queue provider against the persisted Isar database, without mounting UI.
@pragma('vm:entry-point')
Future<void> headlessMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();
  _headlessContainer = container;

  // Wait for Isar and the repository before creating the controller.
  await container.read(isarProvider.future);
  container.read(libraryRepositoryProvider);

  final controller =
      container.read(playbackControllerProvider.notifier);

  // Signal Android only after the initial queue restore attempt completes.
  await controller.initialQueueRestoreCompleted;

  await const MethodChannel('com.example.musicplayer/player')
      .invokeMethod<void>('headlessReady');
}

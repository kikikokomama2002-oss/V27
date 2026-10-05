import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers.dart';
import 'playback/playback_controller.dart';
import 'package:flutter/services.dart';

/// Headless Dart entry point used by the Android playback service when the
/// foreground Flutter engine is detached. It recreates the same query-backed
/// queue provider against the persisted Isar database, without mounting UI.
@pragma('vm:entry-point')
Future<void> headlessMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  // Keep the container alive for the lifetime of the headless engine. The
  // PlaybackController installs the native-call handler and restores the
  // persisted logical queue descriptor once Isar is available.
  unawaited(container.read(isarProvider.future));
  container.read(playbackControllerProvider);
  const MethodChannel('com.example.musicplayer/player').invokeMethod('headlessReady');
}

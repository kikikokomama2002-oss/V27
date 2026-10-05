import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

class AudioPermissionResult {
  const AudioPermissionResult({
    required this.granted,
    required this.permanentlyDenied,
  });

  final bool granted;
  final bool permanentlyDenied;
}

/// Requests the correct storage/media permission depending on Android
/// version: READ_MEDIA_AUDIO on API 33+, READ_EXTERNAL_STORAGE below it.
class PermissionsHelper {
  static Future<AudioPermissionResult> requestAudioPermission() async {
    if (!Platform.isAndroid) {
      return const AudioPermissionResult(granted: true, permanentlyDenied: false);
    }

    final audioStatus = await Permission.audio.status;
    if (audioStatus.isGranted) {
      return const AudioPermissionResult(granted: true, permanentlyDenied: false);
    }

    final audioResult = await Permission.audio.request();
    if (audioResult.isGranted) {
      return const AudioPermissionResult(granted: true, permanentlyDenied: false);
    }

    // Pre-Android 13 fallback. `Permission.audio` is not meaningful on
    // older Android versions, so a permanent result from that permission
    // alone must not prevent the legacy storage permission from succeeding.
    final storageStatus = await Permission.storage.status;
    if (storageStatus.isGranted) {
      return const AudioPermissionResult(granted: true, permanentlyDenied: false);
    }
    if (storageStatus.isPermanentlyDenied) {
      return const AudioPermissionResult(granted: false, permanentlyDenied: true);
    }

    final storageResult = await Permission.storage.request();
    return AudioPermissionResult(
      granted: storageResult.isGranted,
      permanentlyDenied:
          storageResult.isPermanentlyDenied || audioResult.isPermanentlyDenied,
    );
  }

  /// Requests POST_NOTIFICATIONS on Android 13+ and is a no-op on older
  /// Android releases where notification permission is granted by the
  /// platform/app configuration. A permanently denied notification permission
  /// is intentionally not treated as an audio-library blocker.
  static Future<PermissionStatus> requestNotificationPermission() async {
    if (!Platform.isAndroid) return PermissionStatus.granted;
    final status = await Permission.notification.status;
    if (status.isGranted) return status;
    return Permission.notification.request();
  }
}

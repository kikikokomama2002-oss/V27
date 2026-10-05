import 'package:equatable/equatable.dart';

/// Snapshot of native playback state, mirrored from the Kotlin
/// PlayerEventChannel every ~500ms and on every player event.
class PlaybackState extends Equatable {
  const PlaybackState({
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.currentTrackId,
    this.currentTrackVolume,
  });

  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final int? currentTrackId;
  final String? currentTrackVolume;

  factory PlaybackState.fromMap(Map<dynamic, dynamic> map) {
    int nonNegativeInt(dynamic raw, String field) {
      if (raw == null) return 0;
      if (raw is! num) throw FormatException('$field must be numeric');
      if (raw is double && !raw.isFinite) throw FormatException('$field must be finite');
      final value = raw.toInt();
      return value < 0 ? 0 : value;
    }

    final rawTrackId = map['currentTrackId'];
    int? trackId;
    if (rawTrackId != null) {
      if (rawTrackId is! num || (rawTrackId is double && !rawTrackId.isFinite)) {
        throw FormatException('currentTrackId must be numeric');
      }
      final value = rawTrackId.toInt();
      trackId = value > 0 ? value : null;
    }

    final rawPlaying = map['isPlaying'];
    return PlaybackState(
      isPlaying: rawPlaying is bool ? rawPlaying : false,
      position: Duration(milliseconds: nonNegativeInt(map['positionMs'], 'positionMs')),
      duration: Duration(milliseconds: nonNegativeInt(map['durationMs'], 'durationMs')),
      currentTrackId: trackId,
      currentTrackVolume: map['currentTrackVolume'] is String
          ? map['currentTrackVolume'] as String
          : null,
    );
  }

  PlaybackState copyWith({
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    int? currentTrackId,
    String? currentTrackVolume,
  }) {
    return PlaybackState(
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      currentTrackId: currentTrackId ?? this.currentTrackId,
      currentTrackVolume: currentTrackVolume ?? this.currentTrackVolume,
    );
  }

  @override
  List<Object?> get props => [isPlaying, position, duration, currentTrackId, currentTrackVolume];
}

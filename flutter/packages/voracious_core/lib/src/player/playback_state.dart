/// The observable state of the playback engine.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'media_track.dart';

enum PlaybackStatus {
  /// Nothing loaded.
  idle,

  /// A file is opening.
  loading,

  /// Loaded, playing, but waiting on data.
  buffering,

  playing,
  paused,

  /// Reached the end of the file.
  ended,

  /// Failed; see [PlaybackState.errorMessage].
  error,
}

/// An immutable snapshot of what the engine is doing.
@immutable
class PlaybackState {
  const PlaybackState({
    this.status = PlaybackStatus.idle,
    this.mediaUrl,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.speed = 1,
    this.volume = 1,
    this.isMuted = false,
    this.isSeeking = false,
    this.tracks = const [],
    this.activeAudioTrackId,
    this.activeSubtitleTrackId,
    this.subtitleDelay = Duration.zero,
    this.audioDelay = Duration.zero,
    this.videoWidth,
    this.videoHeight,
    this.isHardwareDecoding,
    this.errorMessage,
  });

  static const PlaybackState initial = PlaybackState();

  final PlaybackStatus status;

  /// What is loaded, as handed to the engine.
  final String? mediaUrl;

  final Duration position;
  final Duration duration;

  /// Playback rate; 1.0 is normal.
  final double speed;

  /// 0.0 to 1.0.
  final double volume;
  final bool isMuted;

  /// True between a seek being requested and the engine settling. Study-mode
  /// auto-pause has to stand down while this is set, or seeking would trip it.
  final bool isSeeking;

  final List<MediaTrack> tracks;

  final int? activeAudioTrackId;
  final int? activeSubtitleTrackId;

  /// Engine-side subtitle timing offset, for embedded tracks.
  final Duration subtitleDelay;
  final Duration audioDelay;

  final int? videoWidth;
  final int? videoHeight;

  /// Whether the engine settled on a hardware decoder. Worth surfacing: on a
  /// cheap TV box, software decode of 4K HEVC is the difference between smooth
  /// playback and a slideshow.
  final bool? isHardwareDecoding;

  final String? errorMessage;

  bool get isPlaying => status == PlaybackStatus.playing;
  bool get isPaused => status == PlaybackStatus.paused;
  bool get hasMedia =>
      status != PlaybackStatus.idle && status != PlaybackStatus.error;

  List<MediaTrack> get audioTracks =>
      tracks.where((t) => t.kind == MediaTrackKind.audio).toList();

  List<MediaTrack> get subtitleTracks =>
      tracks.where((t) => t.kind == MediaTrackKind.subtitle).toList();

  List<MediaTrack> get videoTracks =>
      tracks.where((t) => t.kind == MediaTrackKind.video).toList();

  /// Fraction of the file played, in `[0, 1]`.
  double get progress => duration.inMilliseconds == 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  PlaybackState copyWith({
    PlaybackStatus? status,
    String? mediaUrl,
    Duration? position,
    Duration? duration,
    double? speed,
    double? volume,
    bool? isMuted,
    bool? isSeeking,
    List<MediaTrack>? tracks,
    int? activeAudioTrackId,
    int? activeSubtitleTrackId,
    Duration? subtitleDelay,
    Duration? audioDelay,
    int? videoWidth,
    int? videoHeight,
    bool? isHardwareDecoding,
    String? errorMessage,
    bool clearError = false,
    bool clearActiveSubtitleTrack = false,
  }) =>
      PlaybackState(
        status: status ?? this.status,
        mediaUrl: mediaUrl ?? this.mediaUrl,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        speed: speed ?? this.speed,
        volume: volume ?? this.volume,
        isMuted: isMuted ?? this.isMuted,
        isSeeking: isSeeking ?? this.isSeeking,
        tracks: tracks ?? this.tracks,
        activeAudioTrackId: activeAudioTrackId ?? this.activeAudioTrackId,
        activeSubtitleTrackId: clearActiveSubtitleTrack
            ? null
            : (activeSubtitleTrackId ?? this.activeSubtitleTrackId),
        subtitleDelay: subtitleDelay ?? this.subtitleDelay,
        audioDelay: audioDelay ?? this.audioDelay,
        videoWidth: videoWidth ?? this.videoWidth,
        videoHeight: videoHeight ?? this.videoHeight,
        isHardwareDecoding: isHardwareDecoding ?? this.isHardwareDecoding,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      );

  @override
  bool operator ==(Object other) =>
      other is PlaybackState &&
      other.status == status &&
      other.mediaUrl == mediaUrl &&
      other.position == position &&
      other.duration == duration &&
      other.speed == speed &&
      other.volume == volume &&
      other.isMuted == isMuted &&
      other.isSeeking == isSeeking &&
      other.activeAudioTrackId == activeAudioTrackId &&
      other.activeSubtitleTrackId == activeSubtitleTrackId &&
      other.subtitleDelay == subtitleDelay &&
      other.audioDelay == audioDelay &&
      other.videoWidth == videoWidth &&
      other.videoHeight == videoHeight &&
      other.isHardwareDecoding == isHardwareDecoding &&
      other.errorMessage == errorMessage &&
      const ListEquality<MediaTrack>().equals(other.tracks, tracks);

  @override
  int get hashCode => Object.hash(
        status,
        mediaUrl,
        position,
        duration,
        speed,
        volume,
        isMuted,
        isSeeking,
        activeAudioTrackId,
        activeSubtitleTrackId,
        subtitleDelay,
        audioDelay,
        videoWidth,
        videoHeight,
        isHardwareDecoding,
        errorMessage,
      );

  @override
  String toString() => 'PlaybackState($status, ${position.inMilliseconds}ms'
      '/${duration.inMilliseconds}ms)';
}

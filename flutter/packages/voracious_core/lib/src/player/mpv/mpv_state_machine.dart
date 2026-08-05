/// Folds mpv events and property changes into a [PlaybackState].
///
/// mpv reports playback status as several independent flags — `pause`,
/// `paused-for-cache`, `eof-reached`, `idle-active`, `seeking` — and the useful
/// status is a function of all of them. Deriving it in one place, from data,
/// means the awkward combinations (paused while buffering; eof reached but the
/// file still loaded) can be tested without an engine.
library;

import 'package:meta/meta.dart';

import '../media_track.dart';
import '../playback_state.dart';
import 'mpv_protocol.dart';
import 'mpv_track_list.dart';

/// The event kinds libmpv delivers that this layer acts on.
enum MpvEventKind {
  startFile,
  endFile,
  fileLoaded,
  seek,
  playbackRestart,
  idle,
  shutdown,
  propertyChange,
}

/// Why a file ended, mirroring `mpv_end_file_reason`.
enum MpvEndFileReason { eof, stop, quit, error, redirect, unknown }

/// One event from the engine.
@immutable
class MpvEvent {
  const MpvEvent({
    required this.kind,
    this.propertyName,
    this.propertyValue,
    this.endFileReason,
    this.errorCode,
    this.errorMessage,
  });

  final MpvEventKind kind;

  final String? propertyName;
  final Object? propertyValue;

  final MpvEndFileReason? endFileReason;
  final int? errorCode;
  final String? errorMessage;

  factory MpvEvent.property(String name, Object? value) => MpvEvent(
        kind: MpvEventKind.propertyChange,
        propertyName: name,
        propertyValue: value,
      );

  @override
  String toString() => kind == MpvEventKind.propertyChange
      ? 'MpvEvent(property $propertyName = $propertyValue)'
      : 'MpvEvent($kind)';
}

/// Accumulates engine events into a [PlaybackState].
class MpvStateMachine {
  MpvStateMachine({PlaybackState initial = PlaybackState.initial})
      : _state = initial;

  PlaybackState _state;

  // Raw mpv flags. Status is derived from these rather than stored, because
  // they change independently and in any order.
  bool _paused = true;
  bool _pausedForCache = false;
  bool _eofReached = false;
  bool _idleActive = true;
  bool _seeking = false;
  bool _fileLoaded = false;
  bool _loading = false;
  String? _errorMessage;

  PlaybackState get state => _state;

  /// Applies [event], returning the new state.
  PlaybackState apply(MpvEvent event) {
    switch (event.kind) {
      case MpvEventKind.startFile:
        _loading = true;
        _fileLoaded = false;
        _eofReached = false;
        _errorMessage = null;
        _state = _state.copyWith(clearError: true);

      case MpvEventKind.fileLoaded:
        _loading = false;
        _fileLoaded = true;
        _idleActive = false;

      case MpvEventKind.endFile:
        _loading = false;
        _fileLoaded = false;
        if (event.endFileReason == MpvEndFileReason.error) {
          _errorMessage = event.errorMessage ?? 'playback failed';
          _state = _state.copyWith(errorMessage: _errorMessage);
        } else if (event.endFileReason == MpvEndFileReason.eof) {
          _eofReached = true;
        }

      case MpvEventKind.seek:
        _seeking = true;

      case MpvEventKind.playbackRestart:
        // Emitted once a seek has completed and output has resumed.
        _seeking = false;

      case MpvEventKind.idle:
        _idleActive = true;
        _fileLoaded = false;
        _loading = false;

      case MpvEventKind.shutdown:
        _state = _state.copyWith(status: PlaybackStatus.idle);
        return _state;

      case MpvEventKind.propertyChange:
        _applyProperty(event.propertyName!, event.propertyValue);
    }

    _state = _state.copyWith(
      status: _deriveStatus(),
      isSeeking: _seeking,
    );
    return _state;
  }

  /// Convenience for property changes.
  PlaybackState applyProperty(String name, Object? value) =>
      apply(MpvEvent.property(name, value));

  void _applyProperty(String name, Object? value) {
    switch (name) {
      case MpvProperty.pause:
        _paused = parseMpvFlag(value) ?? _paused;

      case MpvProperty.pausedForCache:
        _pausedForCache = parseMpvFlag(value) ?? false;

      case MpvProperty.eofReached:
        _eofReached = parseMpvFlag(value) ?? false;

      case MpvProperty.idleActive:
        _idleActive = parseMpvFlag(value) ?? _idleActive;

      case MpvProperty.seeking:
        _seeking = parseMpvFlag(value) ?? false;

      case MpvProperty.timePos:
        final position = parseMpvSeconds(value);
        // mpv sets time-pos to null between files; keeping the last position
        // avoids the progress bar snapping to zero mid-transition.
        if (position != null) _state = _state.copyWith(position: position);

      case MpvProperty.duration:
        final duration = parseMpvSeconds(value);
        if (duration != null) _state = _state.copyWith(duration: duration);

      case MpvProperty.speed:
        final speed = parseMpvNumber(value);
        if (speed != null && speed > 0) _state = _state.copyWith(speed: speed);

      case MpvProperty.volume:
        // mpv volume is a percentage; the rest of the app uses 0..1.
        final volume = parseMpvNumber(value);
        if (volume != null) {
          _state = _state.copyWith(volume: (volume / 100).clamp(0.0, 1.0));
        }

      case MpvProperty.mute:
        final muted = parseMpvFlag(value);
        if (muted != null) _state = _state.copyWith(isMuted: muted);

      case MpvProperty.path:
        _state = _state.copyWith(mediaUrl: value as String?);

      case MpvProperty.trackList:
        if (value is String) {
          final tracks = parseMpvTrackList(value);
          _state = _state.copyWith(
            tracks: tracks,
            activeAudioTrackId: selectedTrackId(value, MediaTrackKind.audio),
            activeSubtitleTrackId:
                selectedTrackId(value, MediaTrackKind.subtitle),
          );
        }

      case MpvProperty.audioId:
        final id = _parseTrackId(value);
        _state = _state.copyWith(activeAudioTrackId: id);

      case MpvProperty.subtitleId:
        final id = _parseTrackId(value);
        _state = id == null
            ? _state.copyWith(clearActiveSubtitleTrack: true)
            : _state.copyWith(activeSubtitleTrackId: id);

      case MpvProperty.subDelay:
        final delay = parseMpvSeconds(value);
        if (delay != null) _state = _state.copyWith(subtitleDelay: delay);

      case MpvProperty.audioDelay:
        final delay = parseMpvSeconds(value);
        if (delay != null) _state = _state.copyWith(audioDelay: delay);

      case MpvProperty.width:
        final width = parseMpvNumber(value);
        if (width != null) _state = _state.copyWith(videoWidth: width.round());

      case MpvProperty.height:
        final height = parseMpvNumber(value);
        if (height != null) {
          _state = _state.copyWith(videoHeight: height.round());
        }

      case MpvProperty.hwdecCurrent:
        // mpv reports the decoder actually in use, which is the only reliable
        // way to know whether the hardware path was taken: requesting it does
        // not guarantee getting it.
        final hwdec = value is String ? value : null;
        _state = _state.copyWith(
          isHardwareDecoding:
              hwdec != null && hwdec != 'no' && hwdec.isNotEmpty,
        );
    }
  }

  /// `aid`/`sid` are a track number, or `"no"`/`false` when nothing is
  /// selected.
  static int? _parseTrackId(Object? value) => switch (value) {
        final num n => n.toInt(),
        final String s => int.tryParse(s),
        _ => null,
      };

  PlaybackStatus _deriveStatus() {
    if (_errorMessage != null) return PlaybackStatus.error;
    if (_loading) return PlaybackStatus.loading;
    if (_idleActive && !_fileLoaded) return PlaybackStatus.idle;
    // eof-reached stays set while the file is still loaded with keep-open,
    // which is how the app knows to offer the next episode.
    if (_eofReached) return PlaybackStatus.ended;
    if (_pausedForCache) return PlaybackStatus.buffering;
    return _paused ? PlaybackStatus.paused : PlaybackStatus.playing;
  }
}

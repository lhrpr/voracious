/// The mpv client protocol expressed as data.
///
/// libmpv is driven by string commands and named properties. Building those
/// strings is easy to get subtly wrong — a seek with the wrong flags becomes a
/// keyframe seek, a property name typo silently observes nothing — and none of
/// it needs a running engine to verify, so it lives here rather than in the
/// FFI package.
library;

import 'package:meta/meta.dart';

/// Property names mpv exposes, as constants rather than scattered literals.
abstract final class MpvProperty {
  static const String pausedForCache = 'paused-for-cache';
  static const String pause = 'pause';
  static const String timePos = 'time-pos';
  static const String duration = 'duration';
  static const String speed = 'speed';
  static const String volume = 'volume';
  static const String mute = 'mute';
  static const String eofReached = 'eof-reached';
  static const String seeking = 'seeking';
  static const String idleActive = 'idle-active';
  static const String path = 'path';
  static const String trackList = 'track-list';
  static const String audioId = 'aid';
  static const String subtitleId = 'sid';
  static const String subDelay = 'sub-delay';
  static const String audioDelay = 'audio-delay';
  static const String width = 'width';
  static const String height = 'height';
  static const String hwdecCurrent = 'hwdec-current';
  static const String demuxerCacheTime = 'demuxer-cache-time';

  /// Properties worth observing for the whole life of the player.
  ///
  /// Position updates arrive on every frame at 60 Hz, which is more than the
  /// UI needs but exactly what listening-mode auto-pause needs to land within
  /// a frame of the right moment.
  static const List<String> observed = [
    pause,
    pausedForCache,
    timePos,
    duration,
    speed,
    volume,
    mute,
    eofReached,
    seeking,
    idleActive,
    path,
    trackList,
    audioId,
    subtitleId,
    subDelay,
    audioDelay,
    width,
    height,
    hwdecCurrent,
  ];
}

/// A command to send with `mpv_command`.
@immutable
class MpvCommand {
  const MpvCommand(this.arguments);

  /// Argument vector, first element being the command name.
  final List<String> arguments;

  String get name => arguments.first;

  /// Loads [url].
  ///
  /// [startAt] is passed as a per-file option rather than as a seek after
  /// loading, so resuming a video does not show its first frame before
  /// jumping.
  factory MpvCommand.loadFile(
    String url, {
    Duration startAt = Duration.zero,
    bool paused = false,
  }) {
    final options = <String>[
      if (startAt > Duration.zero) 'start=${_formatSeconds(startAt)}',
      if (paused) 'pause=yes',
    ];
    return MpvCommand([
      'loadfile',
      url,
      'replace',
      '0',
      if (options.isNotEmpty) options.join(','),
    ]);
  }

  factory MpvCommand.stop() => const MpvCommand(['stop']);

  /// Seeks to an absolute [position].
  ///
  /// Always `exact`: study navigation targets subtitle timestamps, and the
  /// default keyframe seek would miss the start of a line by whatever the
  /// GOP length happens to be.
  factory MpvCommand.seekAbsolute(Duration position) => MpvCommand([
        'seek',
        _formatSeconds(position.isNegative ? Duration.zero : position),
        'absolute+exact',
      ]);

  factory MpvCommand.seekRelative(Duration offset) => MpvCommand([
        'seek',
        _formatSeconds(offset),
        'relative+exact',
      ]);

  factory MpvCommand.setProperty(String name, String value) =>
      MpvCommand(['set', name, value]);

  factory MpvCommand.cycleProperty(String name) => MpvCommand(['cycle', name]);

  /// Adds an external subtitle file.
  ///
  /// `select` displays it immediately; `auto` adds it without selecting, which
  /// is what Voracious wants when it is rendering the text itself.
  factory MpvCommand.addSubtitle(String path, {bool select = false}) =>
      MpvCommand(['sub-add', path, select ? 'select' : 'auto']);

  factory MpvCommand.removeSubtitle(int id) =>
      MpvCommand(['sub-remove', '$id']);

  /// Captures a frame into memory. `video` excludes subtitles and OSD, which
  /// is right for an Anki card: the subtitle goes in its own field.
  factory MpvCommand.screenshotRaw() =>
      const MpvCommand(['screenshot-raw', 'video']);

  factory MpvCommand.quit() => const MpvCommand(['quit']);

  @override
  bool operator ==(Object other) =>
      other is MpvCommand &&
      other.arguments.length == arguments.length &&
      _listEquals(other.arguments, arguments);

  @override
  int get hashCode => Object.hashAll(arguments);

  @override
  String toString() => 'MpvCommand(${arguments.join(' ')})';
}

bool _listEquals(List<String> a, List<String> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Formats a duration the way mpv parses times: seconds with millisecond
/// precision, no locale involvement.
String _formatSeconds(Duration duration) =>
    (duration.inMicroseconds / Duration.microsecondsPerSecond)
        .toStringAsFixed(3);

/// Public alias, used by the FFI layer and tests.
String formatMpvSeconds(Duration duration) => _formatSeconds(duration);

/// Parses a duration from an mpv numeric property, tolerating null and NaN,
/// both of which mpv reports for a property that is not currently meaningful.
Duration? parseMpvSeconds(Object? value) {
  final seconds = switch (value) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s),
    _ => null,
  };
  if (seconds == null || seconds.isNaN || seconds.isInfinite) return null;
  return Duration(
      microseconds: (seconds * Duration.microsecondsPerSecond).round());
}

/// Parses an mpv flag property, which arrives as a bool, `"yes"`/`"no"` or 0/1
/// depending on which API the value came through.
bool? parseMpvFlag(Object? value) => switch (value) {
      final bool b => b,
      final num n => n != 0,
      'yes' || 'true' || '1' => true,
      'no' || 'false' || '0' => false,
      _ => null,
    };

/// Parses an mpv numeric property.
double? parseMpvNumber(Object? value) {
  final result = switch (value) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s),
    _ => null,
  };
  if (result == null || result.isNaN || result.isInfinite) return null;
  return result;
}

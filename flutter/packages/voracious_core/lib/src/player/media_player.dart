/// The playback engine contract.
///
/// Everything above this line — study modes, the library, Anki export — is
/// written against this interface and against nothing else, which is what
/// allows the engine underneath to be an LGPL build of libmpv on desktop and
/// Android, and something else entirely on a platform that will not run native
/// code (Tizen, webOS) without any of that logic being rewritten.
library;

import 'dart:typed_data';

import 'playback_state.dart';

/// A playback engine.
abstract interface class MediaPlayer {
  /// The current state, always available synchronously.
  PlaybackState get state;

  /// State changes. Broadcast: several widgets and the study session all
  /// listen.
  Stream<PlaybackState> get states;

  /// Loads [url] and, if [startAt] is given, resumes from that position.
  ///
  /// [startAt] is applied before the first frame is shown, so resuming does
  /// not flash the opening frame.
  Future<void> open(String url, {Duration startAt = Duration.zero});

  /// Unloads the current file.
  Future<void> close();

  Future<void> play();
  Future<void> pause();
  Future<void> togglePause();

  Future<void> seek(Duration position);

  /// Seeks relative to the current position, clamped to the file.
  Future<void> seekBy(Duration offset);

  /// Sets playback rate. Values below 1 are the ones that matter here: slowing
  /// dialogue down is a study aid, and the engine is expected to keep pitch.
  Future<void> setSpeed(double speed);

  Future<void> setVolume(double volume);
  Future<void> setMuted(bool muted);

  /// Selects an embedded audio track by [MediaTrack.id], or null for none.
  Future<void> setAudioTrack(int? trackId);

  /// Selects an embedded subtitle track, or null to turn engine subtitles off.
  ///
  /// Voracious normally renders its own analysed subtitles and leaves this
  /// null; it is here for image-based tracks, which only the engine can draw.
  Future<void> setSubtitleTrack(int? trackId);

  /// Loads an external subtitle file into the engine for display.
  Future<void> addExternalSubtitle(String path, {bool select = false});

  /// Shifts engine subtitle timing.
  Future<void> setSubtitleDelay(Duration delay);

  Future<void> setAudioDelay(Duration delay);

  /// Captures the current frame as encoded image bytes, for Anki cards.
  ///
  /// The frame comes back at the video's own resolution — engines do not scale
  /// screenshots — so a caller that wants a card-sized image scales it itself.
  Future<Uint8List> captureFrame();

  /// Releases engine resources. The instance is unusable afterwards.
  Future<void> dispose();
}

/// Extracts an audio clip from a media file.
///
/// Separate from [MediaPlayer] on purpose. Playback engines decode audio for
/// output, not for export; producing an MP3 of one subtitle line means running
/// an encoder, and which encoder is available is a per-platform packaging
/// decision. Keeping it behind its own interface also keeps the encoder out of
/// the playback path, where an LGPL build must not grow a GPL-only component.
abstract interface class AudioClipExtractor {
  /// Extracts audio from [mediaPath] between [begin] and [end].
  ///
  /// Returns encoded audio bytes; [format] names the container the caller
  /// wants (`mp3`, `m4a`, `opus`) and implementations may fall back to what
  /// they have.
  Future<Uint8List> extractClip(
    String mediaPath, {
    required Duration begin,
    required Duration end,
    String format = 'mp3',
  });

  /// Formats this extractor can produce.
  Set<String> get supportedFormats;
}

/// Thrown when the engine fails.
class MediaPlayerException implements Exception {
  const MediaPlayerException(this.message, {this.code});

  final String message;

  /// Engine-specific error code, when there is one.
  final int? code;

  @override
  String toString() =>
      'MediaPlayerException: $message${code != null ? ' (code $code)' : ''}';
}

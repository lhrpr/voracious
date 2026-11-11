/// voracious_core's [MediaPlayer], backed by media_kit.
///
/// media_kit bundles a stock libmpv for every desktop and mobile platform and
/// draws hardware-decoded frames into a Flutter texture, which replaces the
/// hand-built FFI bindings and per-platform video bridge this app used to
/// carry. Those existed to keep a shipped build LGPL-clean; Voracious is now
/// personal and open source, so the stock GPL build is fine.
///
/// mpv never draws subtitles here. Voracious renders its own analysed tracks
/// (several at once, word by word), so engine subtitles stay off unless a
/// caller asks for an image-based track with [setSubtitleTrack].
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart' as mk;
import 'package:voracious_core/voracious_core.dart';

import 'frame_capture.dart';

class MediaKitPlayer implements MediaPlayer {
  MediaKitPlayer._(this.player) {
    _subscriptions.addAll([
      player.stream.playing.listen((_) => _emit()),
      player.stream.completed.listen((_) => _emit()),
      player.stream.buffering.listen((_) => _emit()),
      player.stream.position.listen(_onPosition),
      player.stream.duration.listen((value) => _emit(duration: value)),
      player.stream.rate.listen((_) => _emit()),
      player.stream.volume.listen((_) => _emit()),
      player.stream.tracks.listen((_) => _emit()),
      player.stream.track.listen((_) => _emit()),
      player.stream.width.listen((_) => _emit()),
      player.stream.height.listen((_) => _emit()),
      player.stream.error.listen((message) {
        _errorMessage = message;
        _emit();
      }),
    ]);
  }

  /// Starts an engine configured for study playback.
  static Future<MediaKitPlayer> create() async {
    final player = mk.Player(
      configuration: const mk.PlayerConfiguration(
        title: 'Voracious',
        // Engine subtitles off from the start; see the library comment.
        libass: false,
      ),
    );
    final native = player.platform;
    if (native is mk.NativePlayer) {
      // Every option here is plain mpv; media_kit just passes it through.
      await native.setProperty('sid', 'no');
      await native.setProperty('sub-auto', 'no');
      // Keep pitch when slowing dialogue down.
      await native.setProperty('audio-pitch-correction', 'yes');
      // Precise seeks: a study app jumps to cue starts, not to keyframes.
      await native.setProperty('hr-seek', 'yes');
    }
    return MediaKitPlayer._(player);
  }

  /// The underlying media_kit player, for the video widget.
  final mk.Player player;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();

  PlaybackState _state = PlaybackState.initial;
  String? _mediaUrl;
  String? _errorMessage;
  bool _muted = false;

  /// Set between a seek request and the first position report after it.
  /// media_kit has no seeking stream, and this is what StudySession needs:
  /// auto-pause stands down from the request until the playhead has moved.
  bool _seeking = false;

  bool _disposed = false;

  String get engineDescription => 'libmpv via media_kit';

  @override
  PlaybackState get state => _state;

  @override
  Stream<PlaybackState> get states => _states.stream;

  void _onPosition(Duration position) {
    _seeking = false;
    _emit(position: position);
  }

  void _emit({Duration? position, Duration? duration}) {
    if (_disposed) return;
    final s = player.state;
    _state = PlaybackState(
      status: _statusFrom(s),
      mediaUrl: _mediaUrl,
      position: position ?? s.position,
      duration: duration ?? s.duration,
      speed: s.rate,
      volume: (s.volume / 100).clamp(0.0, 1.0),
      isMuted: _muted,
      isSeeking: _seeking,
      tracks: _tracksFrom(s.tracks),
      activeAudioTrackId: int.tryParse(s.track.audio.id),
      activeSubtitleTrackId: int.tryParse(s.track.subtitle.id),
      videoWidth: s.width,
      videoHeight: s.height,
      errorMessage: _errorMessage,
    );
    _states.add(_state);
  }

  PlaybackStatus _statusFrom(mk.PlayerState s) {
    if (_errorMessage != null) return PlaybackStatus.error;
    if (_mediaUrl == null) return PlaybackStatus.idle;
    if (s.completed) return PlaybackStatus.ended;
    if (s.duration == Duration.zero) return PlaybackStatus.loading;
    if (s.buffering && s.playing) return PlaybackStatus.buffering;
    return s.playing ? PlaybackStatus.playing : PlaybackStatus.paused;
  }

  /// media_kit lists "auto" and "no" pseudo-tracks alongside the real ones;
  /// only numeric ids are tracks in the file.
  List<MediaTrack> _tracksFrom(mk.Tracks tracks) => [
        for (final t in tracks.video)
          if (int.tryParse(t.id) case final id?)
            MediaTrack(
              id: id,
              kind: MediaTrackKind.video,
              title: t.title,
              codec: t.codec,
              width: t.w,
              height: t.h,
            ),
        for (final t in tracks.audio)
          if (int.tryParse(t.id) case final id?)
            MediaTrack(
              id: id,
              kind: MediaTrackKind.audio,
              title: t.title,
              languageCode: _normaliseLanguage(t.language),
              codec: t.codec,
              channelCount: t.channelscount,
            ),
        for (final t in tracks.subtitle)
          if (int.tryParse(t.id) case final id?)
            MediaTrack(
              id: id,
              kind: MediaTrackKind.subtitle,
              title: t.title,
              languageCode: _normaliseLanguage(t.language),
              codec: t.codec,
              isDefault: t.isDefault ?? false,
              // media_kit doesn't surface mpv's forced flag; titles usually say it.
              isForced: (t.title ?? '').toLowerCase().contains('forced'),
              isImageBased: _imageCodecs.contains(t.codec),
            ),
      ];

  static const _imageCodecs = {
    'hdmv_pgs_subtitle',
    'dvd_subtitle',
    'dvb_subtitle',
    'xsub',
  };

  static String? _normaliseLanguage(String? tag) =>
      tag == null || tag.isEmpty ? null : toIso6393(tag) ?? tag;

  @override
  Future<void> open(String url, {Duration startAt = Duration.zero}) async {
    _mediaUrl = url;
    _errorMessage = null;
    _emit();
    await player.open(mk.Media(url, start: startAt));
  }

  @override
  Future<void> close() async {
    await player.stop();
    _mediaUrl = null;
    _emit();
  }

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> togglePause() => player.playOrPause();

  @override
  Future<void> seek(Duration position) async {
    _seeking = true;
    _emit();
    await player.seek(position);
  }

  @override
  Future<void> seekBy(Duration offset) {
    final target = _state.position + offset;
    final end = _state.duration;
    return seek(
      target < Duration.zero
          ? Duration.zero
          : (end > Duration.zero && target > end ? end : target),
    );
  }

  @override
  Future<void> setSpeed(double speed) => player.setRate(speed);

  /// The current frame as a card-sized JPEG, or null when there's no picture
  /// to take (audio only, or the engine couldn't produce one).
  Future<Uint8List?> capturePicture() async {
    final Uint8List full;
    try {
      full = await captureFrame();
    } on Object {
      return null;
    }
    return full.isEmpty ? null : shrinkFrame(full);
  }

  @override
  Future<void> setVolume(double volume) =>
      player.setVolume((volume * 100).clamp(0, 100).toDouble());

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    await _setProperty('mute', muted ? 'yes' : 'no');
    _emit();
  }

  @override
  Future<void> setAudioTrack(int? trackId) => trackId == null
      ? player.setAudioTrack(mk.AudioTrack.no())
      : _setProperty('aid', '$trackId');

  @override
  Future<void> setSubtitleTrack(int? trackId) =>
      _setProperty('sid', trackId == null ? 'no' : '$trackId');

  @override
  Future<void> addExternalSubtitle(String path, {bool select = false}) =>
      _command(['sub-add', path, select ? 'select' : 'auto']);

  @override
  Future<void> setSubtitleDelay(Duration delay) =>
      _setProperty('sub-delay', '${delay.inMicroseconds / 1e6}');

  @override
  Future<void> setAudioDelay(Duration delay) =>
      _setProperty('audio-delay', '${delay.inMicroseconds / 1e6}');

  @override
  Future<Uint8List> captureFrame() async {
    // JPEG: media_kit encodes in Dart, and PNG at full resolution is slow.
    final bytes = await player.screenshot(format: 'image/jpeg');
    if (bytes == null) {
      throw StateError('no frame to capture');
    }
    return bytes;
  }

  Future<void> _setProperty(String name, String value) async {
    final native = player.platform;
    if (native is mk.NativePlayer) await native.setProperty(name, value);
  }

  Future<void> _command(List<String> args) async {
    final native = player.platform;
    if (native is mk.NativePlayer) await native.command(args);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    await player.dispose();
    await _states.close();
  }
}

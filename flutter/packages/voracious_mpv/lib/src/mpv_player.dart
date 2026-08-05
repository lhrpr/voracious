/// A [MediaPlayer] backed by libmpv.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:voracious_core/voracious_core.dart';

import 'mpv_bindings.dart';
import 'mpv_event_pump.dart';
import 'mpv_library.dart';

/// Controls playback through libmpv.
///
/// This class owns control and state only. Getting decoded frames onto the
/// screen is the render API's job and belongs in the Flutter plugin layer,
/// where the texture lives; keeping the two apart is what lets everything here
/// be exercised without a display.
class MpvPlayer implements MediaPlayer {
  MpvPlayer._(this._library, this._handle);

  final MpvLibrary _library;
  final MpvHandle _handle;

  final MpvStateMachine _machine = MpvStateMachine();
  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();

  MpvEventPump? _pump;
  StreamSubscription<MpvEvent>? _eventSubscription;
  bool _disposed = false;

  /// Creates and initialises an engine.
  ///
  /// [platform] and [tuning] select the option set; see [MpvConfiguration].
  /// [libraryPath] overrides library discovery, which a desktop build that
  /// ships its own libmpv next to the executable will want.
  static Future<MpvPlayer> create({
    required MpvPlatform platform,
    MpvTuning tuning = MpvTuning.desktop,
    String? libraryPath,
    List<MpvOption> extraOptions = const [],
    bool enforceLgplSafety = true,
  }) async {
    final options = [
      ...MpvConfiguration.forPlatform(platform, tuning: tuning),
      ...extraOptions,
    ];

    if (enforceLgplSafety) {
      final violations = validateLgplSafety(options);
      if (violations.isNotEmpty) {
        throw StateError(
          'mpv configuration names components an LGPL build does not have:\n'
          '${violations.map((v) => '  - $v').join('\n')}',
        );
      }
    }

    final library = MpvLibrary.open(explicitPath: libraryPath);
    final bindings = library.bindings;

    final handle = bindings.create();
    if (handle == nullptr) {
      throw const MediaPlayerException('mpv_create returned null');
    }

    // Options must be set before mpv_initialize; several of them cannot be
    // changed afterwards.
    for (final option in options) {
      final name = option.name.toNativeUtf8();
      final value = option.value.toNativeUtf8();
      try {
        final code = bindings.setOptionString(handle, name, value);
        if (code < 0) {
          throw MediaPlayerException(
            'could not set ${option.name}=${option.value}: '
            '${bindings.describeError(code)}',
            code: code,
          );
        }
      } finally {
        calloc
          ..free(name)
          ..free(value);
      }
    }

    final initCode = bindings.initialize(handle);
    if (initCode < 0) {
      bindings.terminateDestroy(handle);
      throw MediaPlayerException(
        'mpv_initialize failed: ${bindings.describeError(initCode)}',
        code: initCode,
      );
    }

    final player = MpvPlayer._(library, handle);
    await player._startObserving();
    return player;
  }

  /// Description of the loaded library, for the about screen. The LGPL notice
  /// has to name the exact library the user is running.
  String get engineDescription => _library.describe();

  @override
  PlaybackState get state => _machine.state;

  @override
  Stream<PlaybackState> get states => _states.stream;

  Future<void> _startObserving() async {
    final bindings = _library.bindings;

    observedProperties.forEach((name, format) {
      final namePointer = name.toNativeUtf8();
      try {
        bindings.observeProperty(_handle, 0, namePointer, format);
      } finally {
        calloc.free(namePointer);
      }
    });

    _pump = await MpvEventPump.start(
      handleAddress: _handle.address,
      libraryPath: _library.path,
    );
    _eventSubscription = _pump!.events.listen((event) {
      final next = _machine.apply(event);
      if (!_states.isClosed) _states.add(next);
    });
  }

  @override
  Future<void> open(String url, {Duration startAt = Duration.zero}) async =>
      _command(MpvCommand.loadFile(url, startAt: startAt));

  @override
  Future<void> close() async => _command(MpvCommand.stop());

  @override
  Future<void> play() async => _setProperty(MpvProperty.pause, 'no');

  @override
  Future<void> pause() async => _setProperty(MpvProperty.pause, 'yes');

  @override
  Future<void> togglePause() async =>
      _command(MpvCommand.cycleProperty(MpvProperty.pause));

  @override
  Future<void> seek(Duration position) async =>
      _command(MpvCommand.seekAbsolute(position));

  @override
  Future<void> seekBy(Duration offset) async =>
      _command(MpvCommand.seekRelative(offset));

  @override
  Future<void> setSpeed(double speed) async {
    if (speed <= 0) {
      throw ArgumentError.value(speed, 'speed', 'must be greater than zero');
    }
    await _setProperty(MpvProperty.speed, speed.toStringAsFixed(3));
  }

  @override
  Future<void> setVolume(double volume) async {
    // mpv works in percent; the rest of the app in 0..1.
    final percent = (volume.clamp(0.0, 1.0) * 100).round();
    await _setProperty(MpvProperty.volume, '$percent');
  }

  @override
  Future<void> setMuted(bool muted) async =>
      _setProperty(MpvProperty.mute, muted ? 'yes' : 'no');

  @override
  Future<void> setAudioTrack(int? trackId) async =>
      _setProperty(MpvProperty.audioId, trackId?.toString() ?? 'no');

  @override
  Future<void> setSubtitleTrack(int? trackId) async =>
      _setProperty(MpvProperty.subtitleId, trackId?.toString() ?? 'no');

  @override
  Future<void> addExternalSubtitle(String path, {bool select = false}) async =>
      _command(MpvCommand.addSubtitle(path, select: select));

  @override
  Future<void> setSubtitleDelay(Duration delay) async =>
      _setProperty(MpvProperty.subDelay, formatMpvSeconds(delay));

  @override
  Future<void> setAudioDelay(Duration delay) async =>
      _setProperty(MpvProperty.audioDelay, formatMpvSeconds(delay));

  /// Captures the current frame.
  ///
  /// Written through a temporary file rather than `screenshot-raw`: the raw
  /// command returns an uncompressed mpv node that would have to be decoded
  /// through FFI and then encoded anyway, and the file path costs one write to
  /// the cache directory.
  @override
  Future<Uint8List> captureFrame() async {
    final directory = await Directory.systemTemp.createTemp('voracious_frame');
    final file = File('${directory.path}/frame.jpg');
    try {
      await _setProperty('screenshot-format', 'jpg');
      await _setProperty('screenshot-jpeg-quality', '90');
      // `video` captures the decoded frame without subtitles or OSD drawn on
      // it, which is what an Anki card wants.
      _command(MpvCommand(['screenshot-to-file', file.path, 'video']));

      // The command is asynchronous inside mpv; wait briefly for the file.
      for (var attempt = 0; attempt < 50; attempt++) {
        if (await file.exists() && await file.length() > 0) {
          return await file.readAsBytes();
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      throw const MediaPlayerException('screenshot timed out');
    } finally {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await _eventSubscription?.cancel();
    _pump?.stop();
    await _states.close();

    _library.bindings.terminateDestroy(_handle);
  }

  void _command(MpvCommand command) {
    _checkAlive();
    final bindings = _library.bindings;

    // mpv_command takes a NULL-terminated argv.
    final argv = calloc<Pointer<Utf8>>(command.arguments.length + 1);
    final allocated = <Pointer<Utf8>>[];
    try {
      for (var i = 0; i < command.arguments.length; i++) {
        final pointer = command.arguments[i].toNativeUtf8();
        allocated.add(pointer);
        argv[i] = pointer;
      }
      argv[command.arguments.length] = nullptr;

      final code = bindings.command(_handle, argv);
      if (code < 0) {
        throw MediaPlayerException(
          '${command.name} failed: ${bindings.describeError(code)}',
          code: code,
        );
      }
    } finally {
      for (final pointer in allocated) {
        calloc.free(pointer);
      }
      calloc.free(argv);
    }
  }

  Future<void> _setProperty(String name, String value) async {
    _checkAlive();
    final bindings = _library.bindings;
    final namePointer = name.toNativeUtf8();
    final valuePointer = value.toNativeUtf8();
    try {
      final code =
          bindings.setPropertyString(_handle, namePointer, valuePointer);
      if (code < 0) {
        throw MediaPlayerException(
          'could not set $name=$value: ${bindings.describeError(code)}',
          code: code,
        );
      }
    } finally {
      calloc
        ..free(namePointer)
        ..free(valuePointer);
    }
  }

  /// Reads any mpv property as a string. Useful for diagnostics the typed
  /// state does not cover.
  String? readProperty(String name) {
    _checkAlive();
    return _library.bindings.readStringProperty(_handle, name);
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('MpvPlayer has been disposed');
    }
  }
}

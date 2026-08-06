/// A live mpv render context, addressed from Dart by its texture id.
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// Video output could not be started, or failed while running.
///
/// Worth catching rather than propagating: a player with no picture is still a
/// player, and on this app's study screen it is still a usable one. The caller
/// decides whether losing video is fatal.
class VideoOutputException implements Exception {
  const VideoOutputException(this.message, {this.code});

  final String message;

  /// The platform error code, when there was one.
  final String? code;

  @override
  String toString() => 'VideoOutputException: $message';
}

/// Video output for one libmpv instance.
///
/// Created against a *running* engine: it takes the `mpv_handle` the Dart
/// bindings already own rather than starting one of its own. Two things follow
/// from that, and both matter.
///
/// The first is ordering. Create this before loading a file. mpv's `vo=libmpv`
/// has nothing to draw into until a render context exists, and a file opened
/// first will have decoded its opening frames with the video output stalled.
///
/// The second is teardown. The render context holds the engine handle, so it
/// must be disposed *before* the player is. libmpv notices the other order and
/// says so — "Broken API use: mpv_render_context_free() not called" — after it
/// is too late to matter.
class VideoOutput {
  VideoOutput._(this.textureId);

  static const MethodChannel _channel = MethodChannel('voracious_video');

  /// Identifies the texture to a `Texture` widget, and this output to the
  /// platform side.
  final int textureId;

  bool _disposed = false;

  /// Attaches to the engine at [mpvHandle].
  ///
  /// [mpvHandle] is the address of an initialised `mpv_handle*` —
  /// `MpvPlayer.nativeHandle`. [libraryPath] is the library the Dart side
  /// opened — `MpvPlayer.libraryPath` — and is passed rather than rediscovered
  /// so that both sides resolve the same libmpv image. Loading a second one
  /// would give the render context a different copy of the engine's globals
  /// from the handle it was given.
  ///
  /// [initialSize] is only what to draw until the widget has been laid out
  /// once; [setSurfaceSize] settles it.
  ///
  /// Throws [VideoOutputException] if the platform has no implementation, if
  /// libmpv has no render API, or if a GL context could not be made.
  static Future<VideoOutput> create({
    required int mpvHandle,
    required String libraryPath,
    Size initialSize = const Size(1280, 720),
  }) async {
    try {
      final textureId = await _channel.invokeMethod<int>('create', {
        'handle': mpvHandle,
        'libraryPath': libraryPath,
        'width': initialSize.width.round().clamp(1, 1 << 16),
        'height': initialSize.height.round().clamp(1, 1 << 16),
      });
      if (textureId == null) {
        throw const VideoOutputException('the platform returned no texture id');
      }
      return VideoOutput._(textureId);
    } on MissingPluginException {
      throw const VideoOutputException(
        'no video output on this platform yet',
        code: 'unimplemented',
      );
    } on PlatformException catch (error) {
      throw VideoOutputException(
        error.message ?? 'video output failed to start',
        code: error.code,
      );
    }
  }

  /// Sets the size mpv renders at, in physical pixels.
  ///
  /// This is the size of the box the video is being shown in, not the size of
  /// the video. mpv scales and letterboxes into whatever it is given and
  /// applies the display aspect ratio while doing it, so sizing to the widget
  /// keeps anamorphic video correct without anything here knowing about pixel
  /// aspect, and scales a 4K file once instead of twice.
  ///
  /// Cheap to call with an unchanged size; the platform side coalesces
  /// requests and reallocates only when the size actually moves.
  Future<void> setSurfaceSize(Size pixels) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('setSurfaceSize', {
        'textureId': textureId,
        'width': pixels.width.round().clamp(1, 1 << 16),
        'height': pixels.height.round().clamp(1, 1 << 16),
      });
    } on PlatformException {
      // A resize that does not land is a cosmetic problem for one frame, and
      // the next layout will try again. Not worth propagating into a build.
    }
  }

  /// Releases the render context and the texture.
  ///
  /// Call before disposing the player; see the class comment. Safe to call
  /// twice.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _channel.invokeMethod<void>('dispose', {'textureId': textureId});
    } on PlatformException {
      // Nothing useful to do about a failure to tear down, and throwing here
      // would mask whatever the caller was disposing for.
    }
  }
}

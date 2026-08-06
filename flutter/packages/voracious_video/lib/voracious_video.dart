/// Video output for a running libmpv.
///
/// `voracious_mpv` owns control and state; nothing in it can put a picture on
/// screen, because getting decoded frames to the compositor means holding a
/// texture the toolkit owns and that is native code by definition. This is
/// that native code, and the seam between them is two numbers: the address of
/// the `mpv_handle` and the path of the libmpv it came from.
///
/// ```dart
/// final player = await MpvPlayer.create(platform: MpvPlatform.macos);
/// final output = await VideoOutput.create(
///   mpvHandle: player.nativeHandle,
///   libraryPath: player.libraryPath,
/// );
/// await player.open(path);          // after the render context exists
/// ...
/// await output.dispose();           // before the player
/// await player.dispose();
/// ```
library;

export 'src/video_output.dart' show VideoOutput, VideoOutputException;
export 'src/video_surface.dart' show VideoSurface;

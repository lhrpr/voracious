/// libmpv bindings and a [MediaPlayer] built on them.
///
/// libmpv is loaded dynamically at runtime, never statically linked. That is
/// what allows an LGPL build of mpv to be used by a proprietary application:
/// the user keeps the ability to replace the library. See
/// `flutter/docs/lgpl-mpv-build.md`.
library;

export 'src/mpv_bindings.dart'
    show MpvEndFileReasonCode, MpvEventId, MpvFormat, MpvHandle;
export 'src/mpv_event_pump.dart' show MpvEventPump, observedProperties;
export 'src/mpv_library.dart' show MpvLibrary, MpvLibraryNotFoundException;
export 'src/mpv_player.dart' show MpvPlayer;

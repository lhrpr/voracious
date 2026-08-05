# voracious_mpv

`dart:ffi` bindings to the libmpv client API, and a `MediaPlayer` implementation
on top of them. Pure Dart: Flutter is not required to build or analyse this
package.

## Dynamic loading

libmpv is opened with `DynamicLibrary.open` at runtime and never statically
linked. That is a licensing requirement, not a convenience — an LGPL library
used by a proprietary application has to remain replaceable by the user. See
[`docs/lgpl-mpv-build.md`](../../docs/lgpl-mpv-build.md).

`MpvLibrary.defaultCandidates()` lists the names tried per platform, and
`MpvLibrary.describe()` reports the exact library and client API version loaded,
which the about screen has to state.

```dart
final player = await MpvPlayer.create(platform: MpvPlatform.android);
await player.open('/storage/emulated/0/Movies/episode.mkv');
player.states.listen((state) => print(state.status));
```

`MpvPlayer.create` validates its option set against the components an LGPL build
does not have, and refuses to initialise a configuration that names one.

## Threading

`mpv_wait_event` blocks and must be called from one thread for the life of the
handle, so the event loop runs in a background isolate (`MpvEventPump`) and
posts decoded events back. The mpv handle crosses as a raw address, which is
safe because the client API is thread-safe.

`track-list` is observed formatless and then fetched with
`mpv_get_property_string`, which returns JSON — decoding an mpv node through FFI
is a great deal of work for a value that is already available as text.

## Scope

Control and state only. Getting decoded frames onto the screen goes through
`mpv_render_context_*` into a texture the toolkit owns, which belongs in the
Flutter plugin layer. Keeping the two apart is what lets everything here be
exercised without a display.

Audio clip extraction is not here either: see `AudioClipExtractor` in
`voracious_core`.

## Tests

`dart test` covers the parts that do not need libmpv installed — library
discovery, the observation table, and the client API constants. Anything that
calls into the library belongs in an integration suite that runs on a device
with a real build present.

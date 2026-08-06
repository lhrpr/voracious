# voracious_video

Video output. Attaches an mpv render context to a libmpv that `voracious_mpv`
is already driving, and draws its frames into a texture Flutter composites.

macOS only so far. The Dart API is written so that adding a platform means
adding a renderer, not changing this API.

## Why it is a separate package

`voracious_mpv` owns control and state and is pure Dart, which is what lets all
of it be tested without a display. Putting a picture on screen cannot be: it
means holding a texture the toolkit owns, and that is native code by
definition. Keeping the two apart is what keeps the first one testable.

The seam between them is two numbers — the address of the `mpv_handle` and the
path of the libmpv it came from:

```dart
final player = await MpvPlayer.create(platform: MpvPlatform.macos);
final output = await VideoOutput.create(
  mpvHandle: player.nativeHandle,
  libraryPath: player.libraryPath,
);
await player.open(path);      // after the render context exists
...
await output.dispose();       // before the player
await player.dispose();
```

Both orderings in that snippet are load-bearing.

**Create the output before opening a file.** `vo=libmpv` has nowhere to draw
until a render context exists, so a file loaded first spends its opening frames
with video output stalled.

**Dispose the output before the player.** The render context holds the engine
handle. libmpv notices the other order — "Broken API use:
mpv_render_context_free() not called" — well after it could have helped.

## How it works on macOS

Flutter's macOS embedder takes video frames as `CVPixelBuffer`s and turns them
into Metal textures. mpv's render API draws into an OpenGL framebuffer object.
An `IOSurface` is what bridges them: a pixel buffer backed by one can be bound
as a GL texture with `CGLTexImageIOSurface2D` and read by Metal without the
frame ever leaving the GPU.

The alternative is mpv's software render API into a malloc'd buffer, which
pulls every frame back across the bus — about 500 MB/s at 1080p60, to produce
a picture that then has to be uploaded again.

Two things about this are worth knowing before changing any of it.

**The surface is rendered at the widget's size, not the video's.** mpv scales
and letterboxes into whatever framebuffer it is given and applies the display
aspect ratio while doing it. Sizing to the widget therefore keeps anamorphic
video correct without the Dart side knowing anything about pixel aspect, and
scales a 4K file once rather than twice. It also means `VideoSurface` needs no
`AspectRatio`: the bars are already part of the frame.

**`MPV_RENDER_PARAM_FLIP_Y` is deliberately not set**, which looks wrong.
OpenGL's framebuffer origin is bottom-left and every Apple surface is top-down,
so a flip seems obviously required. It is not — `CGLTexImageIOSurface2D` maps
GL's row 0 to the *last* row of the IOSurface, so the two inversions have
already cancelled. Setting the flag inverts a correct image.

## Requirements

A libmpv with **the OpenGL render API compiled in**. This is not the same thing
as `gpu-api=opengl`:

- `gpu-api=opengl` selects the standalone `gpu` video output, which needs a
  windowing context. Current Apple builds of mpv do not have one and will
  reject the option — `mpv --gpu-api=help` on Homebrew's mpv 0.41 offers only
  `auto` and `vulkan`.
- The render API needs no windowing context, because the caller supplies the
  GL context. It comes from `video/out/opengl/libmpv_gl.c` and is present in
  the same Homebrew build that rejects `gpu-api=opengl`.

If it is missing, `VideoOutput.create` throws a `VideoOutputException` naming
the symbol, the app keeps playing without a picture, and the player screen says
why. See [`docs/lgpl-mpv-build.md`](../../docs/lgpl-mpv-build.md) for the flags
a shipped build needs.

## Verifying it

Two levels, because they answer different questions.

```sh
flutter test
```

covers the boundary — argument names, size rounding, that dispose is
idempotent, that the widget asks for physical pixels rather than logical ones.
It cannot reach the renderer at all: under `flutter test` there is no platform
side, `VideoOutput.create` throws `MissingPluginException`, and the caller is
expected to carry on without a picture.

```sh
tool/render_probe.sh path/to/video.mkv --out /tmp/frame.png
```

covers the part that matters and that no widget test can see. It compiles the
plugin's own `MpvOpenGLSurface.swift` — with no Flutter involved, which is why
that file has no Flutter in it — plays a few seconds against a real libmpv, and
reports what actually landed in the IOSurface:

```
frames rendered: 86 in 3.0s
video size: 1280x720
hwdec in use: videotoolbox
surface: 1280x720  mean R=124.5 G=129.4 B=126.0  non-black 99.8%
```

It exits non-zero if no frame arrived or the surface came back black, and the
PNG is there for the failures a number cannot describe. Run it against colour
bars: the per-channel means make a red/blue swizzle obvious, and the flip
described above is a thing you can only see.

There is also
[`voracious_app/integration_test`](../../apps/voracious_app/integration_test),
which needs a real embedder (`flutter test integration_test -d macos`) and
checks that a render context is really created against the running engine and
that the teardown order libmpv insists on is the one the app uses.

## Layout

```
lib/
  voracious_video.dart          exports
  src/
    video_output.dart           the channel client and its lifetime rules
    video_surface.dart          Texture widget; reports its pixel size
macos/voracious_video/
  Package.swift                 SwiftPM; this plugin is SPM-only
  Sources/
    mpv_client_api/             vendored ISC headers, no linking (see its README)
    voracious_video/
      VoraciousVideoPlugin.swift  method channel, one renderer per texture id
      MpvRenderApi.swift          libmpv's render entry points, via dlsym
      MpvOpenGLSurface.swift      CGL, IOSurfaces, the render loop — no Flutter
      MpvVideoRenderer.swift      the FlutterTexture adapter over it
tool/
  render_probe.swift            headless driver for the above
  render_probe.sh               builds and runs it
```

### Swift Package Manager only

There is no podspec. The app this ships in uses SwiftPM, which is Flutter's
default, and an untested podspec is worth less than an honest absence of one —
particularly here, where the package has two targets and a module map that
CocoaPods would need a different arrangement for.

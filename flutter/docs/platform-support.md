# Platform support

What runs where, and what each platform needs beyond the shared core.

## The tiers

| Tier | Platforms | Shared code |
|---|---|---|
| Full | Windows, macOS, Android, iOS | ~100% of core, all of the UI |
| TV | Google TV / Android TV, Fire TV, Nvidia Shield, cheap Amlogic/Rockchip boxes, tvOS | All of core; a separate ten-foot UI |
| Separate project | Samsung Tizen, LG webOS, Roku | None — these will not run native code |

Everything in `voracious_core` is pure Dart and platform-agnostic. Only the
implementations behind the interfaces listed in the
[README](../README.md#platform-seams) differ.

## Full tier

### Windows

- libmpv as `libmpv-2.dll` beside the executable.
- `hwdec=d3d11va`, `gpu-api=d3d11`, `ao=wasapi`.
- `LocalFileSystem` works directly.

### macOS

- `libmpv.dylib` in `Contents/Frameworks/`, loaded via `@rpath`.
- `hwdec=videotoolbox`, `ao=coreaudio`.
- Video output is implemented: `voracious_video` draws the mpv render context
  into an IOSurface-backed `CVPixelBuffer` that Flutter composites as a
  texture. It needs a libmpv with the OpenGL render API compiled in, which is a
  different thing from `gpu-api=opengl` — see
  [`lgpl-mpv-build.md`](lgpl-mpv-build.md#the-opengl-render-api-is-not-optional-and-is-not-gpu-apiopengl).
- Sandboxing: a collection folder chosen through the open panel needs a
  security-scoped bookmark to survive a relaunch. `LocalFileSystem` is fine once
  the bookmark is resolved.

### Android

- `libmpv.so` per ABI (`arm64-v8a`, `armeabi-v7a`, `x86_64`) in `jniLibs`.
- `hwdec=mediacodec-copy`, `ao=audiotrack`.
- **Storage is the real work.** A collection chosen through the Storage Access
  Framework arrives as a content URI, not a path, and `LocalFileSystem` cannot
  read it. This needs a `MediaFileSystem` implementation over `DocumentFile`.
  mpv can play a content URI given an open file descriptor.

### iOS

- libmpv as a **dynamic** `mpv.framework`. Dynamic frameworks have been
  supported since iOS 8; the static-linking anxiety in the usual write-ups does
  not apply, and this is what VLC ships on the App Store under LGPL.
- `hwdec=videotoolbox`, `ao=avfoundation`.
- Files come from the Files app via security-scoped URLs, or from the app's own
  document directory.

## TV tier

One Android codebase covers Google TV, Android TV, Fire TV, Nvidia Shield and
the cheap Amlogic/Rockchip boxes. **No Shield is required** — every one of those
chipsets has a dedicated decode block, and H.264/H.265 4K60 is table stakes.
MediaCodec is one runtime-queried API across all of them, so there are no
per-vendor builds; the only per-architecture artefact is the `.so`, which is a
normal ABI split.

Fire TV differs only in packaging: Amazon IAP instead of Play Billing, no Play
Services, different remote conventions, separate submission. Gradle product
flavours handle it; roughly 95% of the code is shared.

tvOS shares the iOS media stack and needs its own UI.

### What actually goes wrong on cheap boxes

- **CPU headroom.** Keep video decode on the hardware path religiously. Use
  `MpvTuning.cheapTvBox`, which turns off the scaling, dithering, debanding and
  interpolation a desktop GPU does for free, and shrinks the demuxer cache to
  fit 2 GB of RAM.
- **ASS/SSA rendering.** libass does per-frame CPU vector rasterisation and
  stutters on a $40 box. A "simplify styling" fallback is worth having.
- **Buggy MediaCodec.** Broken flushes, wrong colour ranges, hangs. mpv carries
  workarounds; test on the worst device early.
- **Seeking.** A-B loops mean constant flushes, which is the operation cheap
  decoders handle worst. Test loop-heavy workflows on real hardware, not an
  emulator.
- **Audio.** Dolby and DTS are licensed per device and many boxes only pass
  them through. mpv's own AC-3/DTS decoders fix this cheaply, which is why
  `audio-spdif` is left empty in the Android configuration.

Suggested floor: Android TV 10+, 2 GB RAM, hardware HEVC.

### Scope the TV UI down

A TV is a hostile input device: D-pad only, no touch, ten-foot viewing distance.
A-B loop, playback speed and the listening/reading modes map fine to a remote.
Word-tap dictionary lookup, flashcard export and note-taking do not.

The sensible split is passive watching on TV, with the interactive work on phone
or desktop. This decision shapes the whole navigation model, so it is worth
making before any TV UI is built — and it is also what would make a constrained
Tizen/webOS build tolerable later, since such a build would not be attempting
the hard part.

## Separate-project tier

Tizen (JS/HTML), webOS (JS/HTML) and Roku (BrightScript) will not run a native
binary **under any licence** — the barrier is native code, not copyleft.
Accepting GPL would not help, and would cost the App Store (VLC was pulled over
exactly this).

If a Tizen or webOS build is ever justified, it is a reduced web build using
the platform's own media pipeline (AVPlay on Tizen, the webOS media pipeline on
webOS), reimplementing the study modes against it. Note what that costs: patchy
MKV support, no libass, and poor seek control — the weakest denominator of the
lot. It is only worth it for the scoped-down passive TV experience above, never
as the primary target.

Nothing in `voracious_core` assumes a native engine. It is pure Dart behind a
`MediaPlayer` interface, so the study modes, subtitle handling and library logic
would port to such a build; only the engine layer would be rewritten.

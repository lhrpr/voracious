# Rewrite status

This tracks the Flutter/Dart, LGPL-mpv rewrite living under [`flutter/`](flutter/).
The root [`README.md`](README.md) still describes the original Electron app —
that file is left alone; this one is for the rewrite until it's ready to
replace it.

## Where things stand

| Package | State |
|---|---|
| [`voracious_core`](flutter/packages/voracious_core) | Done for the areas it covers. Pure Dart, 346 tests, `dart analyze`/`dart format` clean. |
| [`voracious_mpv`](flutter/packages/voracious_mpv) | Done. `dart:ffi` bindings + `MediaPlayer` impl, 33 tests (10 unit + 23 against a real libmpv), `dart analyze`/`dart format` clean. |
| [`voracious_video`](flutter/packages/voracious_video) | Done for macOS. mpv render context → IOSurface → `FlutterTexture`, 12 tests plus a headless render probe. |
| [`voracious_app`](flutter/apps/voracious_app) | macOS UI, playable end-to-end **with a picture**. 18 tests + 2 integration tests, `flutter analyze`/`dart format` clean. |

All four build and test natively on macOS (Dart 3.12.2, Flutter 3.44.8, mpv
0.41.0). Windows, Android, iOS/tvOS apps are not started — the platform seams
they'd need are in `voracious_core` and tested, but nothing renders them yet.

## The macOS app today

Runs, shows video, plays audio, drives the study modes, shows subtitles with
furigana — against a real video file, a real libmpv, real position updates.
What it does not have:

- Dictionary lookup on word tap (the plumbing is there; no tokeniser wired up
  yet, no dictionary UI).
- Anki export UI, and a settings screen for the preferences core already
  persists.
- Security-scoped bookmarks, so a collection folder survives a relaunch under
  the sandbox.

See [`flutter/apps/voracious_app/README.md`](flutter/apps/voracious_app/README.md)
for the keyboard layout, file layout, and a note on why `PlayerController`
reads state through getters instead of mirroring it into fields.

## How video output works

Flutter's macOS embedder takes frames as `CVPixelBuffer`s and turns them into
Metal textures; mpv's render API draws into an OpenGL framebuffer. An
`IOSurface` bridges them — a pixel buffer backed by one binds as a GL texture
via `CGLTexImageIOSurface2D` and is read by Metal without the frame leaving the
GPU. mpv's software render API would have worked and would have pulled every
frame back across the bus, roughly 500 MB/s at 1080p60.

The requirement this puts on a shipped build is easy to get wrong, so it is
written down in [`flutter/docs/lgpl-mpv-build.md`](flutter/docs/lgpl-mpv-build.md):
libmpv must have **the OpenGL render API** compiled in, which is a different
thing from `gpu-api=opengl`. The latter needs a windowing context that Apple
builds of mpv do not have and reject the option for; the former needs none,
because the caller supplies the context. Homebrew's mpv 0.41 refuses
`gpu-api=opengl` and has the render API, which is exactly the pair that makes
this confusing.

Full notes, including why `MPV_RENDER_PARAM_FLIP_Y` is deliberately not set,
are in [`flutter/packages/voracious_video/README.md`](flutter/packages/voracious_video/README.md).

## Bugs found by testing against real libmpv

Worth recording because none of them were visible from pure-Dart tests — they
only showed up once an integration suite ran against an actual library:

1. **`gpu-api=opengl` was fatal on macOS/iOS/tvOS.** Current mpv only accepts
   `auto`/`vulkan` for `gpu-api` on Apple platforms; `MpvPlayer.create` treats
   a rejected option as fatal, so the engine could not start at all. Fixed by
   dropping the option there — under `vo=libmpv`, the render API caller picks
   the backend, so `gpu-api` (which configures the unused standalone `gpu` VO)
   was never doing anything besides breaking startup.
2. **An explicit library path silently fell back to the system libmpv** if it
   failed to load. For a shipped build that bundles its own libmpv, that meant
   quietly running whatever the machine happened to have — possibly a GPL
   build, which is the exact outcome dynamic linking exists to avoid. Explicit
   paths are now authoritative: fail loudly instead of substituting.
3. **A use-after-free crashed teardown roughly 1 time in 4.** The event pump
   isolate blocks in `mpv_wait_event` on a native thread that `Isolate.kill`
   cannot interrupt; disposing the player destroyed the handle while that
   thread could still be inside the call. Fixed with a cooperative shutdown
   (shared stop flag + `mpv_wakeup`, wait for isolate exit before freeing
   anything). Verified clean over repeated runs; a regression test opens and
   disposes the player 8 times per run.

Video output added two more, both from checks written because the failure would
otherwise have been invisible rather than because anything looked wrong:

4. **The picture was upside down.** `MPV_RENDER_PARAM_FLIP_Y` looks obviously
   required — GL's framebuffer origin is bottom-left, every Apple surface is
   top-down — but `CGLTexImageIOSurface2D` has already inverted it, so setting
   the flag flips a correct image. Found by
   [`render_probe.sh`](flutter/packages/voracious_video/tool/render_probe.sh),
   which writes the rendered frame out as a PNG; against colour bars the flip
   and a red/blue swizzle are both immediate, and neither is a thing an
   assertion would have been written for.

5. **`MpvLibrary.path` was not a path.** On macOS the first candidate,
   `@rpath/libmpv.dylib`, loads successfully inside an app bundle — dyld falls
   back to the leaf name — so that string was recorded as the library's
   location. It is not one. `@rpath` resolves against the *loading* Mach-O
   image, so handing it to the video output plugin gave a path that opened for
   the Dart VM and failed from the plugin, and the about screen was naming a
   library the user could not go and look at, which is precisely what the LGPL
   notice is for. `MpvLibrary` now asks the loader where the library actually
   is, with `dladdr` on one of its own symbols.

And one that no test would have caught, because nothing was wrong from the
app's side — it took reading what mpv actually starts:

6. **`load-scripts=no` was not turning the scripts off.** It only covers the
   user's `scripts/` directory; mpv's own Lua scripts are compiled into the
   library and each has its own switch. The embedded player was starting eight
   of them — console, stats, auto_profiles, select, positioning, commands,
   context_menu, ytdl_hook — on eight threads with eight Lua states, none of
   them reachable, and two installing `on_load` hooks that every `loadfile`
   waited on. All eight are now switched off explicitly and a trace of the
   shipped option list loads zero scripts. Because those switches were added
   across mpv 0.32–0.41, they are the one category of option `MpvPlayer.create`
   will skip rather than fail on when the library does not have it
   (`MpvOption.optional`); a rejected *value* is still fatal.

## Environment notes

- `brew install dart-sdk` for a standalone Dart SDK (no Flutter needed for the
  two packages).
- `brew install mpv` for a real `libmpv.dylib` — needed for the mpv
  integration suite and for running the app at all. Both skip themselves
  cleanly if it's absent. That build has the OpenGL render API video output
  needs, but not `videotoolbox-gl`, so on a dev machine mpv falls back to
  moving decoded frames through system memory. Correct, just not free; a
  shipped build enables it.
- `brew install --cask flutter` and `brew install cocoapods` for the app.
- Debug builds of the app run **unsandboxed** on purpose — a sandboxed process
  can't `dlopen` a library outside its bundle, so it can't reach the Homebrew
  libmpv on a dev machine. Release builds keep the sandbox and expect a
  bundled LGPL libmpv; see
  [`flutter/docs/lgpl-mpv-build.md`](flutter/docs/lgpl-mpv-build.md).

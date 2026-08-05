# Building an LGPL libmpv, and the obligations that come with it

This document is the operational half of `video-app-licensing-and-frameworks.md`
at the repository root. That one works out *what* licence position to take; this
one records *how* to build to it and what has to be shipped alongside.

> Not legal advice. A short consult with someone who knows open-source
> licensing is cheap insurance before launch, particularly on the linking setup.

## The position in one paragraph

mpv's default build is GPLv2+. Building it with `--enable-lgpl` produces an
LGPLv2.1+ library, which a proprietary application may use provided it links
dynamically, ships the licence notices, and publishes the corresponding source
of the exact build it distributes. FFmpeg underneath is LGPL 2.1+ as long as it
is built with `--disable-gpl` and without `--enable-nonfree`. libass is ISC and
carries no copyleft obligation at all.

## What LGPL mode removes

Relicensing permission could not be obtained from every MPlayer-era author, so
`--enable-lgpl` compiles these out:

| Component | Consequence for us |
|---|---|
| X11 and Xv video output | None. We render through the client render API (`vo=libmpv`). |
| Legacy `direct3d` VO | None. Windows uses `gpu-api=d3d11`. |
| CACA video output | None. |
| OSS and JACK audio output | None. Desktop Linux uses `pulse,alsa`. |
| vdpau hardware decoding | None. nvdec covers the same NVIDIA hardware. |
| DVD, CDDA and DVB input | None. The library is files on disk. |

**None of these are on any path Voracious uses**, which is what makes LGPL mode
viable here rather than merely legal. The catch is that a plausible-looking
option added later to fix one device could quietly reintroduce a dependency on
one of them, and the failure would be a silent runtime fallback on one platform.

`MpvConfiguration` in `voracious_core` therefore carries
[`validateLgplSafety`](../packages/voracious_core/lib/src/player/mpv/mpv_options.dart),
and `mpv_test.dart` asserts that every shipped platform configuration passes it.
`MpvPlayer.create` runs the same check at startup and refuses to initialise a
configuration that names a removed component.

## Configure flags

### FFmpeg

```sh
./configure \
  --disable-gpl \
  --disable-nonfree \
  --disable-version3 \
  --enable-shared --disable-static \
  --disable-programs --disable-doc \
  --enable-decoder=aac,ac3,eac3,dts,mp3,opus,vorbis,flac,alac,pcm_s16le \
  --enable-decoder=ass,ssa,subrip,webvtt,mov_text \
  --enable-demuxer=matroska,mov,mpegts,avi,webm_dash_manifest,ass,srt,webvtt \
  --enable-parser=aac,ac3,h264,hevc,vp9,av1 \
  --disable-encoders --disable-muxers \
  --disable-debug
```

The shape of that list is the architecture from the licensing notes: **all video
decoders stay off**. Video goes to the platform hardware decoder, so FFmpeg
demuxes, parses, and decodes audio and subtitles only. That is also what keeps
video codec patent exposure with the device maker, who has already paid.

Encoders are disabled outright. Anki audio clips are produced by a separate
extractor (see below), not by this build.

Verify afterwards:

```sh
# Must print nothing.
grep -E 'CONFIG_(GPL|NONFREE|LIBX264|LIBX265|POSTPROC)\s+1' config.h
```

### mpv

```sh
meson setup build \
  -Dlgpl=true \
  -Dlibmpv=true \
  -Dcplayer=false \
  -Dgpl=false \
  -Dlua=disabled \
  -Djavascript=disabled \
  -Dlibarchive=disabled \
  -Dcdda=disabled -Ddvdnav=disabled -Ddvbin=disabled \
  -Doss-audio=disabled -Djack=disabled \
  -Dvdpau=disabled \
  -Dlibass=enabled \
  --default-library=shared
```

Verify afterwards:

```sh
# Must report LGPL, not GPL.
./build/mpv --version | grep -i licen
```

### Per-platform notes

| Platform | Extra flags | Output |
|---|---|---|
| Windows | `-Dd3d11=enabled -Dwasapi=enabled` | `libmpv-2.dll` |
| macOS | `-Dcocoa=enabled -Dvideotoolbox-gl=enabled` | `libmpv.dylib` in the app bundle's `Frameworks/` |
| iOS / tvOS | `-Dios-gl=enabled`, cross-file toolchain | `mpv.framework` — must be a **dynamic** framework |
| Android | `-Degl-android=enabled -Dmediacodec=enabled`, NDK cross-file, one build per ABI | `libmpv.so` under `jniLibs/<abi>/` |
| Linux | `-Dwayland=enabled -Dx11=disabled -Dpulse=enabled` | `libmpv.so.2` |

Android needs `arm64-v8a`, `armeabi-v7a` and `x86_64`. That is a normal ABI
split in one project, not per-vendor builds: MediaCodec is one runtime-queried
API across every chipset.

## Linking

Dynamic linking is the requirement that makes all of this work, so it is worth
being explicit about what that means per platform.

- **Windows / Linux** — a DLL or `.so` beside the executable. Nothing special.
- **macOS** — `libmpv.dylib` in `Contents/Frameworks/`, loaded via `@rpath`.
- **iOS / tvOS** — a **dynamic** `.framework`, supported since iOS 8. The
  static-linking anxiety in the usual write-ups applies only to static linking;
  a dynamic framework is fine, and it is what VLC ships on the App Store under
  LGPL.
- **Android** — `libmpv.so` in `jniLibs`, loaded with `System.loadLibrary`.

`voracious_mpv` never links libmpv statically: it calls `DynamicLibrary.open`
at runtime, and `MpvLibrary.defaultCandidates()` lists the names it tries.
`MpvLibrary.describe()` reports the exact library and client API version loaded,
which is what the about screen needs to state.

## Distribution checklist

Before shipping a build:

- [ ] `mpv --version` on the built library reports **LGPL**, not GPL.
- [ ] FFmpeg `config.h` has no `CONFIG_GPL`, `CONFIG_NONFREE`, `CONFIG_LIBX264`,
      `CONFIG_LIBX265` or `CONFIG_POSTPROC`.
- [ ] libmpv is loaded dynamically and is replaceable in the shipped layout.
- [ ] The about screen shows `renderNoticesAsText()` — licence, linkage and
      source URL for every component.
- [ ] The exact source of the shipped build, its configure flags, and any
      patches, are published at the URL in `correspondingSourceUrl` and stay
      reachable for as long as the binaries are distributed.
- [ ] `dart test` passes, including the LGPL safety assertions in `mpv_test.dart`.

Adding a native dependency means adding it to `thirdPartyNotices` in
`packages/voracious_core/lib/src/licensing/third_party_notices.dart`. The tests
assert that every copyleft entry there carries a source URL and is dynamically
linked, so a component added without a notice fails the build rather than
shipping quietly.

## Where a patent licence would be needed

Not from any of the above, but worth restating from the licensing notes, since
these are the three ways to walk into it:

1. Shipping a **software** H.264/H.265 decoder — avoided by disabling video
   decoders in FFmpeg and keeping `hwdec` on.
2. **Encoding** — clip export, generated flashcard video, on-device transcode.
   Use the platform hardware encoder (VideoToolbox, MediaCodec, Media
   Foundation), never x264/x265.
3. Server-side processing is exempt from copyleft since nothing is distributed,
   so GPL FFmpeg is fine there if we ever have a server.

## Audio clip extraction for Anki

`MediaPlayer` deliberately has no `extractAudio`. Playback engines decode audio
for output, not export, and producing an MP3 means running an encoder — a
per-platform packaging decision that must not grow into the playback path.

The `AudioClipExtractor` interface in `media_player.dart` covers it separately.
Implementations should prefer the platform encoder (`AVAssetExportSession`,
`MediaCodec`, Media Foundation) over bundling one.

# Language-Learning Video App — Licensing & Framework Notes

## The three separate issues

People conflate these; they're independent.

1. **FFmpeg's own licence.** Core is LGPL 2.1+ — fine for proprietary commercial use if you link dynamically, ship licence notices, and publish the LGPL-covered source. Only becomes GPL with `--enable-gpl` (x264, x265, libpostproc, some filters).
2. **Distribution vs. server-side.** Copyleft obligations trigger on *distribution*. Netflix/YouTube/Meta run FFmpeg on their own servers and ship only the output, so it never bites them. Their clients use OS decoders.
3. **Codec patents.** Entirely separate from software licensing. H.264/HEVC/AAC are pooled. Switching away from FFmpeg doesn't help. Using the OS decoder does — the device maker already paid.

**"No one uses FFmpeg commercially" is a myth.** Chrome ships a trimmed LGPL build; VLC is on the App Store under LGPL.

**Caveat:** issue 1 is about FFmpeg *alone*. Any wrapper that bundles FFmpeg stacks its own licence on top, and the wrapper's terms can be stricter than FFmpeg's. See the mpv section below — this is the trap.

---

## Recommended architecture

Use FFmpeg (or libVLC) as a **demuxer/parser only**. It opens the container, pulls out tracks, and hands compressed H.264/H.265 samples to the OS hardware decoder. It never decodes video itself.

- Near-universal format support
- Hardware acceleration, good battery life
- Video patent exposure stays with the OEM
- Software decode used only for audio codecs and subtitles (cheap, low exposure)

This is standard professional practice — ExoPlayer ships an FFmpeg extension for exactly this.

### Native player / decode APIs

| Platform | API |
|---|---|
| iOS / macOS / tvOS | AVFoundation + VideoToolbox |
| Android / Android TV | Media3 (ExoPlayer) + MediaCodec |
| Windows | Media Foundation |
| Web | HTML5 `<video>`, WebCodecs for frame-level work |
| Samsung Tizen | AVPlay |
| LG webOS | webOS Media Pipeline |
| Roku | BrightScript player (no native modules at all) |

### Open-source libraries

- **FFmpeg** — LGPL 2.1+ core; demux, parse, audio decode, subtitle parsing
- **libVLC / VLCKit / MobileVLCKit** — LGPL; wraps the whole pipeline if you'd rather not build FFmpeg yourself
- **GStreamer** — LGPL, plugin architecture; same patent caveats
- **Media3 / ExoPlayer** — Apache 2.0; carries a large device-workaround table, worth it on its own
- **libass** — **ISC licensed**, not copyleft. ASS/SSA subtitle rendering needs no GPL concession.
- **mpv / libmpv** — **GPLv2+ by default.** An LGPL build mode exists but is conditional and lossy; see below.

### mpv / libmpv — a third copyleft layer

Worth calling out separately, because wrapper libraries (Flutter's `media_kit`, various Electron and Qt players) present libmpv as a drop-in and the licence question is easy to miss.

- **Default build is GPLv2+**, inherited from MPlayer code. Not LGPL like FFmpeg's core.
- An **LGPLv2.1+ mode** (`--enable-lgpl`) exists, the result of a multi-year relicensing effort. The mpv developers state the intended use of LGPL mode *is* libmpv specifically — so it's a supported path, not a hack.
- Relicensing permission couldn't be obtained from every MPlayer-era author, so LGPL mode **disables**: X11 video output, OSS audio, vdpau, JACK, DVD/CDDA/DVB, CACA, legacy direct3d.
- For our purposes most of those losses are harmless — a consumer using libmpv's GPU render API never touches the X11 VO, and nvdec covers what vdpau would have. But it means an LGPL libmpv is **not** the same binary everyone else is testing against.

**The practical consequence: "libmpv" has no single licence.** It is set entirely by configure flags — which you do not control when consuming prebuilt binaries.

Checked against `media_kit` as the worked example:

| Layer | Licence |
|---|---|
| `media_kit` Dart code | MIT |
| `media_kit_libs_*` native binaries | Built in separate repos; **flags undocumented** |
| Android build repo | Build *flavours* incl. an explicit `encoders-gpl` (GPLv3) alongside default/full |

The maintainers are clearly aware of the split, and the default flavour presumably omits x264/x265. But those repos' LICENSE files cover the **build scripts**, not the binary they produce — and the binary's licence is decided by the mpv and FFmpeg configure flags, which are not published. Establishing the real answer means reading their build scripts, and possibly maintaining our own libmpv builds across every target platform.

**Architectural tension:** mpv also isn't a demuxer. It is a complete playback pipeline with its own opinions. It does use hardware decode (VideoToolbox / MediaCodec / D3D11VA / VAAPI / nvdec), so the patent story is comparable — but adopting it means abandoning the demux-only architecture recommended above, and taking a much larger dependency.

---

## LGPL in a paid app — practical checklist

Monetisation is irrelevant to LGPL; only linking and source availability matter.

- Build with `--disable-gpl`; audit enabled components (no x264, x265, `--enable-nonfree`)
- **Link dynamically** — on iOS, a dynamic `.framework` (supported since iOS 8). The static-linking anxiety you've read about applies only to static linking.
- Ship LGPL text and attribution in the about screen
- Host the exact source you built, with configure flags and patches, at a stable URL
- Keep your code in separate modules that merely call the library
- **Audit any wrapper that ships prebuilt native binaries** (`media_kit`, VLCKit, ffmpeg-kit). Its own LICENSE file usually covers its source, not the binary it bundles. If the configure flags aren't published, assume nothing — either verify them or build your own.

### Where you *would* need a patent licence

1. Shipping your own **software** H.264/H.265 decoder (e.g. desktop with no hardware decode)
2. **Encoding** — clip export, generated flashcard videos, on-device transcoding. Use VideoToolbox/MediaCodec hardware encoders, not x264/x265.
3. Server-side processing is exempt from copyleft (no distribution), so GPL FFmpeg is fine there.

---

## Android TV

**No Shield required.** Amlogic, Rockchip, and Realtek all have dedicated decode blocks; H.264/H.265 4K60 is table stakes. MediaCodec is one runtime-queried API across every chipset — **no per-vendor builds**. The only per-architecture artefact is your FFmpeg `.so` (arm64-v8a, armeabi-v7a, x86_64), which is a normal ABI split in one project.

### Real problems on cheap boxes

- **CPU headroom** — keep video decode on the hardware path religiously
- **ASS/SSA rendering** — libass does per-frame CPU vector rasterisation; stutters on $40 boxes. Consider a "simplify styling" fallback.
- **Buggy MediaCodec** — broken flushes, wrong colour ranges, hangs. Media3's workaround table is a strong argument against hand-rolling.
- **Seeking** — A-B loops mean constant flushes, the operation cheap decoders handle worst. Test loop-heavy workflows early on your worst device.
- **Audio** — Dolby/DTS are licensed per-device; many boxes only pass through. FFmpeg's software AC-3/DTS decoders fix this cheaply.

Suggested floor: Android TV 10+, 2 GB RAM, hardware HEVC.

---

## Cross-platform reality

**One Android codebase covers:** Google TV / Android TV, Amazon Fire TV, Nvidia Shield, cheap Amlogic/Rockchip boxes.

Fire TV differences are small — Amazon IAP instead of Play Billing, no Play Services, different remote conventions, separate submission. Handle with Gradle product flavours; ~95% shared code.

**Genuinely separate projects:** Tizen (JS/HTML), webOS (JS/HTML), Roku (BrightScript), tvOS (Swift).

### Does accepting copyleft help here?

**No.** The barrier on Tizen/webOS/Roku is *native code*, not licensing — they won't run your binary under any licence, commercial ones included. And GPL actively hurts:

- App Store conflict (VLC was pulled over it) — affects iOS/tvOS
- Viral across linking; your app becomes GPL and redistributable
- Gains you almost nothing — the GPL components are encoders and filters. Every decoder, demuxer, and parser you need is in the LGPL core, and libass is ISC.

The one real exception: accepting GPL would let us take **stock libmpv and its wrappers off the shelf**, skipping the LGPL build work described above. That's a convenience argument, not a capability one, and it costs iOS/tvOS.

### Options for reducing the split

- **Accept it** — Android for the native world; a reduced web build for Tizen/webOS if ever justified
- **Web-first everywhere** — maximum reach, but inherits the weakest denominator (patchy MKV, no libass, poor seek control) on *all* platforms. Bad trade here.
- **Scope the TV tier down** — probably the real answer. A TV is a hostile input device: D-pad only, no touch, ten-foot distance. A-B loop and speed map fine to a remote; word-tap dictionary lookup, flashcards, and notes don't. If TV is passive watching with the interactive work on phone/desktop, a constrained Tizen/webOS build becomes tolerable — it isn't trying to do the hard part.

Decide this before building the Leanback UI; it shapes the whole navigation model.

---

*Not legal advice. A short consult with someone who knows open-source licensing and media patents is cheap insurance before launch, particularly on your linking setup.*

/// mpv configuration, and the rules that keep it inside an LGPL build.
///
/// mpv's default build is GPLv2+. Building it with `--enable-lgpl` produces an
/// LGPLv2.1+ library, which is what a proprietary application can link against
/// dynamically — but the relicensing was never completed for every MPlayer-era
/// component, so LGPL mode **removes** some of them outright: the X11 video
/// output, OSS and JACK audio, vdpau, DVD/CDDA/DVB input, CACA, and the legacy
/// direct3d VO.
///
/// The practical hazard is not that a removed component fails to build — it is
/// that a configuration naming one silently falls back at runtime, on one
/// platform, months later. [validateLgplSafety] exists so that a configuration
/// naming a removed component fails in a unit test instead.
///
/// See `flutter/docs/lgpl-mpv-build.md` for the build flags themselves and the
/// distribution obligations that come with them.
library;

import 'package:meta/meta.dart';

/// Platforms the app targets, as far as engine configuration is concerned.
///
/// Android TV and Google TV are the same runtime as Android and differ only in
/// how much headroom the hardware has, which is a tuning question rather than a
/// platform one — see [MpvTuning.lowPower].
enum MpvPlatform {
  windows,
  macos,
  linux,
  android,
  ios,

  /// tvOS. Same media stack as iOS, different UI and app lifecycle.
  tvos,
}

/// A single `--name=value` option.
@immutable
class MpvOption {
  const MpvOption(this.name, this.value, {this.optional = false});

  final String name;
  final String value;

  /// Whether a build that has never heard of this option may ignore it.
  ///
  /// Almost every option here is load-bearing, so a library that rejects one
  /// is a library this app cannot use and `MpvPlayer.create` refuses to start
  /// on it. The exceptions are the switches that turn mpv's built-in scripts
  /// off: they arrived across several mpv releases, and each one only ever
  /// removes work. An older library should skip the ones it lacks rather than
  /// fail to start. A rejected *value* stays fatal either way — only an
  /// unknown option name is tolerated.
  final bool optional;

  @override
  bool operator ==(Object other) =>
      other is MpvOption &&
      other.name == name &&
      other.value == value &&
      other.optional == optional;

  @override
  int get hashCode => Object.hash(name, value, optional);

  @override
  String toString() => '$name=$value';
}

/// Performance and quality knobs.
@immutable
class MpvTuning {
  const MpvTuning({
    this.lowPower = false,
    this.hardwareDecoding = true,
    this.cacheSeconds = 30,
    this.demuxerMaxBytes,
    this.audioChannels = 'auto-safe',
  });

  /// Cheap Amlogic/Rockchip TV boxes and older phones. Turns off the scaling
  /// and dithering that a desktop GPU does for free, and shrinks the demuxer
  /// cache to fit a 2 GB device.
  final bool lowPower;

  /// Keep video decode on the hardware path. Turning this off is a debugging
  /// aid, not a supported configuration: software decode of H.264/HEVC is both
  /// the battery problem and the patent exposure the architecture avoids.
  final bool hardwareDecoding;

  final int cacheSeconds;

  /// Demuxer cache size. Defaults to 32 MB, or 8 MB when [lowPower].
  final int? demuxerMaxBytes;

  /// `auto-safe` downmixes to what the device actually supports rather than
  /// assuming a passthrough-capable receiver, which is the common failure on
  /// TV boxes that report more channels than they can output.
  final String audioChannels;

  int get effectiveDemuxerMaxBytes =>
      demuxerMaxBytes ?? (lowPower ? 8 * 1024 * 1024 : 32 * 1024 * 1024);

  static const MpvTuning desktop = MpvTuning();
  static const MpvTuning cheapTvBox =
      MpvTuning(lowPower: true, cacheSeconds: 10);
}

/// Builds the option list for an embedded, LGPL-safe libmpv.
abstract final class MpvConfiguration {
  /// Options that apply everywhere.
  ///
  /// The theme running through them is that this is a library inside someone
  /// else's UI: mpv must not create a window, must not read the user's config
  /// files, must not bind the keyboard, and must not draw an OSD.
  static List<MpvOption> common(MpvTuning tuning) => [
        // Render through the client render API into a texture the toolkit owns.
        // This is also the video output path that LGPL mode fully supports —
        // the X11 VO it removes is never involved.
        const MpvOption('vo', 'libmpv'),

        // Stay alive between files rather than exiting at the end of playback.
        const MpvOption('idle', 'yes'),
        const MpvOption('keep-open', 'yes'),
        const MpvOption('force-window', 'no'),

        // The host application owns all input and all chrome.
        const MpvOption('osc', 'no'),
        const MpvOption('osd-level', '0'),
        const MpvOption('input-default-bindings', 'no'),
        const MpvOption('input-vo-keyboard', 'no'),
        const MpvOption('terminal', 'no'),

        // Never read ~/.config/mpv: the app's behaviour must not depend on a
        // file the user forgot they wrote in 2016.
        const MpvOption('config', 'no'),
        const MpvOption('load-scripts', 'no'),

        // `load-scripts=no` covers the user's `scripts/` directory and nothing
        // else. mpv's own scripts are compiled into the library and each has
        // its own switch, so an embedded libmpv still starts eight of them:
        // every one below, plus `osc` — already off above, which is why the
        // on-screen controller is the one that does not appear here. Each runs
        // on its own thread with its own Lua state, and `auto_profiles` and
        // `ytdl_hook` also install `on_load` hooks that every `loadfile` then
        // blocks on.
        //
        // None of them can reach anything in this app: the host owns the OSD,
        // the keyboard and the menus, so console, stats, select, positioning,
        // commands and context_menu have no input to receive and no surface to
        // draw on. `auto_profiles` evaluates conditional profiles from a
        // config file that `config=no` already refused to read. `ytdl_hook`
        // shells out to yt-dlp for URLs, and Voracious opens local files.
        //
        // These are [MpvOption.optional] because they were added across mpv
        // 0.32–0.41; a library predating one must skip it and start, not
        // refuse. `load-console` was `load-osd-console` before 0.40 — the old
        // name still works but warns on every start, so it is not set here and
        // a pre-0.40 library keeps console.lua.
        const MpvOption('load-console', 'no', optional: true),
        const MpvOption('load-stats-overlay', 'no', optional: true),
        const MpvOption('load-auto-profiles', 'no', optional: true),
        const MpvOption('load-select', 'no', optional: true),
        const MpvOption('load-positioning', 'no', optional: true),
        const MpvOption('load-commands', 'no', optional: true),
        const MpvOption('load-context-menu', 'no', optional: true),
        const MpvOption('ytdl', 'no', optional: true),

        // Voracious loads, analyses and renders subtitles itself; mpv picking
        // up sidecar files as well would double every line on screen.
        const MpvOption('sub-auto', 'no'),
        const MpvOption('sid', 'no'),

        // Exact seeking is not optional here. Every study interaction —
        // replay this line, jump to the previous line, A-B loop — seeks to a
        // subtitle timestamp, and keyframe-only seeking would land seconds off.
        const MpvOption('hr-seek', 'yes'),
        const MpvOption('hr-seek-framedrop', 'no'),

        MpvOption('cache-secs', '${tuning.cacheSeconds}'),
        MpvOption('demuxer-max-bytes', '${tuning.effectiveDemuxerMaxBytes}'),
        MpvOption('audio-channels', tuning.audioChannels),

        // Slowing dialogue down is a study aid; it is useless without pitch
        // correction.
        const MpvOption('audio-pitch-correction', 'yes'),

        if (tuning.lowPower) ...const [
          MpvOption('scale', 'bilinear'),
          MpvOption('cscale', 'bilinear'),
          MpvOption('dscale', 'bilinear'),
          MpvOption('dither', 'no'),
          MpvOption('deband', 'no'),
          MpvOption('video-sync', 'audio'),
          MpvOption('interpolation', 'no'),
        ],
      ];

  /// Platform-specific decoder, audio output and GPU API selection.
  static List<MpvOption> forPlatform(
    MpvPlatform platform, {
    MpvTuning tuning = MpvTuning.desktop,
  }) =>
      [
        ...common(tuning),
        ..._platformOptions(platform, tuning),
      ];

  static List<MpvOption> _platformOptions(
    MpvPlatform platform,
    MpvTuning tuning,
  ) {
    if (!tuning.hardwareDecoding) {
      return [const MpvOption('hwdec', 'no'), ..._audioOutput(platform)];
    }

    switch (platform) {
      case MpvPlatform.windows:
        return [
          // Media Foundation's decoder, reached through D3D11VA.
          const MpvOption('hwdec', 'd3d11va'),
          const MpvOption('gpu-api', 'd3d11'),
          const MpvOption('gpu-context', 'd3d11'),
          const MpvOption('ao', 'wasapi'),
        ];

      // No `gpu-api` on the Apple platforms. Apple deprecated OpenGL and mpv
      // dropped the GL backend there, so `gpu-api=opengl` is not merely
      // suboptimal — it is not a value this build accepts, and because
      // MpvPlayer.create treats a rejected option as fatal, setting it stops
      // the engine from starting at all. Leaving it unset is also the correct
      // answer rather than a workaround: under `vo=libmpv` the render API
      // caller picks the backend through MPV_RENDER_PARAM_API_TYPE, and
      // `gpu-api` configures the standalone `gpu` VO, which is not in use.
      case MpvPlatform.macos:
        return [
          const MpvOption('hwdec', 'videotoolbox'),
          const MpvOption('ao', 'coreaudio'),
        ];

      case MpvPlatform.ios:
      case MpvPlatform.tvos:
        return [
          const MpvOption('hwdec', 'videotoolbox'),
          const MpvOption('ao', 'avfoundation'),
        ];

      case MpvPlatform.android:
        return [
          // `mediacodec` renders into the surface directly; the `-copy`
          // variant reads frames back so the render API can composite them,
          // which is what an embedded texture needs.
          const MpvOption('hwdec', 'mediacodec-copy'),
          const MpvOption('gpu-api', 'opengl'),
          const MpvOption('gpu-context', 'android'),
          const MpvOption('ao', 'audiotrack'),
          // Many boxes only pass Dolby/DTS through and cannot decode it.
          // Letting mpv's own AC-3/DTS decoders handle it is cheaper than
          // per-device licensing and works on hardware that would be silent.
          const MpvOption('audio-spdif', ''),
        ];

      case MpvPlatform.linux:
        return [
          // `auto-safe` picks VAAPI or nvdec. Notably not vdpau, which LGPL
          // mode removes; nvdec covers the same hardware.
          const MpvOption('hwdec', 'auto-safe'),
          const MpvOption('gpu-api', 'opengl'),
          const MpvOption('ao', 'pulse,alsa'),
        ];
    }
  }

  static List<MpvOption> _audioOutput(MpvPlatform platform) =>
      switch (platform) {
        MpvPlatform.windows => const [MpvOption('ao', 'wasapi')],
        MpvPlatform.macos => const [MpvOption('ao', 'coreaudio')],
        MpvPlatform.ios || MpvPlatform.tvos => const [
            MpvOption('ao', 'avfoundation')
          ],
        MpvPlatform.android => const [MpvOption('ao', 'audiotrack')],
        MpvPlatform.linux => const [MpvOption('ao', 'pulse,alsa')],
      };
}

/// A configuration value that an LGPL build of mpv cannot honour.
@immutable
class LgplViolation {
  const LgplViolation({
    required this.option,
    required this.component,
    required this.reason,
  });

  final MpvOption option;

  /// The component that LGPL mode removes.
  final String component;

  final String reason;

  @override
  String toString() => 'LgplViolation(${option.name}=${option.value}: $reason)';
}

/// Components `--enable-lgpl` removes, mapped to the option values that would
/// select them.
///
/// Relicensing permission could not be obtained from every MPlayer-era author,
/// so these stayed GPL and are compiled out of an LGPL build. A configuration
/// naming one does not fail loudly; it falls back, or plays without sound.
const Map<String, List<String>> _removedByLgplMode = {
  'vo': ['x11', 'xv', 'direct3d', 'caca'],
  'ao': ['oss', 'jack'],
  'hwdec': ['vdpau', 'vdpau-copy'],
  'gpu-context': ['x11', 'x11vk'],
  'gpu-api': ['vdpau'],
};

/// Reasons, for the message a failing test prints.
const Map<String, String> _removalReasons = {
  'x11': 'the X11 video output is GPL-only and absent from an LGPL build',
  'xv': 'the Xv video output is GPL-only and absent from an LGPL build',
  'direct3d': 'the legacy direct3d VO is GPL-only; use gpu-api=d3d11',
  'caca': 'the CACA video output is GPL-only',
  'oss': 'OSS audio output is GPL-only',
  'jack': 'JACK audio output is GPL-only',
  'vdpau': 'vdpau is GPL-only; nvdec covers the same hardware',
  'vdpau-copy': 'vdpau is GPL-only; nvdec covers the same hardware',
  'x11vk': 'the X11 Vulkan context is GPL-only',
};

/// Checks [options] against the components an LGPL build of mpv does not have.
///
/// Returns every violation found; an empty list means the configuration is
/// safe to run against `--enable-lgpl` libmpv. Call this from a test over
/// every platform's configuration, so that a plausible-looking option added to
/// fix one device does not quietly make the build require GPL mpv.
List<LgplViolation> validateLgplSafety(List<MpvOption> options) {
  final violations = <LgplViolation>[];

  for (final option in options) {
    final removed = _removedByLgplMode[option.name];
    if (removed == null) continue;

    // Option values may be a fallback list: `ao=pulse,alsa`.
    for (final value in option.value.split(',')) {
      final trimmed = value.trim();
      if (!removed.contains(trimmed)) continue;
      violations.add(LgplViolation(
        option: option,
        component: trimmed,
        reason: _removalReasons[trimmed] ?? '$trimmed is not in an LGPL build',
      ));
    }
  }

  return violations;
}

/// Formats [options] as the `--name=value` arguments an mpv build script or a
/// manual reproduction would use.
List<String> formatAsCommandLine(List<MpvOption> options) =>
    [for (final option in options) '--${option.name}=${option.value}'];

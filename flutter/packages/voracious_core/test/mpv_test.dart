import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

void main() {
  group('LGPL safety', () {
    test('every shipped platform configuration is LGPL-safe', () {
      // The point of this test: an option added to fix one device must not
      // quietly make the app require a GPL build of mpv.
      for (final platform in MpvPlatform.values) {
        for (final tuning in [MpvTuning.desktop, MpvTuning.cheapTvBox]) {
          final options =
              MpvConfiguration.forPlatform(platform, tuning: tuning);
          expect(
            validateLgplSafety(options),
            isEmpty,
            reason: 'configuration for $platform is not LGPL-safe',
          );
        }
      }
    });

    test('catches the components an LGPL build removes', () {
      final violations = validateLgplSafety(const [
        MpvOption('vo', 'x11'),
        MpvOption('ao', 'oss'),
        MpvOption('hwdec', 'vdpau'),
      ]);

      expect(violations, hasLength(3));
      expect(violations.map((v) => v.component), ['x11', 'oss', 'vdpau']);
      expect(violations.first.reason, contains('X11'));
    });

    test('catches a removed component inside a fallback list', () {
      final violations =
          validateLgplSafety(const [MpvOption('ao', 'pulse,jack,alsa')]);
      expect(violations.single.component, 'jack');
    });

    test('passes a safe fallback list', () {
      expect(
          validateLgplSafety(const [MpvOption('ao', 'pulse,alsa')]), isEmpty);
    });
  });

  group('mpv configuration', () {
    Map<String, String> optionsFor(MpvPlatform platform, {MpvTuning? tuning}) =>
        {
          for (final option in MpvConfiguration.forPlatform(platform,
              tuning: tuning ?? MpvTuning.desktop))
            option.name: option.value,
        };

    test('renders through the client API and creates no window', () {
      final options = optionsFor(MpvPlatform.linux);
      expect(options['vo'], 'libmpv');
      expect(options['force-window'], 'no');
      expect(options['osc'], 'no');
      expect(options['input-default-bindings'], 'no');
    });

    test('never reads the user config', () {
      // Behaviour that depends on ~/.config/mpv is unsupportable.
      expect(optionsFor(MpvPlatform.macos)['config'], 'no');
      expect(optionsFor(MpvPlatform.macos)['load-scripts'], 'no');
    });

    test('enables exact seeking, which study navigation depends on', () {
      expect(optionsFor(MpvPlatform.windows)['hr-seek'], 'yes');
    });

    test('leaves subtitles to the app', () {
      final options = optionsFor(MpvPlatform.android);
      expect(options['sub-auto'], 'no');
      expect(options['sid'], 'no');
    });

    test('selects the platform hardware decoder', () {
      expect(optionsFor(MpvPlatform.windows)['hwdec'], 'd3d11va');
      expect(optionsFor(MpvPlatform.macos)['hwdec'], 'videotoolbox');
      expect(optionsFor(MpvPlatform.ios)['hwdec'], 'videotoolbox');
      expect(optionsFor(MpvPlatform.tvos)['hwdec'], 'videotoolbox');
      expect(optionsFor(MpvPlatform.android)['hwdec'], 'mediacodec-copy');
      expect(optionsFor(MpvPlatform.linux)['hwdec'], 'auto-safe');
    });

    test('selects the platform audio output', () {
      expect(optionsFor(MpvPlatform.windows)['ao'], 'wasapi');
      expect(optionsFor(MpvPlatform.android)['ao'], 'audiotrack');
      expect(optionsFor(MpvPlatform.macos)['ao'], 'coreaudio');
    });

    test('software decode can be forced, and stays LGPL-safe', () {
      final options = optionsFor(
        MpvPlatform.linux,
        tuning: const MpvTuning(hardwareDecoding: false),
      );
      expect(options['hwdec'], 'no');
      expect(options['ao'], 'pulse,alsa');
    });

    test('low-power tuning trims the expensive rendering', () {
      final options =
          optionsFor(MpvPlatform.android, tuning: MpvTuning.cheapTvBox);
      expect(options['scale'], 'bilinear');
      expect(options['dither'], 'no');
      expect(options['deband'], 'no');
      expect(options['demuxer-max-bytes'], '${8 * 1024 * 1024}');
      expect(options['cache-secs'], '10');
    });

    test('desktop tuning keeps the larger cache', () {
      expect(optionsFor(MpvPlatform.windows)['demuxer-max-bytes'],
          '${32 * 1024 * 1024}');
    });

    test('formats as command line arguments', () {
      final formatted = formatAsCommandLine(const [MpvOption('vo', 'libmpv')]);
      expect(formatted, ['--vo=libmpv']);
    });
  });

  group('mpv commands', () {
    test('loadfile carries the resume position as a per-file option', () {
      final command = MpvCommand.loadFile(
        '/movies/a.mkv',
        startAt: const Duration(minutes: 1, seconds: 30),
      );
      expect(command.arguments,
          ['loadfile', '/movies/a.mkv', 'replace', '0', 'start=90.000']);
    });

    test('loadfile without a start position omits the options field', () {
      expect(MpvCommand.loadFile('/a.mkv').arguments,
          ['loadfile', '/a.mkv', 'replace', '0']);
    });

    test('seeks are always exact', () {
      expect(
        MpvCommand.seekAbsolute(const Duration(seconds: 12, milliseconds: 340))
            .arguments,
        ['seek', '12.340', 'absolute+exact'],
      );
      expect(
        MpvCommand.seekRelative(const Duration(seconds: -5)).arguments,
        ['seek', '-5.000', 'relative+exact'],
      );
    });

    test('a negative absolute seek clamps to zero', () {
      expect(MpvCommand.seekAbsolute(const Duration(seconds: -3)).arguments[1],
          '0.000');
    });

    test('subtitle commands', () {
      expect(MpvCommand.addSubtitle('/a.srt').arguments,
          ['sub-add', '/a.srt', 'auto']);
      expect(MpvCommand.addSubtitle('/a.srt', select: true).arguments.last,
          'select');
    });

    test('screenshot excludes the OSD', () {
      expect(MpvCommand.screenshotRaw().arguments, ['screenshot-raw', 'video']);
    });
  });

  group('mpv value parsing', () {
    test('parses seconds from every representation', () {
      expect(parseMpvSeconds(1.5), const Duration(milliseconds: 1500));
      expect(parseMpvSeconds('2.25'), const Duration(milliseconds: 2250));
      expect(parseMpvSeconds(null), isNull);
      expect(parseMpvSeconds(double.nan), isNull);
      expect(parseMpvSeconds('not a number'), isNull);
    });

    test('parses flags from every representation', () {
      expect(parseMpvFlag(true), isTrue);
      expect(parseMpvFlag('yes'), isTrue);
      expect(parseMpvFlag(1), isTrue);
      expect(parseMpvFlag('no'), isFalse);
      expect(parseMpvFlag(0), isFalse);
      expect(parseMpvFlag('maybe'), isNull);
    });

    test('formats seconds without locale involvement', () {
      expect(formatMpvSeconds(const Duration(milliseconds: 1234)), '1.234');
    });
  });

  group('track list parsing', () {
    const json = '''
[
 {"id":1,"type":"video","selected":true,"codec":"h264","demux-w":1920,"demux-h":1080},
 {"id":1,"type":"audio","lang":"jpn","title":"Japanese 5.1","selected":true,
  "codec":"eac3","demux-channel-count":6,"default":true},
 {"id":2,"type":"audio","lang":"en","codec":"aac","demux-channel-count":2},
 {"id":1,"type":"sub","lang":"eng","codec":"subrip","forced":true},
 {"id":2,"type":"sub","lang":"jpn","codec":"hdmv_pgs_subtitle","selected":true}
]
''';

    test('parses every track kind', () {
      final tracks = parseMpvTrackList(json);
      expect(tracks, hasLength(5));
      expect(tracks.where((t) => t.kind == MediaTrackKind.audio), hasLength(2));
      expect(
          tracks.where((t) => t.kind == MediaTrackKind.subtitle), hasLength(2));
    });

    test('normalises container language codes to ISO 639-3', () {
      final tracks = parseMpvTrackList(json);
      final english =
          tracks.firstWhere((t) => t.id == 2 && t.kind == MediaTrackKind.audio);
      expect(english.languageCode, 'eng', reason: '"en" must be normalised');
    });

    test('flags image-based subtitle tracks', () {
      final subtitles = parseMpvTrackList(json)
          .where((t) => t.kind == MediaTrackKind.subtitle)
          .toList();
      expect(subtitles.firstWhere((t) => t.id == 1).isImageBased, isFalse);
      expect(subtitles.firstWhere((t) => t.id == 2).isImageBased, isTrue,
          reason: 'PGS carries pictures, so it cannot be studied');
    });

    test('reads titles, defaults, forced flags and dimensions', () {
      final tracks = parseMpvTrackList(json);
      final audio = tracks.firstWhere((t) => t.kind == MediaTrackKind.audio);
      expect(audio.title, 'Japanese 5.1');
      expect(audio.isDefault, isTrue);
      expect(audio.channelCount, 6);

      final video = tracks.firstWhere((t) => t.kind == MediaTrackKind.video);
      expect(video.width, 1920);
      expect(video.height, 1080);

      expect(
          tracks.firstWhere((t) => t.kind == MediaTrackKind.subtitle).isForced,
          isTrue);
    });

    test('finds the selected track of each kind', () {
      expect(selectedTrackId(json, MediaTrackKind.audio), 1);
      expect(selectedTrackId(json, MediaTrackKind.subtitle), 2);
      expect(selectedTrackId('[]', MediaTrackKind.audio), isNull);
    });

    test('malformed JSON yields an empty list rather than throwing', () {
      expect(parseMpvTrackList('not json'), isEmpty);
      expect(parseMpvTrackList('{}'), isEmpty);
    });

    test('builds a usable menu label', () {
      final audio = parseMpvTrackList(json)
          .firstWhere((t) => t.kind == MediaTrackKind.audio);
      expect(audio.displayLabel, 'Japanese 5.1 (Japanese)');
    });
  });

  group('mpv state machine', () {
    test('starts idle', () {
      expect(MpvStateMachine().state.status, PlaybackStatus.idle);
    });

    test('follows a file through loading to playing', () {
      final machine = MpvStateMachine();

      expect(machine.apply(const MpvEvent(kind: MpvEventKind.startFile)).status,
          PlaybackStatus.loading);
      expect(
          machine.apply(const MpvEvent(kind: MpvEventKind.fileLoaded)).status,
          PlaybackStatus.paused);
      expect(machine.applyProperty(MpvProperty.pause, false).status,
          PlaybackStatus.playing);
    });

    test('reports buffering while paused for cache', () {
      final machine = MpvStateMachine()
        ..apply(const MpvEvent(kind: MpvEventKind.fileLoaded))
        ..applyProperty(MpvProperty.pause, false);

      expect(machine.applyProperty(MpvProperty.pausedForCache, true).status,
          PlaybackStatus.buffering);
      expect(machine.applyProperty(MpvProperty.pausedForCache, false).status,
          PlaybackStatus.playing);
    });

    test('reports ended when eof is reached with the file still open', () {
      final machine = MpvStateMachine()
        ..apply(const MpvEvent(kind: MpvEventKind.fileLoaded))
        ..applyProperty(MpvProperty.pause, false);

      expect(machine.applyProperty(MpvProperty.eofReached, true).status,
          PlaybackStatus.ended);
    });

    test('surfaces a playback error', () {
      final machine = MpvStateMachine()
        ..apply(const MpvEvent(kind: MpvEventKind.startFile));

      final state = machine.apply(const MpvEvent(
        kind: MpvEventKind.endFile,
        endFileReason: MpvEndFileReason.error,
        errorMessage: 'unrecognized file format',
      ));

      expect(state.status, PlaybackStatus.error);
      expect(state.errorMessage, 'unrecognized file format');
    });

    test('a new file clears the previous error', () {
      final machine = MpvStateMachine()
        ..apply(const MpvEvent(
          kind: MpvEventKind.endFile,
          endFileReason: MpvEndFileReason.error,
          errorMessage: 'boom',
        ));
      expect(machine.state.status, PlaybackStatus.error);

      machine.apply(const MpvEvent(kind: MpvEventKind.startFile));
      expect(machine.state.errorMessage, isNull);
      expect(machine.state.status, PlaybackStatus.loading);
    });

    test('tracks seeking so study modes can stand down', () {
      final machine = MpvStateMachine()
        ..apply(const MpvEvent(kind: MpvEventKind.fileLoaded));

      expect(machine.apply(const MpvEvent(kind: MpvEventKind.seek)).isSeeking,
          isTrue);
      expect(
        machine
            .apply(const MpvEvent(kind: MpvEventKind.playbackRestart))
            .isSeeking,
        isFalse,
      );
    });

    test('converts mpv volume percent to a 0..1 range', () {
      final machine = MpvStateMachine();
      expect(machine.applyProperty(MpvProperty.volume, 50).volume, 0.5);
      expect(machine.applyProperty(MpvProperty.volume, 130).volume, 1.0);
    });

    test('keeps the last position when time-pos goes null between files', () {
      final machine = MpvStateMachine()
        ..applyProperty(MpvProperty.timePos, 12.5);
      expect(machine.state.position, const Duration(milliseconds: 12500));

      machine.applyProperty(MpvProperty.timePos, null);
      expect(machine.state.position, const Duration(milliseconds: 12500));
    });

    test('reads tracks and selections from the track list', () {
      final machine = MpvStateMachine()
        ..applyProperty(
          MpvProperty.trackList,
          '[{"id":1,"type":"audio","lang":"jpn","selected":true},'
          '{"id":2,"type":"audio","lang":"eng"}]',
        );

      expect(machine.state.audioTracks, hasLength(2));
      expect(machine.state.activeAudioTrackId, 1);
    });

    test('a subtitle id of "no" clears the selection', () {
      final machine = MpvStateMachine()
        ..applyProperty(MpvProperty.subtitleId, 2);
      expect(machine.state.activeSubtitleTrackId, 2);

      machine.applyProperty(MpvProperty.subtitleId, 'no');
      expect(machine.state.activeSubtitleTrackId, isNull);
    });

    test('reports whether hardware decoding actually happened', () {
      final machine = MpvStateMachine();
      expect(
          machine
              .applyProperty(MpvProperty.hwdecCurrent, 'no')
              .isHardwareDecoding,
          isFalse);
      expect(
          machine
              .applyProperty(MpvProperty.hwdecCurrent, 'mediacodec')
              .isHardwareDecoding,
          isTrue);
    });

    test('computes progress', () {
      final machine = MpvStateMachine()
        ..applyProperty(MpvProperty.duration, 100.0)
        ..applyProperty(MpvProperty.timePos, 25.0);
      expect(machine.state.progress, 0.25);
      expect(PlaybackState.initial.progress, 0);
    });

    test('observes the properties the state machine consumes', () {
      // A property the machine handles but nobody observes would simply never
      // arrive.
      for (final property in MpvProperty.observed) {
        expect(property, isNotEmpty);
      }
      expect(MpvProperty.observed, contains(MpvProperty.timePos));
      expect(MpvProperty.observed, contains(MpvProperty.trackList));
      expect(MpvProperty.observed, contains(MpvProperty.pause));
    });
  });
}

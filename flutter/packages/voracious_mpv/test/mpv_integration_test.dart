/// Tests that call into a real libmpv.
///
/// Everything here needs an actual library on the machine, which is why it is
/// separate from `mpv_library_test.dart`: that suite covers the parts that can
/// be checked by reading the bindings, this one covers the parts where the
/// bindings can only be wrong at runtime. The distinction is not academic — the
/// first thing this suite found was a `gpu-api` value that no current Apple
/// build accepts, which stopped the engine from starting at all and which no
/// amount of pure-Dart testing could have shown.
///
/// The whole suite skips itself when no libmpv is present, so a machine or
/// container without one still reports green rather than failing to build.
library;

import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:voracious_mpv/voracious_mpv.dart';

/// The library, or null when this machine has none.
MpvLibrary? _openLibrary() {
  try {
    return MpvLibrary.open();
  } on Object {
    return null;
  }
}

final MpvLibrary? _library = _openLibrary();

/// `skip` takes a reason or null, so this doubles as the guard for every group.
final Object? _skip = _library == null
    ? 'no libmpv on this machine; install one (brew install mpv, '
        'apt install libmpv2) to run the integration suite'
    : null;

/// The configuration profile matching the machine the tests are running on.
MpvPlatform get _hostPlatform {
  if (Platform.isMacOS) return MpvPlatform.macos;
  if (Platform.isWindows) return MpvPlatform.windows;
  if (Platform.isLinux) return MpvPlatform.linux;
  if (Platform.isAndroid) return MpvPlatform.android;
  if (Platform.isIOS) return MpvPlatform.ios;
  throw UnsupportedError('unknown host platform');
}

/// Silences the engine. Playback still runs in real time; it just goes
/// nowhere, which is what a test wants.
const List<MpvOption> _headless = [
  MpvOption('ao', 'null'),
  MpvOption('vo', 'null'),
];

final String _fixture = () {
  final path = 'test/fixtures/multitrack.mkv';
  return File(path).existsSync() ? path : 'packages/voracious_mpv/$path';
}();

/// Polls until [condition] holds, so tests wait on the engine rather than on a
/// fixed delay that is either flaky or slow.
Future<bool> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return condition();
}

void main() {
  group('loading a real library', () {
    test('reports the client API version and where it came from', () {
      final library = _library!;
      expect(library.clientApiVersion, matches(RegExp(r'^\d+\.\d+$')));
      expect(library.describe(), contains(library.path));

      // The about screen has to name the library the user is actually running,
      // which is an LGPL obligation, not a nicety.
      expect(library.describe(), contains('libmpv'));
    });

    test('an explicit path that cannot be loaded does not fall back', () {
      // This is the case that matters for a shipped build: it passes the
      // libmpv it bundles, and quietly loading the machine's own copy instead
      // would mean running an unknown — quite possibly GPL — build.
      expect(
        () => MpvLibrary.open(explicitPath: '/nonexistent/libnothing.dylib'),
        throwsA(isA<MpvLibraryNotFoundException>()),
      );
    });

    test('a failed explicit load names only the path it was given', () {
      try {
        MpvLibrary.open(explicitPath: '/nonexistent/libnothing.dylib');
        fail('should have thrown');
      } on MpvLibraryNotFoundException catch (error) {
        expect(error.attempts.keys, ['/nonexistent/libnothing.dylib']);
      }
    });

    test('translates error codes into the library own messages', () {
      final bindings = _library!.bindings;
      // -7 is MPV_ERROR_OPTION_ERROR; the text comes from libmpv itself.
      expect(bindings.describeError(0), isNotEmpty);
      expect(bindings.describeError(-7), isNotEmpty);
      expect(bindings.describeError(-7), isNot(bindings.describeError(0)));
    });
  }, skip: _skip);

  group('the shipped configuration', () {
    test('every option this platform ships is accepted by the build', () {
      // The regression test for `gpu-api=opengl`, which current Apple builds
      // reject outright. MpvPlayer.create treats a rejected option as fatal,
      // so one bad value here is the difference between a working player and
      // one that throws before it ever initialises. Each option goes onto its
      // own handle so a single failure cannot mask the ones after it.
      //
      // Optional options are exempt from *that name existing* — they are the
      // built-in-script switches, added across several mpv releases — but not
      // from having a usable value: a build that knows the option and refuses
      // the value is still a configuration bug.
      final bindings = _library!.bindings;
      final rejected = <String>[];

      for (final option in MpvConfiguration.forPlatform(_hostPlatform)) {
        final handle = bindings.create();
        final name = option.name.toNativeUtf8();
        final value = option.value.toNativeUtf8();
        try {
          final code = bindings.setOptionString(handle, name, value);
          if (code == MpvErrorCode.optionNotFound && option.optional) continue;
          if (code < 0) {
            rejected.add('${option.name}=${option.value} '
                '(${bindings.describeError(code)})');
          }
        } finally {
          calloc
            ..free(name)
            ..free(value);
          bindings.terminateDestroy(handle);
        }
      }

      expect(
        rejected,
        isEmpty,
        reason: 'libmpv ${_library!.clientApiVersion} rejected options in the '
            '${_hostPlatform.name} configuration: ${rejected.join(', ')}',
      );
    });

    test('the error code an unknown option reports is the one we skip on', () {
      // MpvOption.optional is only safe because an unknown *name* is
      // distinguishable from a bad value, and that distinction is a bare
      // integer copied out of client.h. If it is wrong, optional options stop
      // being skipped and start being fatal — on someone else's older
      // library, never here.
      final bindings = _library!.bindings;
      final handle = bindings.create();
      final name = 'voracious-no-such-option'.toNativeUtf8();
      final value = 'no'.toNativeUtf8();
      try {
        expect(
          bindings.setOptionString(handle, name, value),
          MpvErrorCode.optionNotFound,
        );
      } finally {
        calloc
          ..free(name)
          ..free(value);
        bindings.terminateDestroy(handle);
      }
    });

    test('no built-in script switch is left at its default', () async {
      // What the option list asks for and what the library did are different
      // questions, and this one is invisible from the app: a script that
      // loads anyway costs a thread and a Lua state and shows no symptom.
      // Reading the flags back after initialisation is the closest thing to
      // proof available through the client API. A build too old to have one
      // of these reports null, which is the documented outcome rather than a
      // failure — see MpvOption.optional.
      final player = await MpvPlayer.create(platform: _hostPlatform);
      addTearDown(player.dispose);

      final stillLoading = <String>[];
      for (final option in MpvConfiguration.forPlatform(_hostPlatform)
          .where((option) => option.optional)) {
        final actual = player.readProperty(option.name);
        if (actual != null && actual != 'no') stillLoading.add(option.name);
      }

      expect(stillLoading, isEmpty);
    });

    test('the low-power profile is accepted too', () {
      final bindings = _library!.bindings;
      final rejected = <String>[];

      for (final option in MpvConfiguration.forPlatform(
        _hostPlatform,
        tuning: MpvTuning.cheapTvBox,
      )) {
        final handle = bindings.create();
        final name = option.name.toNativeUtf8();
        final value = option.value.toNativeUtf8();
        try {
          if (bindings.setOptionString(handle, name, value) < 0) {
            rejected.add('${option.name}=${option.value}');
          }
        } finally {
          calloc
            ..free(name)
            ..free(value);
          bindings.terminateDestroy(handle);
        }
      }

      expect(rejected, isEmpty);
    });

    test('creates a player and settles on the configured decoder and output',
        () async {
      final player = await MpvPlayer.create(platform: _hostPlatform);
      addTearDown(player.dispose);

      expect(player.readProperty('mpv-version'), contains('mpv'));
      expect(player.state.status, PlaybackStatus.idle);

      // What the options asked for is not necessarily what the build settled
      // on, and the difference is worth seeing in a test rather than in a bug
      // report about a slideshow on a TV box.
      if (_hostPlatform == MpvPlatform.macos) {
        expect(player.readProperty('hwdec'), 'videotoolbox');
        expect(player.readProperty('ao'), 'coreaudio');
      }
      expect(player.readProperty('vo'), 'libmpv');
    });

    test('rejects a configuration an LGPL build could not honour', () async {
      // The startup check, exercised against the real library rather than in
      // isolation: an option naming a GPL-only component must fail before any
      // handle is created.
      await expectLater(
        MpvPlayer.create(
          platform: _hostPlatform,
          extraOptions: const [MpvOption('ao', 'jack')],
        ),
        throwsA(isA<StateError>()),
      );
    });
  }, skip: _skip);

  group('playback against a real file', () {
    late MpvPlayer player;

    setUp(() async {
      player = await MpvPlayer.create(
        platform: _hostPlatform,
        extraOptions: _headless,
      );
    });

    tearDown(() => player.dispose());

    test('the fixture is present', () {
      expect(File(_fixture).existsSync(), isTrue,
          reason: 'missing test fixture at $_fixture');
    });

    test('opens a file and reports its duration and dimensions', () async {
      await player.open(_fixture);
      await _waitUntil(() => player.state.duration > Duration.zero);

      expect(player.state.duration.inMilliseconds, closeTo(3000, 400));
      expect(player.state.videoWidth, 160);
      expect(player.state.videoHeight, 120);
      expect(player.state.hasMedia, isTrue);
    });

    test('parses the track list the engine actually reports', () async {
      // MpvTrackList is tested against captured JSON elsewhere; this is the
      // test that the JSON it parses is the shape libmpv really emits.
      await player.open(_fixture);
      await _waitUntil(() => player.state.tracks.length >= 4);

      final audio = player.state.audioTracks;
      final subtitles = player.state.subtitleTracks;

      expect(player.state.videoTracks, hasLength(1));
      expect(audio, hasLength(2));
      expect(subtitles, hasLength(1));

      expect(audio.map((t) => t.languageCode), ['jpn', 'eng']);
      expect(audio.map((t) => t.id), [1, 2]);
    });

    test('position advances while playing', () async {
      await player.open(_fixture);
      await _waitUntil(() => player.state.duration > Duration.zero);

      final start = player.state.position;
      final moved = await _waitUntil(
        () => player.state.position > start + const Duration(milliseconds: 200),
      );

      expect(moved, isTrue,
          reason: 'position never advanced; the event pump is not delivering');
    });

    test('pauses and resumes', () async {
      await player.open(_fixture);
      await _waitUntil(() => player.state.duration > Duration.zero);

      await player.pause();
      expect(await _waitUntil(() => player.state.isPaused), isTrue);

      final held = player.state.position;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.state.position, held);

      await player.play();
      expect(await _waitUntil(() => player.state.isPlaying), isTrue);
    });

    test('seeks to an absolute position', () async {
      await player.open(_fixture);
      await _waitUntil(() => player.state.duration > Duration.zero);
      await player.pause();
      await _waitUntil(() => player.state.isPaused);

      await player.seek(const Duration(milliseconds: 2000));
      final landed = await _waitUntil(
        () =>
            (player.state.position - const Duration(milliseconds: 2000)).abs() <
            const Duration(milliseconds: 400),
      );

      expect(landed, isTrue,
          reason: 'seek landed at ${player.state.position}, not near 2s');
    });

    test('speed, volume and mute round-trip through the engine', () async {
      await player.open(_fixture);
      await _waitUntil(() => player.state.duration > Duration.zero);

      await player.setSpeed(1.5);
      expect(await _waitUntil(() => player.state.speed == 1.5), isTrue);

      await player.setVolume(0.5);
      expect(await _waitUntil(() => player.state.volume == 0.5), isTrue,
          reason: 'volume was ${player.state.volume}');

      await player.setMuted(true);
      expect(await _waitUntil(() => player.state.isMuted), isTrue);
    });

    test('selects an audio track by id', () async {
      await player.open(_fixture);
      await _waitUntil(() => player.state.tracks.length >= 4);

      await player.setAudioTrack(2);
      expect(
          await _waitUntil(() => player.state.activeAudioTrackId == 2), isTrue);

      await player.setAudioTrack(1);
      expect(
          await _waitUntil(() => player.state.activeAudioTrackId == 1), isTrue);
    });

    test('an invalid speed is refused before it reaches the engine', () async {
      await expectLater(() => player.setSpeed(0), throwsArgumentError);
    });

    test('reports the end of the file', () async {
      await player.open(_fixture);
      await _waitUntil(() => player.state.duration > Duration.zero);

      await player.setSpeed(4);
      await player.seek(const Duration(milliseconds: 2500));

      final ended = await _waitUntil(
        () => player.state.status == PlaybackStatus.ended,
        timeout: const Duration(seconds: 15),
      );

      expect(ended, isTrue, reason: 'status stuck at ${player.state.status}');
    });

    test('a study session drives the real engine', () async {
      // The point of the seam: StudySession is written against an interface,
      // and here that interface is a live libmpv rather than a fake.
      await player.open(_fixture);
      await _waitUntil(() => player.state.duration > Duration.zero);

      final session = StudySession(
        playback: MediaPlayerStudyController(player),
        tracks: [
          StudyTrack(
            id: 'jpn',
            cues: CueIndex([
              StudyCue(
                id: '1',
                begin: const Duration(milliseconds: 500),
                end: const Duration(milliseconds: 1500),
                text: AnnotatedText.plain('first line'),
              ),
              StudyCue(
                id: '2',
                begin: const Duration(milliseconds: 2000),
                end: const Duration(milliseconds: 3000),
                text: AnnotatedText.plain('second line'),
              ),
            ]),
          ),
        ],
        mode: SubtitleMode.manual,
      );
      addTearDown(session.dispose);

      await session.goToNextCue();
      final arrived = await _waitUntil(
        () => player.state.position >= const Duration(milliseconds: 400),
      );
      expect(arrived, isTrue);

      await session.togglePause();
      expect(await _waitUntil(() => player.state.isPaused), isTrue);
    });
  }, skip: _skip);

  group('lifecycle', () {
    test('opening and disposing repeatedly does not race the event pump',
        () async {
      // This is the "user closes a video" path, and it used to abort the
      // process perhaps one time in four: dispose killed the pump isolate and
      // destroyed the handle without waiting, while the pump was still inside
      // mpv_wait_event. Being a race, one iteration proves nothing, so this
      // does it enough times that a regression is not merely likely to show
      // up but reliable.
      for (var i = 0; i < 8; i++) {
        final player = await MpvPlayer.create(
          platform: _hostPlatform,
          extraOptions: _headless,
        );
        await player.open(_fixture);
        await _waitUntil(() => player.state.duration > Duration.zero);
        await player.dispose();
      }
    });

    test('dispose is idempotent and the player is unusable afterwards',
        () async {
      final player = await MpvPlayer.create(
        platform: _hostPlatform,
        extraOptions: _headless,
      );

      await player.dispose();
      await player.dispose();

      expect(() => player.readProperty('mpv-version'), throwsStateError);
    });
  }, skip: _skip);
}

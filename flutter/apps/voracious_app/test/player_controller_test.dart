/// End-to-end tests of the app's controllers against a real engine.
///
/// This is the seam the whole architecture is arranged around, so it is worth
/// testing with nothing faked: a real folder scanned off disk, real subtitle
/// files decoded and analysed, and a real libmpv playing a real file, with
/// StudySession deciding what is on screen throughout.
///
/// Skips itself when no libmpv is installed.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voracious_app/src/state/library_controller.dart';
import 'package:voracious_app/src/state/player_controller.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:voracious_mpv/voracious_mpv.dart';

bool get _hasLibmpv {
  try {
    MpvLibrary.open();
    return true;
  } on Object {
    return false;
  }
}

final Object? _skip =
    _hasLibmpv ? null : 'no libmpv on this machine; install one to run these';

String get _fixtures => p.join(Directory.current.path, 'test', 'fixtures');

Future<bool> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  return condition();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LibraryController', () {
    late LibraryController controller;

    setUp(() async {
      controller = LibraryController(
        profiles: ProfileRepository(InMemoryKeyValueStore()),
      );
      await controller.load();
    });

    tearDown(() => controller.dispose());

    test('scans a folder into titles with their subtitles', () async {
      await controller.addCollection(_fixtures, name: 'Fixtures');

      expect(controller.status, ScanStatus.ready);
      expect(controller.index.videos, hasLength(1));

      final video = controller.index.videos.single;
      // Both sidecar files belong to the video, matched by name.
      expect(video.subtitleFiles, hasLength(2));
      expect(
        video.subtitleFiles.map((s) => s.languageCode).toSet(),
        {'jpn', 'eng'},
      );
      expect(video.hasStudyableSubtitles, isTrue);
    });

    test('remembers the collection in the profile', () async {
      await controller.addCollection(_fixtures, name: 'Fixtures');
      expect(controller.collections, hasLength(1));

      // Adding the same folder twice selects it rather than duplicating it.
      await controller.addCollection(_fixtures, name: 'Fixtures');
      expect(controller.collections, hasLength(1));
    });

    test('round-trips a resume position', () async {
      await controller.addCollection(_fixtures, name: 'Fixtures');
      final video = controller.index.videos.single;

      await controller.recordPosition(video.id, const Duration(seconds: 42));
      expect(
        await controller.resumePositionFor(video.id),
        const Duration(seconds: 42),
      );
    });
  });

  group('PlayerController against a real engine', () {
    late LibraryController library;
    late PlayerController player;

    setUp(() async {
      library = LibraryController(
        profiles: ProfileRepository(InMemoryKeyValueStore()),
      );
      await library.load();
      await library.addCollection(_fixtures, name: 'Fixtures');
    });

    tearDown(() async {
      await player.dispose();
      library.dispose();
    });

    Future<void> startPlayer({
      Preferences preferences = const Preferences(),
    }) async {
      player = PlayerController(
        video: library.index.videos.single,
        preferences: preferences,
        onPositionRecorded: (_) {},
      );
      await player.start();
    }

    test('starts the engine, loads both tracks and plays', () async {
      await startPlayer();

      expect(player.stage, PlayerLoadStage.ready, reason: player.error ?? '');
      expect(player.engineDescription, contains('libmpv'));

      // Loaded, decoded, language-detected and analysed, off real files.
      expect(player.tracks, hasLength(2));
      expect(player.tracks.map((t) => t.languageCode),
          containsAll(['jpn', 'eng']));

      expect(await _waitUntil(() => player.playback.duration > Duration.zero),
          isTrue);
      expect(
        await _waitUntil(
          () => player.playback.position > const Duration(milliseconds: 300),
        ),
        isTrue,
        reason: 'playback never advanced',
      );
    });

    test('orders tracks by the language being studied', () async {
      // The first track is the one the study modes take their timing from, so
      // the preference has to decide it rather than the scan order.
      await startPlayer(
        preferences: const Preferences(subtitleOrder: ['eng', 'jpn']),
      );

      expect(player.tracks.first.languageCode, 'eng');
      expect(player.snapshot!.tracks.first.track.languageCode, 'eng');
    });

    test('shows the line that is on screen at the current time', () async {
      await startPlayer();
      await _waitUntil(() => player.playback.duration > Duration.zero);

      await player.seek(const Duration(milliseconds: 700));

      final showing = await _waitUntil(
        () => player.snapshot?.primaryCue != null,
      );
      expect(showing, isTrue);
      expect(
        player.snapshot!.primaryCue!.text.text,
        anyOf('これはテストです', 'This is a test'),
      );
    });

    test('reading practice pauses when it reaches a new line', () async {
      // The mode's whole behaviour, driven by real position updates from the
      // engine rather than by a test feeding them in.
      await startPlayer(
        preferences: const Preferences(subtitleMode: SubtitleMode.read),
      );
      await _waitUntil(() => player.playback.duration > Duration.zero);

      final paused = await _waitUntil(() => player.playback.isPaused);
      expect(paused, isTrue,
          reason: 'reading practice never paused on a line start');

      // The line that caused the pause is the one left on screen.
      expect(player.snapshot!.primaryCue, isNotNull);

      // And continuing resumes.
      await player.continueStudy();
      expect(await _waitUntil(() => player.playback.isPlaying), isTrue);
    });

    test('manual mode toggles one track at a time', () async {
      await startPlayer();
      await _waitUntil(() => player.playback.duration > Duration.zero);
      await player.seek(const Duration(milliseconds: 700));
      await _waitUntil(() => player.snapshot?.primaryCue != null);

      expect(player.snapshot!.tracks.every((t) => !t.isHidden), isTrue);

      player.toggleTrackHidden(1);
      expect(player.snapshot!.tracks[1].isHidden, isTrue);
      expect(player.snapshot!.tracks[0].isHidden, isFalse);

      player.revealAll();
      expect(player.snapshot!.tracks.every((t) => !t.isHidden), isTrue);
    });

    test('looping the current line sets a padded A-B loop', () async {
      await startPlayer();
      await _waitUntil(() => player.playback.duration > Duration.zero);
      await player.seek(const Duration(milliseconds: 700));
      await _waitUntil(() => player.snapshot?.primaryCue != null);

      player.loopCurrentCue();
      final loop = player.loop;
      expect(loop, isNotNull);
      expect(loop!.isValid, isTrue);
      // Padded either side, so the line is not clipped on the way in.
      expect(loop.begin, lessThan(const Duration(milliseconds: 500)));

      player.clearLoop();
      expect(player.loop, isNull);
    });

    test('resumes from a stored position', () async {
      player = PlayerController(
        video: library.index.videos.single,
        preferences: const Preferences(),
        resumeFrom: const Duration(milliseconds: 1800),
        onPositionRecorded: (_) {},
      );
      await player.start();

      final resumed = await _waitUntil(
        () => player.playback.position >= const Duration(milliseconds: 1500),
      );
      expect(resumed, isTrue,
          reason: 'started at ${player.playback.position}, not near 1.8s');
    });
  }, skip: _skip);
}

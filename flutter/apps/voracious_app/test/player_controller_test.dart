/// End-to-end tests of the app's controllers against a real engine.
///
/// This is the seam the whole architecture is arranged around, so it is worth
/// testing with nothing faked: a real folder scanned off disk, real subtitle
/// files decoded and analysed, and a real libmpv playing a real file, with
/// StudySession deciding what is on screen throughout.
///
/// Skips itself when no libmpv is installed.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voracious_app/src/engine/embedded_subtitle_cache.dart';
import 'package:voracious_app/src/state/library_controller.dart';
import 'package:voracious_app/src/state/player_controller.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:voracious_core/voracious_core_io.dart';
import 'package:media_kit/media_kit.dart';

/// media_kit bundles libmpv into app builds, but `flutter test` runs on the
/// host VM and needs a system copy (`brew install mpv`).
final String? _libmpv = () {
  for (final name in const [
    'libmpv.dylib',
    '/opt/homebrew/lib/libmpv.dylib',
    '/usr/local/lib/libmpv.dylib',
    'libmpv.so.2',
    'libmpv-2.dll',
  ]) {
    try {
      DynamicLibrary.open(name);
      return name;
    } on Object {
      continue;
    }
  }
  return null;
}();

final Object? _skip = _libmpv != null
    ? null
    : 'no libmpv on this machine; install one to run these';

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

/// Leaves embedded tracks out, so the engine tests below see only the two
/// sidecar files they were written around.
class _NoEmbeddedSubtitles extends EmbeddedSubtitleCache {
  @override
  Future<List<SubtitleFileRef>> refsFor(VideoEntry video) async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Throws without a libmpv, so only when the engine tests will run.
  if (_libmpv case final path?) MediaKit.ensureInitialized(libmpv: path);

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

  group('EmbeddedSubtitleCache', () {
    late Directory cacheDir;
    late EmbeddedSubtitleCache cache;

    setUp(() async {
      cacheDir = await Directory.systemTemp.createTemp('voracious_subs');
      cache = EmbeddedSubtitleCache(root: () async => cacheDir);
    });

    tearDown(() => cacheDir.delete(recursive: true));

    VideoEntry entryFor(String fileName) => VideoEntry(
          id: fileName,
          name: p.basenameWithoutExtension(fileName),
          path: p.join(_fixtures, fileName),
          subtitleFiles: const [],
        );

    test('extracts the text track embedded in an MKV', () async {
      final refs = await cache.refsFor(entryFor('Sample.Episode.S01E02.mkv'));

      expect(refs, hasLength(1));
      final ref = refs.single;
      expect(ref.id, 'Sample.Episode.S01E02.mkv#track4');
      expect(ref.format, SubtitleFormat.srt);
      expect(ref.languageCode, 'jpn');
      expect(File(ref.path).existsSync(), isTrue);

      // Loads like any sidecar file.
      final track = await SubtitleTrackLoader(
        fileSystem: const LocalFileSystem(),
        analyzer: TextAnalyzer(),
      ).load(ref);
      expect(track.cues.length, 2);
      expect(track.languageCode, 'jpn');
    });

    test('reuses the cache on the next play', () async {
      final video = entryFor('Sample.Episode.S01E02.mkv');
      final first = await cache.refsFor(video);
      final manifest = cacheDir
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere((f) => p.basename(f.path) == 'manifest.json');
      final writtenAt = manifest.lastModifiedSync();

      final second = await cache.refsFor(video);
      expect(second.map((r) => r.path), first.map((r) => r.path));
      expect(manifest.lastModifiedSync(), writtenAt);
    });

    test('returns nothing for a file that is not Matroska', () async {
      expect(await cache.refsFor(entryFor('Sample.Episode.S01E02.en.srt')),
          isEmpty);
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
        embeddedSubtitles: _NoEmbeddedSubtitles(),
      );
      await player.start();
    }

    test('starts the engine, loads both tracks and plays', () async {
      await startPlayer();

      expect(player.stage, PlayerLoadStage.ready, reason: player.error ?? '');
      expect(player.engineDescription, contains('media_kit'));

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

    test('loads embedded tracks alongside sidecar files', () async {
      final cacheDir = await Directory.systemTemp.createTemp('voracious_subs');
      addTearDown(() => cacheDir.delete(recursive: true));
      player = PlayerController(
        video: library.index.videos.single,
        preferences: const Preferences(),
        onPositionRecorded: (_) {},
        embeddedSubtitles: EmbeddedSubtitleCache(root: () async => cacheDir),
      );
      await player.start();

      expect(player.embeddedSubtitleError, isNull);
      expect(player.tracks, hasLength(3));
      expect(player.tracks.map((t) => t.id), contains(endsWith('#track4')));
    });

    test('resumes from a stored position', () async {
      player = PlayerController(
        video: library.index.videos.single,
        preferences: const Preferences(),
        resumeFrom: const Duration(milliseconds: 1800),
        onPositionRecorded: (_) {},
        embeddedSubtitles: _NoEmbeddedSubtitles(),
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

import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

Duration ms(int value) => Duration(milliseconds: value);

StudyCue cue(int beginMs, int endMs, String text, {String? id}) => StudyCue(
      id: id,
      begin: ms(beginMs),
      end: ms(endMs),
      text: AnnotatedText.plain(text),
    );

/// Records what the session asks the player to do.
class FakePlayback implements StudyPlaybackController {
  FakePlayback({this.position = Duration.zero, this.isPlaying = false});

  @override
  Duration position;

  @override
  bool isPlaying;

  final List<String> calls = [];

  @override
  Future<void> play() async {
    calls.add('play');
    isPlaying = true;
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    isPlaying = false;
  }

  @override
  Future<void> seek(Duration target) async {
    calls.add('seek:${target.inMilliseconds}');
    position = target;
  }
}

/// Feeds positions to the session the way the engine's position stream would.
Future<void> advance(
  StudySession session,
  FakePlayback playback,
  List<int> positionsMs,
) async {
  for (final value in positionsMs) {
    playback.position = ms(value);
    await session.onPositionChanged(ms(value), isPlaying: playback.isPlaying);
  }
}

void main() {
  late FakePlayback playback;

  final japanese = StudyTrack(
    id: 'ja',
    languageCode: 'jpn',
    cues: CueIndex([
      cue(1000, 3000, '一行目', id: 'ja1'),
      cue(4000, 6000, '二行目', id: 'ja2'),
      cue(7000, 9000, '三行目', id: 'ja3'),
    ]),
  );

  final english = StudyTrack(
    id: 'en',
    languageCode: 'eng',
    cues: CueIndex([
      cue(1000, 3000, 'Line one', id: 'en1'),
      cue(4000, 6000, 'Line two', id: 'en2'),
    ]),
  );

  setUp(() => playback = FakePlayback());

  group('display', () {
    test('shows the line at the current time on every track', () async {
      final session = StudySession(
        playback: playback,
        tracks: [japanese, english],
      );
      await advance(session, playback, [1500]);

      final snapshot = session.snapshot;
      expect(snapshot.tracks, hasLength(2));
      expect(snapshot.tracks[0].cue?.text.text, '一行目');
      expect(snapshot.tracks[1].cue?.text.text, 'Line one');
      expect(snapshot.primaryCue?.id, 'ja1');
    });

    test('shows nothing in a gap', () async {
      final session = StudySession(playback: playback, tracks: [japanese]);
      await advance(session, playback, [3500]);
      expect(session.snapshot.tracks.single.cue, isNull);
      expect(session.snapshot.hasAnythingToShow, isFalse);
    });

    test('emits a snapshot on every change', () async {
      final session = StudySession(playback: playback, tracks: [japanese]);
      final snapshots = <StudySessionSnapshot>[];
      session.snapshots.listen(snapshots.add);

      await advance(session, playback, [1500, 2000]);
      await Future<void>.delayed(Duration.zero);

      expect(snapshots, hasLength(2));
      addTearDown(session.dispose);
    });
  });

  group('manual mode', () {
    test('never pauses on its own', () async {
      final session = StudySession(
        playback: playback,
        tracks: [japanese],
        mode: SubtitleMode.manual,
      );
      await playback.play();
      playback.calls.clear();

      await advance(session, playback, [1000, 2000, 2900, 3000, 4000]);
      expect(playback.calls, isEmpty);
    });

    test('shows all tracks by default', () async {
      final session = StudySession(
        playback: playback,
        tracks: [japanese, english],
        mode: SubtitleMode.manual,
      );
      await advance(session, playback, [1500]);
      expect(session.snapshot.tracks.every((t) => !t.isHidden), isTrue);
    });

    test('number keys toggle individual tracks', () async {
      final session = StudySession(
        playback: playback,
        tracks: [japanese, english],
        mode: SubtitleMode.manual,
      );
      await advance(session, playback, [1500]);

      session.toggleTrackHidden(1);
      expect(session.snapshot.tracks[0].isHidden, isFalse);
      expect(session.snapshot.tracks[1].isHidden, isTrue);

      session.toggleTrackHidden(1);
      expect(session.snapshot.tracks[1].isHidden, isFalse);
    });

    test('ignores out-of-range track indices', () async {
      final session = StudySession(playback: playback, tracks: [japanese]);
      session.toggleTrackHidden(9);
      expect(session.snapshot.tracks.single.isHidden, isFalse);
    });

    test('continue simply resumes', () async {
      final session = StudySession(playback: playback, tracks: [japanese]);
      await session.continueStudy();
      expect(playback.calls, ['play']);
    });
  });

  group('listening practice', () {
    late StudySession session;

    setUp(() {
      session = StudySession(
        playback: playback,
        tracks: [japanese, english],
        mode: SubtitleMode.listen,
      );
    });

    test('hides every track until revealed', () async {
      await advance(session, playback, [1500]);
      expect(session.snapshot.tracks.every((t) => t.isHidden), isTrue);
      expect(session.snapshot.revealedTrackCount, 0);
    });

    test('pauses shortly before the line ends', () async {
      await playback.play();
      playback.calls.clear();

      // The line ends at 3000ms and the default lead is 300ms.
      await advance(session, playback, [1500, 2600]);
      expect(playback.calls, isEmpty);

      await advance(session, playback, [2750]);
      expect(playback.calls, ['pause']);
      expect(session.snapshot.isFrozen, isTrue);
    });

    test('keeps the line on screen while paused', () async {
      await playback.play();
      await advance(session, playback, [1500, 2750, 3500]);

      // Time has moved past the end of the line, but the display is held.
      expect(session.snapshot.primaryCue?.id, 'ja1');
      expect(session.snapshot.displayTime, ms(1500));
    });

    test('does not pause twice for the same line', () async {
      await playback.play();
      await advance(session, playback, [1500, 2750]);
      playback.calls.clear();

      await advance(session, playback, [2800, 2900]);
      expect(playback.calls, isEmpty);
    });

    test('continue reveals one track at a time, then resumes', () async {
      await playback.play();
      await advance(session, playback, [1500, 2750]);

      await session.continueStudy();
      expect(session.snapshot.revealedTrackCount, 1);
      expect(session.snapshot.tracks[0].isHidden, isFalse);
      expect(session.snapshot.tracks[1].isHidden, isTrue);

      await session.continueStudy();
      expect(session.snapshot.tracks.every((t) => !t.isHidden), isTrue);

      playback.calls.clear();
      await session.continueStudy();
      expect(playback.calls, ['play']);
      expect(session.snapshot.isFrozen, isFalse);
    });

    test('revealing does not pause, unlike quick check', () async {
      await playback.play();
      await advance(session, playback, [1500, 2750]);
      playback.calls.clear();

      await session.continueStudy();
      expect(playback.calls, isEmpty);
    });

    test('moving to a new line re-hides the tracks', () async {
      await advance(session, playback, [1500]);
      await session.continueStudy();
      expect(session.snapshot.revealedTrackCount, 1);

      await advance(session, playback, [4500]);
      expect(session.snapshot.revealedTrackCount, 0);
      expect(session.snapshot.tracks.every((t) => t.isHidden), isTrue);
    });

    test('does not pause while the engine is not playing', () async {
      // Position updates arrive during a seek too; auto-pause must stand down.
      await advance(session, playback, [1500, 2750]);
      expect(playback.calls, isEmpty);
    });

    test('does not pause when a seek lands past the trigger point', () async {
      await playback.play();
      await advance(session, playback, [1500]);
      session.onSeekStarted();
      playback.calls.clear();

      // Jumping straight past the trigger is not "crossing" it.
      await advance(session, playback, [2900]);
      expect(playback.calls, isEmpty);
    });
  });

  group('quick check', () {
    late StudySession session;

    setUp(() {
      session = StudySession(
        playback: playback,
        tracks: [japanese, english],
        mode: SubtitleMode.quickCheck,
      );
    });

    test('never pauses on its own', () async {
      await playback.play();
      playback.calls.clear();
      await advance(session, playback, [1500, 2750, 3000, 4500]);
      expect(playback.calls, isEmpty);
    });

    test('revealing pauses the video', () async {
      await playback.play();
      await advance(session, playback, [1500]);
      playback.calls.clear();

      await session.continueStudy();
      expect(playback.calls, ['pause']);
      expect(session.snapshot.revealedTrackCount, 1);
    });

    test('continuing past the last track resumes', () async {
      await advance(session, playback, [1500]);
      await session.continueStudy();
      await session.continueStudy();
      playback.calls.clear();

      await session.continueStudy();
      expect(playback.calls, ['play']);
    });
  });

  group('reading practice', () {
    late StudySession session;

    setUp(() {
      session = StudySession(
        playback: playback,
        tracks: [japanese],
        mode: SubtitleMode.read,
      );
    });

    test('pauses when a new line starts', () async {
      await playback.play();
      await advance(session, playback, [500]);
      playback.calls.clear();

      await advance(session, playback, [1200]);
      expect(playback.calls, ['pause']);
      expect(session.snapshot.primaryCue?.id, 'ja1');
    });

    test('shows the line rather than hiding it', () async {
      await playback.play();
      await advance(session, playback, [500, 1200]);
      expect(session.snapshot.tracks.single.isHidden, isFalse);
    });

    test('continue resumes and does not immediately re-pause', () async {
      await playback.play();
      await advance(session, playback, [500, 1200]);

      playback.calls.clear();
      await session.continueStudy();
      expect(playback.calls, ['play']);

      await advance(session, playback, [1500, 2000]);
      expect(playback.calls, ['play'], reason: 'still the same line');
    });

    test('pauses again at the next line', () async {
      await playback.play();
      await advance(session, playback, [500, 1200]);
      await session.continueStudy();
      playback.calls.clear();

      await advance(session, playback, [2000, 3500, 4200]);
      expect(playback.calls, ['pause']);
      expect(session.snapshot.primaryCue?.id, 'ja2');
    });
  });

  group('navigation', () {
    test('replay seeks to the start of the current line and plays', () async {
      final session = StudySession(playback: playback, tracks: [japanese]);
      await advance(session, playback, [2000]);
      playback.calls.clear();

      await session.replayCurrentCue();
      expect(playback.calls, ['seek:1050', 'play']);
    });

    test('replay does nothing in a gap', () async {
      final session = StudySession(playback: playback, tracks: [japanese]);
      await advance(session, playback, [3500]);
      playback.calls.clear();

      await session.replayCurrentCue();
      expect(playback.calls, isEmpty);
    });

    test('previous jumps to the line before', () async {
      final session = StudySession(playback: playback, tracks: [japanese]);
      await advance(session, playback, [4500]);
      playback.calls.clear();

      await session.goToPreviousCue();
      expect(playback.calls, ['seek:1050']);
    });

    test('next jumps to the following line', () async {
      final session = StudySession(playback: playback, tracks: [japanese]);
      await advance(session, playback, [1500]);
      playback.calls.clear();

      await session.goToNextCue();
      expect(playback.calls, ['seek:4050']);
    });

    test('next in reading mode pauses on arrival', () async {
      final session = StudySession(
        playback: playback,
        tracks: [japanese],
        mode: SubtitleMode.read,
      );
      await playback.play();
      await advance(session, playback, [1500]);
      playback.calls.clear();

      await session.goToNextCue();
      expect(playback.calls, ['seek:4050', 'pause']);
    });

    test('with no subtitles, navigation steps by a few seconds', () async {
      final session = StudySession(playback: playback);
      playback.position = ms(10000);

      await session.goToPreviousCue();
      expect(playback.calls, ['seek:7000']);

      playback.calls.clear();
      await session.goToNextCue();
      expect(playback.calls, ['seek:10000']);
    });

    test('seeking back before the start clamps at zero', () async {
      final session = StudySession(playback: playback);
      playback.position = ms(1000);
      await session.goToPreviousCue();
      expect(playback.calls, ['seek:0']);
    });

    test('navigation releases a held display', () async {
      final session = StudySession(
        playback: playback,
        tracks: [japanese],
        mode: SubtitleMode.listen,
      );
      await playback.play();
      await advance(session, playback, [1500, 2750]);
      expect(session.snapshot.isFrozen, isTrue);

      await session.goToNextCue();
      expect(session.snapshot.isFrozen, isFalse);
    });

    test('toggle pause flips playback and unfreezes', () async {
      final session = StudySession(
        playback: playback,
        tracks: [japanese],
        mode: SubtitleMode.listen,
      );
      await playback.play();
      await advance(session, playback, [1500, 2750]);

      playback.calls.clear();
      await session.togglePause();
      expect(playback.calls, ['play']);
      expect(session.snapshot.isFrozen, isFalse);

      playback.calls.clear();
      await session.togglePause();
      expect(playback.calls, ['pause']);
    });
  });

  group('A-B loop', () {
    test('seeks back to the start when the end is reached', () async {
      final session = StudySession(playback: playback, tracks: [japanese])
        ..setLoop(AbLoop(begin: ms(1000), end: ms(3000)));

      await playback.play();
      await advance(session, playback, [2000]);
      playback.calls.clear();

      await advance(session, playback, [3100]);
      expect(playback.calls, ['seek:1000']);
    });

    test('builds a padded loop from the current line', () async {
      final session = StudySession(playback: playback, tracks: [japanese]);
      await advance(session, playback, [2000]);
      session.loopCurrentCue();

      expect(session.loop, isNotNull);
      expect(session.loop!.begin, ms(750));
      expect(session.loop!.end, ms(3250));
    });

    test('clamps a loop that would start before zero', () async {
      final session = StudySession(
        playback: playback,
        tracks: [
          StudyTrack(id: 'x', cues: CueIndex([cue(100, 900, 'early')])),
        ],
      );
      await advance(session, playback, [500]);
      session.loopCurrentCue();
      expect(session.loop!.begin, Duration.zero);
    });

    test('rejects an inverted loop', () {
      final session = StudySession(playback: playback)
        ..setLoop(AbLoop(begin: ms(3000), end: ms(1000)));
      expect(session.loop, isNull);
    });

    test('clearing stops the looping', () async {
      final session = StudySession(playback: playback, tracks: [japanese])
        ..setLoop(AbLoop(begin: ms(1000), end: ms(3000)))
        ..clearLoop();

      await playback.play();
      await advance(session, playback, [3100]);
      expect(playback.calls.where((c) => c.startsWith('seek')), isEmpty);
    });
  });

  group('mode and track changes', () {
    test('switching mode resets reveal state', () async {
      final session = StudySession(
        playback: playback,
        tracks: [japanese, english],
        mode: SubtitleMode.listen,
      );
      await advance(session, playback, [1500]);
      await session.continueStudy();
      expect(session.snapshot.revealedTrackCount, 1);

      session.setMode(SubtitleMode.manual);
      expect(session.snapshot.revealedTrackCount, 0);
      expect(session.snapshot.tracks.every((t) => !t.isHidden), isTrue);
    });

    test('setting tracks keeps the display time', () async {
      final session = StudySession(playback: playback, tracks: [japanese]);
      await advance(session, playback, [1500]);

      session.setTracks([japanese, english]);
      expect(session.snapshot.displayTime, ms(1500));
      expect(session.snapshot.tracks, hasLength(2));
      expect(session.snapshot.tracks[1].cue?.text.text, 'Line one');
    });

    test('shrinking the track list clamps the reveal count', () async {
      final session = StudySession(
        playback: playback,
        tracks: [japanese, english],
        mode: SubtitleMode.listen,
      );
      await advance(session, playback, [1500]);
      await session.continueStudy();
      await session.continueStudy();
      expect(session.snapshot.revealedTrackCount, 2);

      session.setTracks([japanese]);
      expect(session.snapshot.revealedTrackCount, 1);
    });

    test('revealAll shows everything whatever the mode', () async {
      final session = StudySession(
        playback: playback,
        tracks: [japanese, english],
        mode: SubtitleMode.listen,
      );
      await advance(session, playback, [1500]);
      session.revealAll();
      expect(session.snapshot.tracks.every((t) => !t.isHidden), isTrue);
    });
  });

  group('SubtitleMode', () {
    test('wire names match the stored profile format', () {
      expect(SubtitleMode.quickCheck.wireName, 'qcheck');
      expect(SubtitleMode.byWireName('listen'), SubtitleMode.listen);
    });

    test('falls back for an unknown name', () {
      expect(
        SubtitleMode.byWireName('nonsense', fallback: SubtitleMode.manual),
        SubtitleMode.manual,
      );
      expect(() => SubtitleMode.byWireName('nonsense'), throwsArgumentError);
    });

    test('classifies its own behaviour', () {
      expect(SubtitleMode.listen.pausesAutomatically, isTrue);
      expect(SubtitleMode.read.pausesAutomatically, isTrue);
      expect(SubtitleMode.manual.pausesAutomatically, isFalse);
      expect(SubtitleMode.quickCheck.revealsProgressively, isTrue);
      expect(SubtitleMode.read.revealsProgressively, isFalse);
    });
  });

  group('track ordering', () {
    final tracks = [
      (id: 'c', language: 'eng'),
      (id: 'a', language: 'jpn'),
      (id: 'b', language: 'deu'),
      (id: 'd', language: null),
    ];

    List<String> order({
      List<String> preferred = const [],
      Set<String> ignored = const {},
    }) =>
        orderSubtitleTracks(
          tracks,
          languageOf: (t) => t.language,
          idOf: (t) => t.id,
          preferredOrder: preferred,
          ignored: ignored,
        ).map((t) => t.id).toList();

    test('sorts by the preferred language order', () {
      expect(order(preferred: ['jpn', 'eng']), ['a', 'c', 'b', 'd']);
    });

    test('unlisted languages keep a stable order after the listed ones', () {
      expect(order(preferred: ['jpn']), ['a', 'b', 'c', 'd']);
    });

    test('drops ignored languages', () {
      expect(
          order(preferred: ['jpn', 'eng'], ignored: {'deu'}), ['a', 'c', 'd']);
    });

    test('with no preference, sorts by language then id', () {
      expect(order(), ['b', 'c', 'a', 'd']);
    });
  });
}

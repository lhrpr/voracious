/// Widget tests for the parts of the UI that make a rendering decision.
///
/// There are only a few, because the UI is supposed to hold no rules: most of
/// what could be wrong here is wrong in core instead, where it is already
/// tested. What is left is the annotation walk (ruby has to sit above its base
/// text without widening the line) and the study display (a hidden track has
/// to occupy space rather than collapse).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voracious_app/src/widgets/annotated_text_view.dart';
import 'package:voracious_app/src/widgets/subtitle_stack.dart';
import 'package:voracious_app/src/widgets/transport_bar.dart';
import 'package:voracious_core/voracious_core.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

StudyCue _cue(String text, {List<Annotation> annotations = const []}) =>
    StudyCue(
      begin: Duration.zero,
      end: const Duration(seconds: 2),
      text: AnnotatedText.lenient(text, annotations),
    );

void main() {
  group('AnnotatedTextView', () {
    testWidgets('renders every character of plain text', (tester) async {
      await tester.pumpWidget(_host(
        AnnotatedTextView(
          text: AnnotatedText.plain('hello'),
          style: const TextStyle(fontSize: 20),
        ),
      ));

      // The walk emits one Text per code point.
      expect(find.text('h'), findsOneWidget);
      expect(find.text('o'), findsOneWidget);
    });

    testWidgets('shows a reading above the text it belongs to', (tester) async {
      await tester.pumpWidget(_host(
        AnnotatedTextView(
          text: AnnotatedText.lenient('日本', [
            const RubyAnnotation(cpBegin: 0, cpEnd: 2, text: 'にほん'),
          ]),
          style: const TextStyle(fontSize: 20),
        ),
      ));

      expect(find.text('にほん'), findsOneWidget);
      expect(find.text('日'), findsOneWidget);

      // The reading sits above the base text, not beside it.
      final reading = tester.getCenter(find.text('にほん'));
      final base = tester.getCenter(find.text('日'));
      expect(reading.dy, lessThan(base.dy));
    });

    testWidgets('drops the reading but keeps the text when ruby is off',
        (tester) async {
      await tester.pumpWidget(_host(
        AnnotatedTextView(
          text: AnnotatedText.lenient('日本', [
            const RubyAnnotation(cpBegin: 0, cpEnd: 2, text: 'にほん'),
          ]),
          style: const TextStyle(fontSize: 20),
          showRuby: false,
        ),
      ));

      // Turning readings off must not take the base text with it, which is
      // what happens if the wrap callback forgets to return its inner pieces.
      expect(find.text('にほん'), findsNothing);
      expect(find.text('日'), findsOneWidget);
      expect(find.text('本'), findsOneWidget);
    });

    testWidgets('reports the tapped word', (tester) async {
      String? tapped;
      await tester.pumpWidget(_host(
        AnnotatedTextView(
          text: AnnotatedText.lenient('走った', [
            const WordAnnotation(cpBegin: 0, cpEnd: 3, lemma: '走る'),
          ]),
          style: const TextStyle(fontSize: 20),
          onWordTap: (word) => tapped = word,
        ),
      ));

      await tester.tap(find.text('走'));
      // Dictionary lookup keys off the lemma, not the surface form.
      expect(tapped, '走る');
    });
  });

  group('SubtitleStack', () {
    StudySessionSnapshot snapshot(List<DisplayedTrack> tracks) =>
        StudySessionSnapshot(
          mode: SubtitleMode.listen,
          displayTime: Duration.zero,
          tracks: tracks,
          revealedTrackCount: 0,
          isFrozen: false,
        );

    StudyTrack track(String id) => StudyTrack(id: id, cues: CueIndex(const []));

    testWidgets('shows a revealed line and withholds a hidden one',
        (tester) async {
      await tester.pumpWidget(_host(
        SubtitleStack(
          snapshot: snapshot([
            // Disjoint characters: the walk emits one Text per code point, so
            // a letter shared between the two lines would prove nothing.
            DisplayedTrack(
              track: track('a'),
              cue: _cue('abc'),
              isHidden: false,
            ),
            DisplayedTrack(
              track: track('b'),
              cue: _cue('xyz'),
              isHidden: true,
            ),
          ]),
          showRuby: true,
          fontScale: 1,
        ),
      ));

      expect(find.text('a'), findsOneWidget);
      // A hidden track must not render its text anywhere in the tree, or it
      // would be readable by anyone who selects it.
      expect(find.text('x'), findsNothing);
      expect(find.text('y'), findsNothing);
    });

    testWidgets('a hidden track still occupies its space', (tester) async {
      Future<double> heightWith({required bool hidden}) async {
        await tester.pumpWidget(_host(
          SubtitleStack(
            snapshot: snapshot([
              DisplayedTrack(
                track: track('a'),
                cue: _cue('line'),
                isHidden: hidden,
              ),
            ]),
            showRuby: true,
            fontScale: 1,
          ),
        ));
        return tester.getSize(find.byType(SubtitleStack)).height;
      }

      final revealed = await heightWith(hidden: false);
      final hidden = await heightWith(hidden: true);

      // Revealing must not shift the other lines: in listening practice the
      // user is looking straight at them when it happens.
      expect(hidden, closeTo(revealed, revealed * 0.35));
      expect(hidden, greaterThan(0));
    });

    testWidgets('tapping a hidden track asks to reveal', (tester) async {
      var revealed = false;
      await tester.pumpWidget(_host(
        SubtitleStack(
          snapshot: snapshot([
            DisplayedTrack(
              track: track('a'),
              cue: _cue('secret'),
              isHidden: true,
            ),
          ]),
          showRuby: true,
          fontScale: 1,
          onRevealTrack: () => revealed = true,
        ),
      ));

      await tester.tap(find.byType(GestureDetector));
      expect(revealed, isTrue);
    });
  });

  group('formatDuration', () {
    test('drops the hour when there is none', () {
      expect(formatDuration(const Duration(minutes: 3, seconds: 7)), '03:07');
      expect(
        formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
      // A negative position is what a seek to before zero produces.
      expect(formatDuration(const Duration(seconds: -5)), '00:00');
    });
  });
}

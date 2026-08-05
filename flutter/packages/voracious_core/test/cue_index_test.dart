import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

StudyCue cue(int beginMs, int endMs, {String? id, String text = 'x'}) =>
    StudyCue(
      id: id,
      begin: Duration(milliseconds: beginMs),
      end: Duration(milliseconds: endMs),
      text: AnnotatedText.plain(text),
    );

Duration ms(int value) => Duration(milliseconds: value);

void main() {
  group('CueIndex', () {
    final index = CueIndex([
      cue(3000, 4000, id: 'c', text: 'third'),
      cue(1000, 2000, id: 'a', text: 'first'),
      cue(2000, 2500, id: 'b', text: 'second'),
    ]);

    test('sorts by start time regardless of input order', () {
      expect(index.cues.map((c) => c.id), ['a', 'b', 'c']);
    });

    test('finds the cue covering a time', () {
      expect(index.cueAt(ms(1500))?.id, 'a');
      expect(index.cueAt(ms(2100))?.id, 'b');
      expect(index.cueAt(ms(3500))?.id, 'c');
    });

    test('returns nothing in a gap or outside the track', () {
      expect(index.cueAt(ms(2700)), isNull);
      expect(index.cueAt(ms(500)), isNull);
      expect(index.cueAt(ms(9000)), isNull);
    });

    test('treats the end of a cue as exclusive', () {
      expect(index.cueAt(ms(1999))?.id, 'a');
      expect(index.cueAt(ms(2000))?.id, 'b');
    });

    test('previousCue steps back one line from inside a cue', () {
      expect(index.previousCue(ms(2100))?.id, 'a');
      expect(index.previousCue(ms(1500)), isNull, reason: 'first cue');
    });

    test('previousCue in a gap returns the line that just ended', () {
      expect(index.previousCue(ms(2700))?.id, 'b');
    });

    test('nextCue finds the next line to start', () {
      expect(index.nextCue(ms(1500))?.id, 'b');
      expect(index.nextCue(ms(2700))?.id, 'c');
      expect(index.nextCue(ms(3500)), isNull);
      expect(index.nextCue(ms(0))?.id, 'a');
    });

    test('walking forwards then back returns to the same cue', () {
      final next = index.nextCue(ms(1500))!;
      expect(index.previousCue(next.begin + ms(1))?.id, 'a');
    });

    test('binary search boundaries', () {
      expect(index.lastStartingAtOrBefore(ms(999)), isNull);
      expect(index.lastStartingAtOrBefore(ms(1000)), 0);
      expect(index.lastStartingAtOrBefore(ms(5000)), 2);
      expect(index.firstStartingAfter(ms(5000)), isNull);
      expect(index.firstStartingAfter(ms(0)), 0);
    });

    test('handles overlapping cues, which ASS tracks routinely have', () {
      final overlapping = CueIndex([
        cue(1000, 8000, id: 'sign'),
        cue(2000, 3000, id: 'line1'),
        cue(3000, 4000, id: 'line2'),
      ]);

      expect(
        overlapping.activeCues(ms(2500)).map((c) => c.id),
        ['sign', 'line1'],
      );
      // The latest-starting active cue is the one the study modes follow.
      expect(overlapping.cueAt(ms(2500))?.id, 'line1');
      // Inside the long cue but between the short ones, only the long one.
      expect(overlapping.cueAt(ms(5000))?.id, 'sign');
    });

    test('empty index answers everything with null', () {
      expect(CueIndex.empty.cueAt(ms(1000)), isNull);
      expect(CueIndex.empty.nextCue(ms(1000)), isNull);
      expect(CueIndex.empty.previousCue(ms(1000)), isNull);
      expect(CueIndex.empty.isEmpty, isTrue);
    });

    test('updateText replaces one cue and keeps its identity', () {
      final updated = index.updateText('b', AnnotatedText.plain('changed'));
      expect(updated.byId('b')!.text.text, 'changed');
      expect(updated.byId('a')!.text.text, 'first');
      expect(updated.length, index.length);
    });

    test('shifted moves every cue and clamps at zero', () {
      final shifted = index.shifted(ms(-1500));
      expect(shifted.cues.first.begin, Duration.zero);
      expect(shifted.cues.last.begin, ms(1500));
    });

    test('lastEnd reports the end of the track', () {
      expect(index.lastEnd, ms(4000));
    });

    test('StudyCue survives a JSON round trip', () {
      final original = cue(1000, 2000, id: 'a', text: 'hello');
      final restored = StudyCue.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.begin, original.begin);
      expect(restored.text.text, 'hello');
    });
  });
}

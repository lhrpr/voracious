import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

void main() {
  group('code points', () {
    test('counts astral characters as one', () {
      expect(codePointLength('a𝄞b'), 3);
      expect('a𝄞b'.length, 4,
          reason: 'UTF-16 length differs, which is the point');
    });

    test('slices by code point, not code unit', () {
      expect(codePointSlice('a𝄞b', 1, 2), '𝄞');
      expect(codePointSlice('日本語字幕', 2, 5), '語字幕');
    });

    test('converts UTF-16 offsets to code point offsets', () {
      expect(codeUnitToCodePointOffset('a𝄞b', 3), 2);
    });
  });

  group('AnnotatedText', () {
    test('plain text has no annotations', () {
      final text = AnnotatedText.plain('hello');
      expect(text.annotations, isEmpty);
      expect(text.length, 5);
    });

    test('accepts nested annotations', () {
      final text = AnnotatedText.strict('食べる', const [
        WordAnnotation(cpBegin: 0, cpEnd: 3, lemma: '食べる'),
        RubyAnnotation(cpBegin: 0, cpEnd: 1, text: 'た'),
      ]);
      expect(text.annotations, hasLength(2));
    });

    test('rejects annotations that only partially overlap', () {
      final text = AnnotatedText.plain('abcdef');
      final withFirst = text.add(const WordAnnotation(cpBegin: 0, cpEnd: 4));
      expect(
        () => withFirst.add(const WordAnnotation(cpBegin: 2, cpEnd: 6)),
        throwsA(isA<AnnotationNestingError>()),
      );
      expect(
          withFirst.tryAdd(const WordAnnotation(cpBegin: 2, cpEnd: 6)), isNull);
    });

    test('lenient construction drops the offender and keeps the rest', () {
      final rejected = <Annotation>[];
      final text = AnnotatedText.lenient(
        'abcdef',
        const [
          WordAnnotation(cpBegin: 0, cpEnd: 4),
          WordAnnotation(cpBegin: 2, cpEnd: 6), // crosses the first
          WordAnnotation(cpBegin: 4, cpEnd: 6),
        ],
        onRejected: rejected.add,
      );
      expect(text.annotations, hasLength(2));
      expect(rejected, hasLength(1));
      expect(rejected.single.cpBegin, 2);
    });

    test('rejects ranges outside the text', () {
      final text = AnnotatedText.plain('abc');
      expect(
        () => text.add(const WordAnnotation(cpBegin: 0, cpEnd: 9)),
        throwsA(isA<RangeError>()),
      );
      expect(
        () => text.add(const WordAnnotation(cpBegin: 2, cpEnd: 2)),
        throwsA(isA<RangeError>()),
      );
    });

    test('setRuby replaces any existing ruby over the range', () {
      var text = AnnotatedText.plain('食べる').setRuby(0, 1, 'た');
      expect(text.ofKind(AnnotationKind.ruby), hasLength(1));

      text = text.setRuby(0, 1, 'しょく');
      expect(text.ofKind(AnnotationKind.ruby), hasLength(1));
      expect((text.ofKind(AnnotationKind.ruby).single as RubyAnnotation).text,
          'しょく');

      text = text.setRuby(0, 1, null);
      expect(text.ofKind(AnnotationKind.ruby), isEmpty);
    });

    test('highlights are scoped to their set', () {
      final created = DateTime.utc(2026);
      var text = AnnotatedText.plain('abcdef')
          .addHighlight(0, 3, 'known', createdAt: created)
          .addHighlight(0, 3, 'study', createdAt: created);
      expect(text.ofKind(AnnotationKind.highlight), hasLength(2));

      text = text.removeHighlights(0, 3, 'known');
      final remaining = text.ofKind(AnnotationKind.highlight);
      expect(remaining, hasLength(1));
      expect((remaining.single as HighlightAnnotation).setId, 'study');
    });

    test('adding a highlight replaces an overlapping one in the same set', () {
      final text = AnnotatedText.plain('abcdef')
          .addHighlight(0, 3, 'study')
          .addHighlight(2, 5, 'study');
      expect(text.ofKind(AnnotationKind.highlight), hasLength(1));
      expect(text.ofKind(AnnotationKind.highlight).single.cpBegin, 2);
    });

    test('queries return annotations outermost first', () {
      final text = AnnotatedText.strict('食べる', const [
        RubyAnnotation(cpBegin: 0, cpEnd: 1, text: 'た'),
        WordAnnotation(cpBegin: 0, cpEnd: 3),
      ]);
      final atZero = text.inRange(0, 1);
      expect(atZero.first, isA<WordAnnotation>(),
          reason: 'the longer span is the outer one');
      expect(atZero.last, isA<RubyAnnotation>());
    });

    test('render walks the annotation tree', () {
      final text = AnnotatedText.strict('食べる', const [
        WordAnnotation(cpBegin: 0, cpEnd: 3, lemma: '食べる'),
        RubyAnnotation(cpBegin: 0, cpEnd: 1, text: 'た'),
      ]);

      final rendered = text.renderToString(
        wrap: (annotation, inner) => switch (annotation) {
          RubyAnnotation(:final text) => ['<ruby>', ...inner, '($text)</ruby>'],
          WordAnnotation() => ['[', ...inner, ']'],
          _ => inner,
        },
      );

      expect(rendered, '[<ruby>食(た)</ruby>べる]');
    });

    test('render covers text outside any annotation', () {
      final text = AnnotatedText.strict('abcdef', const [
        WordAnnotation(cpBegin: 2, cpEnd: 4),
      ]);
      expect(
        text.renderToString(wrap: (_, inner) => ['<', ...inner, '>']),
        'ab<cd>ef',
      );
    });

    test('concat shifts annotation offsets', () {
      final combined = AnnotatedText.concat([
        AnnotatedText.strict('食べる', const [
          RubyAnnotation(cpBegin: 0, cpEnd: 1, text: 'た'),
        ]),
        AnnotatedText.plain('。'),
        AnnotatedText.strict('見る', const [
          RubyAnnotation(cpBegin: 0, cpEnd: 1, text: 'み'),
        ]),
      ]);

      expect(combined.text, '食べる。見る');
      final ruby = combined.ofKind(AnnotationKind.ruby);
      expect(ruby.map((a) => a.cpBegin), [0, 4]);
    });

    test('survives a JSON round trip', () {
      final original = AnnotatedText.strict('食べる', [
        const WordAnnotation(cpBegin: 0, cpEnd: 3, lemma: '食べる'),
        const RubyAnnotation(cpBegin: 0, cpEnd: 1, text: 'た'),
        HighlightAnnotation(
          cpBegin: 0,
          cpEnd: 3,
          setId: 'study',
          createdAtMillis: DateTime.utc(2026).millisecondsSinceEpoch,
        ),
      ]);

      final restored = AnnotatedText.fromJson(original.toJson());
      expect(restored, original);
    });

    test('handles astral characters in annotation ranges', () {
      final text = AnnotatedText.strict('a𝄞b', const [
        WordAnnotation(cpBegin: 1, cpEnd: 2),
      ]);
      expect(text.textOf(text.annotations.single), '𝄞');
    });
  });
}

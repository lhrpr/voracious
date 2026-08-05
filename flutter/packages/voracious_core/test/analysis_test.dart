import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

/// A tokeniser driven by a fixed table, standing in for MeCab/Kuromoji.
class FakeJapaneseTokenizer implements Tokenizer {
  FakeJapaneseTokenizer(this.tokensByText);

  final Map<String, List<LanguageToken>> tokensByText;

  var readyCalls = 0;
  var _ready = false;

  @override
  String get languageCode => 'jpn';

  @override
  bool get isReady => _ready;

  @override
  Future<void> ensureReady() async {
    readyCalls++;
    _ready = true;
  }

  @override
  Future<List<LanguageToken>> tokenize(String text) async =>
      tokensByText[text] ?? const [];
}

class ThrowingTokenizer implements Tokenizer {
  @override
  String get languageCode => 'jpn';

  @override
  bool get isReady => true;

  @override
  Future<void> ensureReady() async {}

  @override
  Future<List<LanguageToken>> tokenize(String text) async =>
      throw StateError('backend exploded');
}

void main() {
  group('WhitespaceTokenizer', () {
    final tokenizer = WhitespaceTokenizer(languageCode: 'eng');

    test('splits on non-word characters', () {
      final tokens = tokenizer.tokenizeSync('Hello, world!');
      expect(tokens.map((t) => t.surface), ['Hello', 'world']);
      expect(tokens.first.cpBegin, 0);
      expect(tokens.first.cpEnd, 5);
    });

    test('keeps internal apostrophes and hyphens', () {
      expect(
        tokenizer.tokenizeSync("l'été well-known").map((t) => t.surface),
        ["l'été", 'well-known'],
      );
    });

    test('handles non-Latin scripts', () {
      expect(
        tokenizer.tokenizeSync('Привет Καλημέρα').map((t) => t.surface),
        ['Привет', 'Καλημέρα'],
      );
    });

    test('offsets are code points, not code units', () {
      final tokens = tokenizer.tokenizeSync('𝄞 note');
      expect(tokens.single.surface, 'note');
      expect(tokens.single.cpBegin, 2, reason: 'the clef is one code point');
    });
  });

  group('buildAnnotatedText', () {
    test('annotates words and generates furigana', () {
      const text = '食べる';
      final annotated = buildAnnotatedText(text, const [
        LanguageToken(
          surface: '食べる',
          cpBegin: 0,
          cpEnd: 3,
          lemma: '食べる',
          reading: 'タベル',
        ),
      ]);

      expect(annotated.ofKind(AnnotationKind.word), hasLength(1));
      final ruby = annotated.ofKind(AnnotationKind.ruby);
      expect(ruby, hasLength(1));
      expect((ruby.single as RubyAnnotation).text, 'た');
    });

    test('does not store a lemma identical to the surface', () {
      final annotated = buildAnnotatedText('食べる', const [
        LanguageToken(surface: '食べる', cpBegin: 0, cpEnd: 3, lemma: '食べる'),
      ]);
      final word =
          annotated.ofKind(AnnotationKind.word).single as WordAnnotation;
      expect(word.lemma, isNull);
    });

    test('keeps a lemma that differs', () {
      final annotated = buildAnnotatedText('食べた', const [
        LanguageToken(surface: '食べた', cpBegin: 0, cpEnd: 3, lemma: '食べる'),
      ]);
      final word =
          annotated.ofKind(AnnotationKind.word).single as WordAnnotation;
      expect(word.lemma, '食べる');
    });

    test('skips punctuation tokens', () {
      final annotated = buildAnnotatedText('食べる。', const [
        LanguageToken(surface: '食べる', cpBegin: 0, cpEnd: 3),
        LanguageToken(surface: '。', cpBegin: 3, cpEnd: 4, isPunctuation: true),
      ]);
      expect(annotated.ofKind(AnnotationKind.word), hasLength(1));
    });

    test('no ruby over a word with no kanji', () {
      final annotated = buildAnnotatedText('コーヒー', const [
        LanguageToken(
          surface: 'コーヒー',
          cpBegin: 0,
          cpEnd: 4,
          reading: 'コーヒー',
        ),
      ]);
      expect(annotated.ofKind(AnnotationKind.ruby), isEmpty);
    });

    test('rejects tokens whose offsets do not match the text', () {
      final rejected = <String>[];
      final annotated = buildAnnotatedText(
        '食べる',
        const [
          LanguageToken(surface: '飲む', cpBegin: 0, cpEnd: 2),
          LanguageToken(surface: '食べる', cpBegin: 0, cpEnd: 3),
        ],
        onRejected: (token, reason) => rejected.add(reason),
      );
      expect(annotated.ofKind(AnnotationKind.word), hasLength(1));
      expect(rejected, hasLength(1));
      expect(rejected.single, contains('!='));
    });

    test('rejects out-of-range tokens', () {
      final rejected = <String>[];
      buildAnnotatedText(
        'abc',
        const [LanguageToken(surface: 'abcdef', cpBegin: 0, cpEnd: 6)],
        onRejected: (token, reason) => rejected.add(reason),
      );
      expect(rejected.single, 'offsets outside text');
    });

    test('ruby nests inside its word annotation', () {
      final annotated = buildAnnotatedText('食べる', const [
        LanguageToken(
          surface: '食べる',
          cpBegin: 0,
          cpEnd: 3,
          reading: 'たべる',
        ),
      ]);
      final ordered = annotated.sortedAnnotations;
      expect(ordered.first, isA<WordAnnotation>());
      expect(ordered.last, isA<RubyAnnotation>());
    });
  });

  group('TextAnalyzer', () {
    test('returns plain text when no tokeniser is registered', () async {
      final analyzer = TextAnalyzer();
      final result = await analyzer.analyze('Hello', 'eng');
      expect(result.annotations, isEmpty);
      expect(result.text, 'Hello');
    });

    test('uses the registered tokeniser for its language', () async {
      final analyzer = TextAnalyzer()
        ..register(FakeJapaneseTokenizer({
          '食べる': const [
            LanguageToken(surface: '食べる', cpBegin: 0, cpEnd: 3, reading: 'たべる'),
          ],
        }));

      expect(analyzer.canAnalyze('jpn'), isTrue);
      expect(analyzer.canAnalyze('eng'), isFalse);

      final result = await analyzer.analyze('食べる', 'jpn');
      expect(result.ofKind(AnnotationKind.ruby), hasLength(1));
    });

    test('loads the backend once, before the first line', () async {
      final tokenizer = FakeJapaneseTokenizer({});
      final analyzer = TextAnalyzer()..register(tokenizer);

      await analyzer.analyzeAll(['a', 'b', 'c'], 'jpn');
      expect(tokenizer.readyCalls, 1);
    });

    test('a tokeniser failure costs the annotations, not the line', () async {
      final analyzer = TextAnalyzer()..register(ThrowingTokenizer());
      final result = await analyzer.analyze('食べる', 'jpn');
      expect(result.text, '食べる');
      expect(result.annotations, isEmpty);
    });

    test('reports progress across a batch', () async {
      final analyzer = TextAnalyzer()..register(FakeJapaneseTokenizer({}));
      final progress = <double>[];
      await analyzer.analyzeAll(
        ['a', 'b', 'c', 'd'],
        'jpn',
        onProgress: progress.add,
      );
      expect(progress, [0.25, 0.5, 0.75, 1.0]);
    });

    test('blank lines skip the tokeniser', () async {
      final analyzer = TextAnalyzer()..register(FakeJapaneseTokenizer({}));
      final result = await analyzer.analyze('   ', 'jpn');
      expect(result.text, '   ');
    });
  });
}

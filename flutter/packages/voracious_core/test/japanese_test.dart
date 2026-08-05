import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

void main() {
  group('kana classification', () {
    test('recognises hiragana, katakana and kanji', () {
      expect(isKana('あ'), isTrue);
      expect(isKana('ア'), isTrue);
      expect(isKana('食'), isFalse);
      expect(isKanji('食'), isTrue);
      expect(isKanji('あ'), isFalse);
      expect(isKanji('々'), isTrue, reason: 'the iteration mark counts');
    });

    test('the prolonged sound mark counts as kana', () {
      // If ー were not kana, コーヒー would split into three runs and furigana
      // alignment would fall apart.
      expect(isKana('ー'), isTrue);
      expect(isAllKana('コーヒー'), isTrue);
    });

    test('the katakana middle dot is punctuation, not kana', () {
      expect(isKana('・'), isFalse);
    });

    test('containsKanji and containsKana', () {
      expect(containsKanji('食べる'), isTrue);
      expect(containsKanji('たべる'), isFalse);
      expect(containsKana('食べる'), isTrue);
      expect(containsKana('漢字'), isFalse);
    });

    test('containsJapanese spots any Japanese script', () {
      expect(containsJapanese('Hello 世界'), isTrue);
      expect(containsJapanese('Hello world'), isFalse);
    });
  });

  group('kana conversion', () {
    test('hiragana to katakana and back', () {
      expect(hiraganaToKatakana('こんにちは'), 'コンニチハ');
      expect(katakanaToHiragana('コンニチハ'), 'こんにちは');
    });

    test('leaves non-kana alone', () {
      expect(hiraganaToKatakana('食べる'), '食ベル');
      expect(katakanaToHiragana('Hello ア'), 'Hello あ');
    });

    test('does not shift katakana without a hiragana counterpart', () {
      // ヷヸヹヺ have no hiragana form.
      expect(katakanaToHiragana('ヷ'), 'ヷ');
    });

    test('expands half-width katakana', () {
      expect(halfWidthToFullWidthKatakana('ｺﾝﾆﾁﾊ'), 'コンニチハ');
    });

    test('combines standalone voiced marks', () {
      expect(halfWidthToFullWidthKatakana('ﾊﾟﾝ'), 'パン');
      expect(halfWidthToFullWidthKatakana('ｶﾞ'), 'ガ');
    });

    test('normalizeKana folds every writing of the same reading', () {
      expect(normalizeKana('パン'), normalizeKana('ﾊﾟﾝ'));
      expect(normalizeKana('パン'), 'ぱん');
      expect(sameReading('タベル', 'たべる'), isTrue);
      expect(sameReading('たべる', 'のむ'), isFalse);
    });
  });

  group('furigana alignment', () {
    List<String> describe(String surface, String reading) => [
          for (final segment in alignFurigana(surface, reading))
            segment.ruby == null
                ? segment.surface
                : '${segment.surface}[${segment.ruby}]',
        ];

    test('no furigana when the surface is already the reading', () {
      expect(alignFurigana('たべる', 'たべる'), isEmpty);
      expect(alignFurigana('タベル', 'たべる'), isEmpty,
          reason: 'same reading, different kana');
    });

    test('a single kanji run takes the whole reading', () {
      expect(describe('日本語', 'にほんご'), ['日本語[にほんご]']);
    });

    test('splits at trailing okurigana', () {
      expect(describe('食べる', 'たべる'), ['食[た]', 'べる']);
      expect(describe('大人しい', 'おとなしい'), ['大人[おとな]', 'しい']);
    });

    test('splits at leading kana', () {
      expect(describe('お茶', 'おちゃ'), ['お', '茶[ちゃ]']);
    });

    test('splits around interior kana', () {
      expect(describe('引っ越し', 'ひっこし'), ['引[ひ]', 'っ', '越[こ]', 'し']);
      expect(describe('打ち合わせ', 'うちあわせ'), ['打[う]', 'ち', '合[あ]', 'わせ']);
      expect(describe('見出し語', 'みだしご'), ['見出[みだ]', 'し', '語[ご]']);
    });

    test('handles sound changes inside a kanji reading', () {
      // Rendaku: 止まる -> ど, not と.
      expect(describe('立ち止まる', 'たちどまる'), ['立[た]', 'ち', '止[ど]', 'まる']);
      // Gemination stays inside the single kanji run.
      expect(describe('学校', 'がっこう'), ['学校[がっこう]']);
    });

    test('does not let a kanji run end up with no reading', () {
      // If the interior-kana search matched greedily at position 0, 気 would
      // get an empty reading.
      final segments = alignFurigana('気持ち', 'きもち');
      expect(
          segments.where((s) => s.needsRuby).every((s) => s.ruby!.isNotEmpty),
          isTrue);
    });

    test('falls back to one span when the reading cannot be aligned', () {
      // 一昨日 -> おととい shares no kana with the surface form.
      expect(describe('三ヶ月', 'さんかげつ'), ['三ヶ月[さんかげつ]']);
    });

    test('katakana ruby on request', () {
      final segments = alignFurigana('食べる', 'たべる', style: RubyStyle.katakana);
      expect(segments.first.ruby, 'タ');
    });

    test('empty inputs produce nothing', () {
      expect(alignFurigana('', 'たべる'), isEmpty);
      expect(alignFurigana('食べる', ''), isEmpty);
    });

    test('builds ruby annotations at the right offsets', () {
      final annotations = furiganaAnnotations('食べる', 'タベル', cpOffset: 5);
      expect(annotations, hasLength(1));
      expect(annotations.single.cpBegin, 5);
      expect(annotations.single.cpEnd, 6);
      expect(annotations.single.text, 'た', reason: 'rendered as hiragana');
    });
  });
}

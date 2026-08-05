import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

void main() {
  group('language table', () {
    test('maps between code sets', () {
      expect(toIso6393('ja'), 'jpn');
      expect(toIso6393('jpn'), 'jpn');
      expect(toIso6391('jpn'), 'ja');
      expect(languageName('jpn'), 'Japanese');
      expect(languageName('en'), 'English');
    });

    test('is case and whitespace tolerant', () {
      expect(toIso6393(' JA '), 'jpn');
    });

    test('returns null for codes it does not know', () {
      expect(toIso6393('zzz'), isNull);
      expect(languageName('zzz'), isNull);
    });

    test('every entry has both codes', () {
      expect(languageTable, isNotEmpty);
      for (final entry in languageTable) {
        expect(entry.iso6393, hasLength(3));
        expect(entry.iso6391, hasLength(2));
        expect(entry.name, isNotEmpty);
      }
    });
  });

  group('subtitle file name tags', () {
    test('reads a two-letter language tag', () {
      final tag = parseSubtitleLanguageTag('Movie.en.srt');
      expect(tag.iso6393, 'eng');
      expect(tag.baseName, 'Movie');
    });

    test('reads a three-letter tag', () {
      expect(parseSubtitleLanguageTag('Show.S01E01.jpn.ass').iso6393, 'jpn');
      expect(parseSubtitleLanguageTag('Show.S01E01.jpn.ass').baseName,
          'Show.S01E01');
    });

    test('reads region and script subtags', () {
      final tag = parseSubtitleLanguageTag('Movie.pt-BR.srt');
      expect(tag.iso6393, 'por');
      expect(tag.regionCode, 'BR');
      expect(tag.displayTag, 'pt-BR');

      final chinese = parseSubtitleLanguageTag('Movie.zh-Hans.srt');
      expect(chinese.iso6393, 'zho');
      expect(chinese.scriptCode, 'Hans');
    });

    test('recognises forced and SDH markers', () {
      final forced = parseSubtitleLanguageTag('Movie.en.forced.srt');
      expect(forced.forced, isTrue);
      expect(forced.iso6393, 'eng');
      expect(forced.baseName, 'Movie');

      final sdh = parseSubtitleLanguageTag('Movie.en.sdh.srt');
      expect(sdh.hearingImpaired, isTrue);
    });

    test('handles the non-standard tags releases actually use', () {
      expect(parseSubtitleLanguageTag('Movie.jp.srt').iso6393, 'jpn');
      expect(parseSubtitleLanguageTag('Movie.chs.srt').iso6393, 'zho');
      expect(parseSubtitleLanguageTag('Movie.English.srt').iso6393, 'eng');
    });

    test('leaves a name with no tag alone', () {
      final tag = parseSubtitleLanguageTag('Movie.srt');
      expect(tag.iso6393, isNull);
      expect(tag.baseName, 'Movie');
    });

    test('does not eat a title that ends in a number', () {
      final tag = parseSubtitleLanguageTag('Blade.Runner.2049.srt');
      expect(tag.baseName, 'Blade.Runner.2049');
      expect(tag.iso6393, isNull);
    });

    test('works without an extension', () {
      expect(parseSubtitleLanguageTag('Movie.en').iso6393, 'eng');
    });
  });

  group('language detection', () {
    test('detects Japanese from kana', () {
      final result = detectLanguage('こんにちは。今日はいい天気ですね。');
      expect(result.iso6393, 'jpn');
      expect(result.confidence, greaterThan(0.5));
    });

    test('distinguishes Chinese from Japanese by the absence of kana', () {
      expect(detectLanguage('今天天气很好，我们去公园散步吧。').iso6393, 'zho');
    });

    test('detects Korean', () {
      expect(detectLanguage('안녕하세요. 오늘 날씨가 좋네요.').iso6393, 'kor');
    });

    test('detects Cyrillic languages', () {
      expect(detectLanguage('Привет, как дела сегодня?').iso6393, 'rus');
      expect(
        detectLanguage('Привіт, як справи? Це українська мова.').iso6393,
        'ukr',
        reason: 'і/ї are Ukrainian-only',
      );
    });

    test('detects other scripts', () {
      expect(
          detectLanguage('Γειά σου κόσμε, τι κάνεις σήμερα;').iso6393, 'ell');
      expect(detectLanguage('สวัสดีครับ วันนี้อากาศดีมาก').iso6393, 'tha');
      expect(detectLanguage('שלום, מה שלומך היום?').iso6393, 'heb');
    });

    test('scores Latin-script languages by function words', () {
      expect(
        detectLanguage('I am not sure that this is the right thing to do '
                'with all of them when they are here')
            .iso6393,
        'eng',
      );
      expect(
        detectLanguage('No sé si esto es lo que quiero hacer con todo esto '
                'cuando ellos están aquí por la mañana')
            .iso6393,
        'spa',
      );
      expect(
        detectLanguage('Ich weiß nicht ob das die richtige Sache ist die man '
                'mit ihnen machen sollte wenn sie hier sind')
            .iso6393,
        'deu',
      );
      expect(
        detectLanguage("Je ne sais pas si c'est la bonne chose à faire avec "
                'eux quand ils sont ici ce matin')
            .iso6393,
        'fra',
      );
    });

    test('gives up rather than guessing on too little text', () {
      expect(detectLanguage('Hi').isUndetermined, isTrue);
      expect(detectLanguage('').isUndetermined, isTrue);
      expect(detectLanguage('12345 67890 !!!').isUndetermined, isTrue);
    });

    test('returns ranked candidates for Latin script', () {
      final candidates = detectLanguageCandidates(
        'I am not sure that this is the right thing to do with all of them',
      );
      expect(candidates.first.iso6393, 'eng');
      expect(candidates.first.confidence, greaterThan(0));
    });
  });
}

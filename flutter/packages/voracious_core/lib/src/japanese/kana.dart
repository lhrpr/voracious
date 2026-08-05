/// Kana classification and conversion.
///
/// Every furigana decision downstream rests on being able to say whether a
/// character is kana, and on comparing two readings that may be written in
/// different kana. A tokeniser hands back readings in katakana; the text on
/// screen is usually hiragana; half-width katakana turns up in older subtitle
/// rips. All three have to compare equal.
library;

const int _hiraganaStart = 0x3041; // ぁ
const int _hiraganaEnd = 0x3096; // ゖ
const int _katakanaStart = 0x30A1; // ァ
const int _katakanaEnd = 0x30FA; // ヺ

/// Highest katakana with a hiragana counterpart (ヶ). ヷヸヹヺ above it have
/// none, so they must not be shifted blindly.
const int _katakanaHiraganaCompatEnd = 0x30F6;

const int _prolongedSoundMark = 0x30FC; // ー
const int _katakanaMiddleDot = 0x30FB; // ・
const int _hiraganaIterationStart = 0x309D; // ゝゞ
const int _katakanaIterationStart = 0x30FD; // ヽヾ

const int _halfWidthStart = 0xFF61; // ｡
const int _halfWidthEnd = 0xFF9F; // ﾟ
const int _halfWidthVoiced = 0xFF9E; // ﾞ
const int _halfWidthSemiVoiced = 0xFF9F; // ﾟ

/// True for hiragana proper (excluding the shared prolonged sound mark).
bool isHiraganaCodePoint(int code) =>
    (code >= _hiraganaStart && code <= _hiraganaEnd) ||
    (code >= _hiraganaIterationStart && code <= _hiraganaIterationStart + 1);

/// True for katakana proper (excluding the middle dot, which is punctuation).
bool isKatakanaCodePoint(int code) =>
    (code >= _katakanaStart && code <= _katakanaEnd) ||
    (code >= _katakanaIterationStart && code <= _katakanaIterationStart + 1) ||
    (code >= 0xFF66 && code <= 0xFF9D);

/// True for any kana, including the prolonged sound mark `ー`.
///
/// `ー` counts because it carries a mora: treating it as a non-kana character
/// would split `コーヒー` into three runs and wreck furigana alignment.
bool isKanaCodePoint(int code) =>
    isHiraganaCodePoint(code) ||
    isKatakanaCodePoint(code) ||
    code == _prolongedSoundMark ||
    code == 0xFF70; // half-width ｰ

/// True for CJK ideographs, including the extension blocks and compatibility
/// ideographs, plus the iteration mark `々`.
bool isKanjiCodePoint(int code) =>
    (code >= 0x4E00 && code <= 0x9FFF) ||
    (code >= 0x3400 && code <= 0x4DBF) ||
    (code >= 0xF900 && code <= 0xFAFF) ||
    (code >= 0x20000 && code <= 0x2FA1F) ||
    code == 0x3005; // 々

/// True for the CJK punctuation that appears in subtitles.
bool isJapanesePunctuationCodePoint(int code) =>
    (code >= 0x3000 && code <= 0x303F && code != 0x3005) ||
    code == _katakanaMiddleDot ||
    (code >= 0xFF01 && code <= 0xFF20) ||
    (code >= 0xFF61 && code <= 0xFF65);

bool isKana(String character) =>
    character.isNotEmpty && isKanaCodePoint(character.runes.first);

bool isKanji(String character) =>
    character.isNotEmpty && isKanjiCodePoint(character.runes.first);

/// True when any character of [text] is kana.
bool containsKana(String text) => text.runes.any(isKanaCodePoint);

/// True when any character of [text] is a kanji.
bool containsKanji(String text) => text.runes.any(isKanjiCodePoint);

/// True when [text] is entirely kana (an empty string is not).
bool isAllKana(String text) =>
    text.isNotEmpty && text.runes.every(isKanaCodePoint);

/// True when [text] contains any Japanese script at all.
bool containsJapanese(String text) => text.runes.any(
      (c) =>
          isKanaCodePoint(c) ||
          isKanjiCodePoint(c) ||
          isJapanesePunctuationCodePoint(c),
    );

/// Converts hiragana in [text] to katakana, leaving everything else alone.
String hiraganaToKatakana(String text) {
  final buffer = StringBuffer();
  for (final code in text.runes) {
    if (code >= _hiraganaStart && code <= _hiraganaEnd) {
      buffer.writeCharCode(code + (_katakanaStart - _hiraganaStart));
    } else if (code >= _hiraganaIterationStart &&
        code <= _hiraganaIterationStart + 1) {
      buffer.writeCharCode(
          code + (_katakanaIterationStart - _hiraganaIterationStart));
    } else {
      buffer.writeCharCode(code);
    }
  }
  return buffer.toString();
}

/// Converts katakana in [text] to hiragana, leaving everything else alone.
///
/// ヷヸヹヺ have no hiragana form and are left as they are.
String katakanaToHiragana(String text) {
  final buffer = StringBuffer();
  for (final code in text.runes) {
    if (code >= _katakanaStart && code <= _katakanaHiraganaCompatEnd) {
      buffer.writeCharCode(code - (_katakanaStart - _hiraganaStart));
    } else if (code >= _katakanaIterationStart &&
        code <= _katakanaIterationStart + 1) {
      buffer.writeCharCode(
          code - (_katakanaIterationStart - _hiraganaIterationStart));
    } else {
      buffer.writeCharCode(code);
    }
  }
  return buffer.toString();
}

/// Expands half-width katakana to their full-width forms, combining the
/// standalone voiced (`ﾞ`) and semi-voiced (`ﾟ`) marks into the preceding
/// character so that `ﾊﾟﾝ` becomes `パン` rather than `ハ゜ン`.
String halfWidthToFullWidthKatakana(String text) {
  final codes = text.runes.toList();
  final buffer = StringBuffer();

  for (var i = 0; i < codes.length; i++) {
    final code = codes[i];
    if (code < _halfWidthStart || code > _halfWidthEnd) {
      buffer.writeCharCode(code);
      continue;
    }

    final base = _halfWidthTable[code - _halfWidthStart];
    final next = i + 1 < codes.length ? codes[i + 1] : null;

    if (next == _halfWidthVoiced) {
      final voiced = _voicedForms[base];
      if (voiced != null) {
        buffer.writeCharCode(voiced);
        i++;
        continue;
      }
    } else if (next == _halfWidthSemiVoiced) {
      final semiVoiced = _semiVoicedForms[base];
      if (semiVoiced != null) {
        buffer.writeCharCode(semiVoiced);
        i++;
        continue;
      }
    }

    buffer.writeCharCode(base);
  }

  return buffer.toString();
}

/// Puts [text] in the single form used for comparing readings: full-width
/// katakana expanded, then everything folded to hiragana.
///
/// `ﾊﾟﾝ`, `パン` and `ぱん` all normalise to `ぱん`.
String normalizeKana(String text) =>
    katakanaToHiragana(halfWidthToFullWidthKatakana(text));

/// True when [a] and [b] are the same reading written differently.
bool sameReading(String a, String b) => normalizeKana(a) == normalizeKana(b);

/// Maps U+FF61..U+FF9F to their full-width equivalents, indexed from
/// U+FF61. The two mark characters map to their spacing forms; callers that
/// want them combined use [halfWidthToFullWidthKatakana].
const List<int> _halfWidthTable = [
  0x3002, 0x300C, 0x300D, 0x3001, 0x30FB, 0x30F2, 0x30A1, 0x30A3, // FF61-FF68
  0x30A5, 0x30A7, 0x30A9, 0x30E3, 0x30E5, 0x30E7, 0x30C3, 0x30FC, // FF69-FF70
  0x30A2, 0x30A4, 0x30A6, 0x30A8, 0x30AA, 0x30AB, 0x30AD, 0x30AF, // FF71-FF78
  0x30B1, 0x30B3, 0x30B5, 0x30B7, 0x30B9, 0x30BB, 0x30BD, 0x30BF, // FF79-FF80
  0x30C1, 0x30C4, 0x30C6, 0x30C8, 0x30CA, 0x30CB, 0x30CC, 0x30CD, // FF81-FF88
  0x30CE, 0x30CF, 0x30D2, 0x30D5, 0x30D8, 0x30DB, 0x30DE, 0x30DF, // FF89-FF90
  0x30E0, 0x30E1, 0x30E2, 0x30E4, 0x30E6, 0x30E8, 0x30E9, 0x30EA, // FF91-FF98
  0x30EB, 0x30EC, 0x30ED, 0x30EF, 0x30F3, 0x309B, 0x309C, // FF99-FF9F
];

Map<int, int> _buildPairMap(String pairs) {
  final map = <int, int>{};
  final codes = pairs.runes.toList();
  for (var i = 0; i + 1 < codes.length; i += 2) {
    map[codes[i]] = codes[i + 1];
  }
  return map;
}

/// Katakana base -> voiced (dakuten) form.
final Map<int, int> _voicedForms =
    _buildPairMap('カガキギクグケゲコゴサザシジスズセゼソゾタダチヂツヅテデトドハバヒビフブヘベホボウヴワヷヲヺ');

/// Katakana base -> semi-voiced (handakuten) form.
final Map<int, int> _semiVoicedForms = _buildPairMap('ハパヒピフプヘペホポ');

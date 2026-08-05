/// Guesses the language of a block of subtitle text.
///
/// The file name tag (see `subtitle_language_tag.dart`) is the primary signal
/// and this is the fallback for the many collections that do not carry one.
/// Voracious does not need to tell Galician from Portuguese; it needs to know
/// which track is the one being studied and which is the translation, so
/// detection is script-first — which settles Japanese, Chinese, Korean, Arabic
/// and the rest outright — with function-word scoring only for the Latin
/// script, where scripts cannot separate anything.
library;

import 'package:meta/meta.dart';

import '../japanese/kana.dart';
import 'language_table.dart';

/// A candidate language with a confidence in `[0, 1]`.
@immutable
class LanguageDetection {
  const LanguageDetection(this.iso6393, this.confidence);

  /// ISO 639-3 code, or [undeterminedLanguage].
  final String iso6393;

  final double confidence;

  bool get isUndetermined => iso6393 == undeterminedLanguage;

  String get displayName => languageName(iso6393) ?? iso6393;

  @override
  String toString() =>
      'LanguageDetection($iso6393, ${(confidence * 100).round()}%)';
}

/// Detects the language of [text].
///
/// Returns [undeterminedLanguage] when there is not enough signal, which the
/// caller should treat as "ask the user" rather than as a guess.
LanguageDetection detectLanguage(String text) {
  final candidates = detectLanguageCandidates(text);
  return candidates.isEmpty
      ? const LanguageDetection(undeterminedLanguage, 0)
      : candidates.first;
}

/// Detects the language of [text], best candidate first.
List<LanguageDetection> detectLanguageCandidates(String text) {
  if (text.trim().length < 8) {
    return const [LanguageDetection(undeterminedLanguage, 0)];
  }

  final counts = _countScripts(text);
  final scripted = counts.values.fold(0, (sum, count) => sum + count);
  if (scripted == 0) {
    return const [LanguageDetection(undeterminedLanguage, 0)];
  }

  final kana = counts[_Script.kana] ?? 0;
  final han = counts[_Script.han] ?? 0;
  final hangul = counts[_Script.hangul] ?? 0;
  final latin = counts[_Script.latin] ?? 0;

  // Japanese text is mostly han by count but always carries kana; Chinese
  // carries none. Two kana characters in a subtitle file is decisive.
  if (kana >= 2) {
    return [LanguageDetection('jpn', _ratio(kana + han, scripted))];
  }
  if (hangul > 0) {
    return [LanguageDetection('kor', _ratio(hangul + han, scripted))];
  }
  if (han > 0 && han >= scripted * 0.2) {
    return [LanguageDetection('zho', _ratio(han, scripted))];
  }

  for (final entry in _singleScriptLanguages.entries) {
    final count = counts[entry.key] ?? 0;
    if (count > 0 && count >= scripted * 0.3) {
      return [LanguageDetection(entry.value(text), _ratio(count, scripted))];
    }
  }

  if (latin >= scripted * 0.5) return _scoreLatinLanguages(text);

  return const [LanguageDetection(undeterminedLanguage, 0)];
}

double _ratio(int part, int whole) =>
    whole == 0 ? 0 : (part / whole).clamp(0.0, 1.0);

enum _Script {
  latin,
  kana,
  han,
  hangul,
  cyrillic,
  greek,
  arabic,
  hebrew,
  thai,
  devanagari
}

/// Scripts that identify a language on their own (possibly after a check for
/// characters unique to one language written in that script).
final Map<_Script, String Function(String text)> _singleScriptLanguages = {
  _Script.cyrillic: _cyrillicLanguage,
  _Script.greek: (_) => 'ell',
  _Script.arabic: _arabicLanguage,
  _Script.hebrew: (_) => 'heb',
  _Script.thai: (_) => 'tha',
  _Script.devanagari: (_) => 'hin',
};

/// Ukrainian uses і/ї/є/ґ, which Russian does not; Serbian has its own set.
String _cyrillicLanguage(String text) {
  if (text.runes
      .any((c) => const [0x0456, 0x0457, 0x0454, 0x0491].contains(c))) {
    return 'ukr';
  }
  if (text.runes
      .any((c) => const [0x0452, 0x0459, 0x045A, 0x045B, 0x045F].contains(c))) {
    return 'srp';
  }
  return 'rus';
}

/// Persian adds پ چ ژ گ to the Arabic script.
String _arabicLanguage(String text) =>
    text.runes.any((c) => const [0x067E, 0x0686, 0x0698, 0x06AF].contains(c))
        ? 'fas'
        : 'ara';

Map<_Script, int> _countScripts(String text) {
  final counts = <_Script, int>{};
  void bump(_Script script) => counts[script] = (counts[script] ?? 0) + 1;

  for (final code in text.runes) {
    if (isKanaCodePoint(code)) {
      bump(_Script.kana);
    } else if (isKanjiCodePoint(code)) {
      bump(_Script.han);
    } else if ((code >= 0xAC00 && code <= 0xD7AF) ||
        (code >= 0x1100 && code <= 0x11FF) ||
        (code >= 0x3130 && code <= 0x318F)) {
      bump(_Script.hangul);
    } else if ((code >= 0x0400 && code <= 0x052F)) {
      bump(_Script.cyrillic);
    } else if ((code >= 0x0370 && code <= 0x03FF) ||
        (code >= 0x1F00 && code <= 0x1FFF)) {
      bump(_Script.greek);
    } else if ((code >= 0x0600 && code <= 0x06FF) ||
        (code >= 0x0750 && code <= 0x077F) ||
        (code >= 0xFB50 && code <= 0xFDFF) ||
        (code >= 0xFE70 && code <= 0xFEFF)) {
      bump(_Script.arabic);
    } else if ((code >= 0x0590 && code <= 0x05FF) ||
        (code >= 0xFB1D && code <= 0xFB4F)) {
      bump(_Script.hebrew);
    } else if (code >= 0x0E00 && code <= 0x0E7F) {
      bump(_Script.thai);
    } else if (code >= 0x0900 && code <= 0x097F) {
      bump(_Script.devanagari);
    } else if ((code >= 0x41 && code <= 0x5A) ||
        (code >= 0x61 && code <= 0x7A) ||
        (code >= 0x00C0 && code <= 0x024F) ||
        (code >= 0x1E00 && code <= 0x1EFF)) {
      bump(_Script.latin);
    }
  }
  return counts;
}

final RegExp _latinWord = RegExp(
  r"[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*",
  unicode: true,
);

List<LanguageDetection> _scoreLatinLanguages(String text) {
  final words = _latinWord
      .allMatches(text.toLowerCase())
      .map((m) => m[0]!)
      .toList(growable: false);
  if (words.length < 5) {
    return const [LanguageDetection(undeterminedLanguage, 0)];
  }

  final scores = <String, double>{};
  for (final entry in _functionWords.entries) {
    var hits = 0;
    for (final word in words) {
      if (entry.value.contains(word)) hits++;
    }
    scores[entry.key] = hits / words.length;
  }

  // Characters that only a few of these languages use at all. A handful of
  // them outweighs a lot of shared function-word noise.
  for (final code in text.toLowerCase().runes) {
    final languages = _markerCharacters[code];
    if (languages == null) continue;
    for (final language in languages) {
      scores[language] = (scores[language] ?? 0) + 0.02;
    }
  }

  final ranked = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  // Below this the "winner" is just whichever list happens to share the most
  // international words, which is not a detection.
  if (ranked.isEmpty || ranked.first.value < 0.06) {
    return const [LanguageDetection(undeterminedLanguage, 0)];
  }

  final total = ranked.take(4).fold<double>(0, (sum, e) => sum + e.value);
  return [
    for (final entry in ranked.take(4))
      if (entry.value > 0)
        LanguageDetection(
          entry.key,
          total == 0 ? 0 : (entry.value / total).clamp(0.0, 1.0),
        ),
  ];
}

/// High-frequency function words per language. Content words are useless for
/// this; articles, pronouns, prepositions and auxiliaries carry nearly all of
/// the discriminating power and appear in any few lines of dialogue.
final Map<String, Set<String>> _functionWords = {
  'eng': {
    'the', 'and', 'of', 'to', 'a', 'in', 'is', 'it', 'you', 'that', 'was', //
    'for', 'on', 'are', 'with', 'as', 'his', 'they', 'be', 'this', 'have',
    'from', 'not', 'but', 'what', 'all', 'we', 'when', 'your', 'can', 'there',
    'my', 'me', 'he', 'she', 'him', 'her', 'do', 'don\'t', 'i\'m', 'just',
  },
  'spa': {
    'el', 'la', 'de', 'que', 'y', 'en', 'un', 'no', 'se', 'los', 'con', //
    'por', 'para', 'una', 'su', 'lo', 'como', 'más', 'pero', 'sus', 'le',
    'ya', 'o', 'este', 'sí', 'porque', 'esta', 'son', 'entre', 'cuando',
    'muy', 'sin', 'sobre', 'también', 'me', 'hasta', 'hay', 'donde', 'qué',
  },
  'por': {
    'de', 'que', 'não', 'do', 'da', 'em', 'para', 'com', 'uma', 'os', 'no', //
    'se', 'na', 'por', 'mais', 'as', 'dos', 'como', 'mas', 'foi', 'ao',
    'ele', 'das', 'tem', 'à', 'seu', 'sua', 'ou', 'ser', 'quando', 'muito',
    'já', 'está', 'eu', 'também', 'só', 'pelo', 'pela', 'até', 'isso',
  },
  'fra': {
    'le', 'de', 'un', 'et', 'à', 'il', 'ne', 'je', 'son', 'que', 'se', //
    'qui', 'ce', 'dans', 'en', 'du', 'elle', 'au', 'pour', 'pas', 'vous',
    'par', 'sur', 'plus', 'me', 'on', 'mon', 'lui', 'nous', 'comme', 'mais',
    'avec', 'tout', 'les', 'des', 'est', 'une', 'c\'est', 'j\'ai', 'moi',
  },
  'deu': {
    'der', 'die', 'und', 'in', 'den', 'von', 'zu', 'das', 'mit', 'sich', //
    'des', 'auf', 'für', 'ist', 'im', 'dem', 'nicht', 'ein', 'eine', 'als',
    'auch', 'es', 'an', 'werden', 'aus', 'er', 'hat', 'dass', 'sie', 'nach',
    'wird', 'bei', 'um', 'am', 'sind', 'noch', 'wie', 'über', 'so', 'war',
    'ich', 'du', 'wir', 'aber', 'nur', 'was', 'mir', 'mich',
  },
  'ita': {
    'di', 'che', 'la', 'il', 'un', 'per', 'in', 'non', 'una', 'è', 'da', //
    'sono', 'mi', 'si', 'ho', 'ma', 'ha', 'le', 'io', 'come', 'con', 'ti',
    'se', 'più', 'questo', 'ci', 'lo', 'qui', 'al', 'tu', 'essere', 'bene',
    'sei', 'era', 'mio', 'molto', 'gli', 'tutto', 'fare', 'del', 'ora',
  },
  'nld': {
    'de', 'en', 'van', 'ik', 'te', 'dat', 'die', 'in', 'een', 'hij', 'het', //
    'niet', 'zijn', 'is', 'was', 'op', 'aan', 'met', 'als', 'voor', 'had',
    'er', 'maar', 'om', 'hem', 'dan', 'zou', 'of', 'wat', 'mijn', 'dit',
    'zo', 'door', 'over', 'ze', 'zich', 'bij', 'ook', 'tot', 'je', 'heb',
  },
  'swe': {
    'och', 'att', 'det', 'som', 'en', 'på', 'är', 'av', 'för', 'med', //
    'till', 'den', 'har', 'de', 'inte', 'om', 'ett', 'han', 'men', 'var',
    'jag', 'sig', 'från', 'vi', 'så', 'kan', 'man', 'när', 'hade', 'du',
    'nu', 'mig', 'dig', 'här', 'vad', 'ska', 'bara', 'upp',
  },
  'dan': {
    'og', 'jeg', 'det', 'at', 'en', 'den', 'til', 'er', 'som', 'på', 'de', //
    'med', 'han', 'af', 'for', 'ikke', 'der', 'var', 'mig', 'sig', 'men',
    'et', 'har', 'om', 'vi', 'min', 'havde', 'hun', 'nu', 'da', 'fra', 'du',
    'sin', 'dem', 'os', 'op', 'hvor', 'eller', 'hvad', 'skal', 'selv',
  },
  'nor': {
    'og', 'jeg', 'det', 'at', 'en', 'et', 'den', 'til', 'er', 'som', 'på', //
    'de', 'med', 'han', 'av', 'ikke', 'der', 'så', 'var', 'meg', 'seg',
    'men', 'har', 'om', 'vi', 'min', 'mitt', 'hadde', 'hun', 'ikkje', 'noe',
    'kan', 'du', 'hva', 'her', 'skal', 'bare',
  },
  'fin': {
    'ja', 'on', 'ei', 'se', 'että', 'en', 'oli', 'hän', 'mutta', 'niin', //
    'kuin', 'jos', 'minä', 'sen', 'tai', 'mitä', 'nyt', 'vain', 'ole',
    'olen', 'tämä', 'siitä', 'kun', 'voi', 'myös', 'ovat', 'sinä', 'me',
  },
  'pol': {
    'się', 'nie', 'to', 'że', 'jest', 'jak', 'co', 'dla', 'tak', 'ale', //
    'po', 'ja', 'tego', 'tym', 'przez', 'już', 'czy', 'ma', 'może', 'jego',
    'być', 'tylko', 'bardzo', 'gdy', 'te', 'jeszcze', 'nas', 'tu', 'nam',
  },
  'ces': {
    'se', 'na', 'je', 'že', 'do', 'to', 'ale', 'si', 'jak', 'za', 'tak', //
    'co', 'jsem', 'po', 'jsou', 'ještě', 'když', 'který', 'být', 'jen',
    'jako', 'také', 'už', 'od', 'může', 'nic', 'jsi', 'nás', 'tady',
  },
  'tur': {
    'bir', 'bu', 've', 'için', 'ne', 'çok', 'daha', 'ile', 'mi', 'ben', //
    'sen', 'biz', 'siz', 'onlar', 'var', 'yok', 'ama', 'gibi', 'kadar',
    'sonra', 'şey', 'evet', 'hayır', 'tamam', 'değil', 'beni', 'bana',
  },
  'ind': {
    'yang', 'dan', 'di', 'itu', 'dengan', 'untuk', 'tidak', 'ini', 'dari', //
    'dalam', 'akan', 'pada', 'juga', 'saya', 'ke', 'karena', 'bisa', 'ada',
    'mereka', 'lebih', 'kami', 'sudah', 'atau', 'kita', 'aku', 'kamu',
  },
  'vie': {
    'và', 'của', 'có', 'là', 'không', 'người', 'được', 'những', 'cho', //
    'trong', 'một', 'các', 'đã', 'với', 'để', 'này', 'khi', 'tôi', 'anh',
    'em', 'thì', 'mà', 'ra', 'đi', 'ở', 'rồi', 'gì', 'sao',
  },
  'ron': {
    'de', 'în', 'la', 'cu', 'care', 'este', 'pe', 'un', 'o', 'și', 'nu', //
    'se', 'ce', 'mai', 'să', 'am', 'ai', 'are', 'din', 'pentru', 'dar',
    'ca', 'fi', 'tot', 'când', 'ei', 'te', 'eu', 'îmi',
  },
  'hun': {
    'az', 'és', 'hogy', 'nem', 'is', 'egy', 'de', 'van', 'ez', 'ki', 'mi', //
    'csak', 'már', 'még', 'meg', 'majd', 'itt', 'ott', 'vagy', 'ha', 'mint',
    'én', 'te', 'ő', 'volt', 'lesz', 'nekem',
  },
};

/// Characters that narrow the field sharply when present.
final Map<int, List<String>> _markerCharacters = {
  0x00DF: ['deu'], // ß
  0x00F1: ['spa'], // ñ
  0x00BF: ['spa'], // ¿
  0x00A1: ['spa'], // ¡
  0x0153: ['fra'], // œ
  0x00E7: ['fra', 'por', 'tur'], // ç
  0x00E3: ['por'], // ã
  0x00F5: ['por'], // õ
  0x0142: ['pol'], // ł
  0x0105: ['pol'], // ą
  0x0119: ['pol'], // ę
  0x017C: ['pol'], // ż
  0x017A: ['pol'], // ź
  0x0159: ['ces'], // ř
  0x016F: ['ces'], // ů
  0x011B: ['ces'], // ě
  0x0131: ['tur'], // ı
  0x011F: ['tur'], // ğ
  0x015F: ['tur'], // ş
  0x0103: ['ron'], // ă
  0x0219: ['ron'], // ș
  0x021B: ['ron'], // ț
  0x0151: ['hun'], // ő
  0x0171: ['hun'], // ű
  0x00E5: ['swe', 'dan', 'nor'], // å
  0x00E6: ['dan', 'nor'], // æ
  0x00F8: ['dan', 'nor'], // ø
  0x0111: ['vie'], // đ
  0x01B0: ['vie'], // ư
  0x01A1: ['vie'], // ơ
};

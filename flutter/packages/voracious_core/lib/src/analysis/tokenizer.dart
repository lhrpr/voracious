/// The tokeniser contract, plus the one implementation that needs no data
/// files.
///
/// Japanese morphological analysis needs a dictionary — MeCab/IPADIC, Sudachi,
/// or a Kuromoji port — measured in tens of megabytes. That is a packaging
/// decision per platform, not something core should force, so core defines the
/// interface and the host application supplies the backend. The token-to-
/// annotation logic, which is where the subtle behaviour lives, stays here and
/// stays testable against hand-written token lists.
library;

import 'language_token.dart';

/// Turns text into tokens for one language.
abstract interface class Tokenizer {
  /// ISO 639-3 code of the language this tokeniser handles.
  String get languageCode;

  /// Loads whatever data the backend needs. Safe to call repeatedly; callers
  /// should await it before the first [tokenize].
  Future<void> ensureReady();

  /// True once [ensureReady] has completed.
  bool get isReady;

  /// Tokenises [text]. Offsets in the result are code point offsets into
  /// [text], and the tokens are in order and non-overlapping.
  Future<List<LanguageToken>> tokenize(String text);
}

/// Splits text on non-word characters.
///
/// Adequate for the space-delimited languages — it is what makes tap-a-word
/// dictionary lookup work for English, Spanish, German and so on — and useless
/// for Japanese, Chinese and Thai, which is exactly why [Tokenizer] is an
/// interface.
class WhitespaceTokenizer implements Tokenizer {
  WhitespaceTokenizer({this.languageCode = 'und'});

  @override
  final String languageCode;

  @override
  bool get isReady => true;

  @override
  Future<void> ensureReady() async {}

  /// A word is a run of letters, marks and digits, and may contain an
  /// apostrophe or hyphen provided a letter follows it — so `l'été` and
  /// `well-known` stay whole, while a trailing dash does not join two words.
  static final RegExp _word = RegExp(
    r"[\p{L}\p{N}\p{M}]+(?:[''’-][\p{L}\p{N}\p{M}]+)*",
    unicode: true,
  );

  @override
  Future<List<LanguageToken>> tokenize(String text) async => tokenizeSync(text);

  /// Synchronous form, for callers already off the UI thread.
  List<LanguageToken> tokenizeSync(String text) {
    final tokens = <LanguageToken>[];
    // Match offsets are UTF-16; walk the string once to convert them.
    var codeUnit = 0;
    var codePoint = 0;
    final chars = text.runes.toList();

    int toCodePoint(int targetCodeUnit) {
      while (codeUnit < targetCodeUnit && codePoint < chars.length) {
        codeUnit += chars[codePoint] > 0xFFFF ? 2 : 1;
        codePoint++;
      }
      return codePoint;
    }

    for (final match in _word.allMatches(text)) {
      final begin = toCodePoint(match.start);
      final end = toCodePoint(match.end);
      tokens.add(LanguageToken(
        surface: match[0]!,
        cpBegin: begin,
        cpEnd: end,
      ));
    }
    return tokens;
  }
}

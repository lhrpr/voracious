/// Turns tokens into an [AnnotatedText].
library;

import 'package:meta/meta.dart';

import '../japanese/furigana.dart';
import '../japanese/kana.dart';
import '../text/annotated_text.dart';
import '../text/code_points.dart';
import 'language_token.dart';

/// Controls what annotations get built from a token list.
@immutable
class AnnotationOptions {
  const AnnotationOptions({
    this.annotateWords = true,
    this.generateRuby = true,
    this.rubyStyle = RubyStyle.hiragana,
    this.rubyOnlyWhenKanjiPresent = true,
  });

  /// Emit a [WordAnnotation] per token. Needed for tap-to-look-up.
  final bool annotateWords;

  /// Emit [RubyAnnotation]s from token readings.
  final bool generateRuby;

  final RubyStyle rubyStyle;

  /// Skip ruby for tokens with no kanji. A reading over a word already written
  /// in kana is pure noise, and katakana loanwords would otherwise all sprout
  /// a hiragana gloss.
  final bool rubyOnlyWhenKanjiPresent;

  /// Word annotations only — used when the text is not Japanese.
  static const AnnotationOptions wordsOnly =
      AnnotationOptions(generateRuby: false);
}

/// Builds annotated text for [text] from [tokens].
///
/// Tokens whose offsets do not line up with [text] are dropped rather than
/// throwing: a third-party tokeniser that normalises a character silently would
/// otherwise take a whole subtitle line down with it. [onRejected] reports
/// each one, so a backend that is systematically wrong is still visible in
/// logs.
AnnotatedText buildAnnotatedText(
  String text,
  List<LanguageToken> tokens, {
  AnnotationOptions options = const AnnotationOptions(),
  void Function(LanguageToken token, String reason)? onRejected,
}) {
  final length = codePointLength(text);
  final annotations = <Annotation>[];

  for (final token in tokens) {
    if (token.cpBegin < 0 ||
        token.cpEnd > length ||
        token.cpBegin >= token.cpEnd) {
      onRejected?.call(token, 'offsets outside text');
      continue;
    }

    final slice = codePointSlice(text, token.cpBegin, token.cpEnd);
    if (slice != token.surface) {
      onRejected?.call(token, 'surface "${token.surface}" != text "$slice"');
      continue;
    }

    if (token.isPunctuation) continue;

    if (options.annotateWords) {
      final lemma = token.lemma;
      annotations.add(WordAnnotation(
        cpBegin: token.cpBegin,
        cpEnd: token.cpEnd,
        // Storing a lemma identical to the surface wastes space and makes
        // every annotation look "interesting" to the UI.
        lemma:
            (lemma == null || lemma.isEmpty || lemma == slice) ? null : lemma,
      ));
    }

    final reading = token.reading;
    if (options.generateRuby && reading != null && reading.isNotEmpty) {
      if (options.rubyOnlyWhenKanjiPresent && !containsKanji(slice)) continue;
      annotations.addAll(furiganaAnnotations(
        slice,
        reading,
        cpOffset: token.cpBegin,
        style: options.rubyStyle,
      ));
    }
  }

  // Ruby must nest inside words, so add words first and let the lenient
  // constructor drop anything that still conflicts.
  annotations.sort(compareForNesting);
  return AnnotatedText.lenient(text, annotations);
}

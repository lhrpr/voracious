/// The unit every tokeniser produces, regardless of language or backend.
library;

import 'package:meta/meta.dart';

/// One token identified in a piece of text.
///
/// Offsets are code point offsets into the text that was tokenised, which is
/// what [AnnotatedText] annotations use.
@immutable
class LanguageToken {
  const LanguageToken({
    required this.surface,
    required this.cpBegin,
    required this.cpEnd,
    this.lemma,
    this.reading,
    this.partOfSpeech,
    this.isPunctuation = false,
  });

  /// The text as it appears.
  final String surface;

  final int cpBegin;
  final int cpEnd;

  /// Dictionary form, when it differs from [surface]. This is what dictionary
  /// lookup keys off, so `食べた` finds `食べる`.
  final String? lemma;

  /// Kana reading, for Japanese. Drives furigana.
  final String? reading;

  /// Backend-specific part of speech tag; opaque to core, but useful for
  /// filtering in the UI.
  final String? partOfSpeech;

  /// True for punctuation and symbols, which get no word annotation.
  final bool isPunctuation;

  /// The form to look up in a dictionary.
  String get lookupForm => lemma ?? surface;

  @override
  bool operator ==(Object other) =>
      other is LanguageToken &&
      other.surface == surface &&
      other.cpBegin == cpBegin &&
      other.cpEnd == cpEnd &&
      other.lemma == lemma &&
      other.reading == reading &&
      other.partOfSpeech == partOfSpeech &&
      other.isPunctuation == isPunctuation;

  @override
  int get hashCode => Object.hash(
        surface,
        cpBegin,
        cpEnd,
        lemma,
        reading,
        partOfSpeech,
        isPunctuation,
      );

  @override
  String toString() => 'LanguageToken("$surface" @$cpBegin-$cpEnd'
      '${lemma != null ? ', lemma: $lemma' : ''}'
      '${reading != null ? ', reading: $reading' : ''})';
}

/// Helpers for working with strings by Unicode code point rather than by UTF-16
/// code unit.
///
/// Every text offset that Voracious persists — subtitle annotation ranges, word
/// boundaries produced by a tokenizer, furigana spans — is a code point offset.
/// Dart's `String` is indexed by UTF-16 code unit, so an emoji or a rare CJK
/// ideograph in the middle of a subtitle line would silently shift every offset
/// after it if we used `substring` directly.
library;

/// Splits [text] into a list of single-code-point strings.
///
/// A surrogate pair comes back as one two-code-unit `String`, not two halves.
List<String> toCodePoints(String text) =>
    text.runes.map(String.fromCharCode).toList(growable: false);

/// Number of code points in [text].
int codePointLength(String text) => text.runes.length;

/// Substring of [text] between the code point offsets [begin] (inclusive) and
/// [end] (exclusive, defaulting to the end of the string).
///
/// Throws [RangeError] if the range is not within the string.
String codePointSlice(String text, int begin, [int? end]) {
  if (begin < 0) {
    throw RangeError.value(begin, 'begin', 'must not be negative');
  }
  if (end != null && end < begin) {
    throw RangeError.value(end, 'end', 'must not be less than begin');
  }

  final buffer = StringBuffer();
  var index = 0;
  for (final rune in text.runes) {
    if (end != null && index >= end) {
      return buffer.toString();
    }
    if (index >= begin) {
      buffer.writeCharCode(rune);
    }
    index++;
  }

  if (begin > index || (end != null && end > index)) {
    throw RangeError('code point range [$begin, $end) is outside a string of '
        'length $index');
  }
  return buffer.toString();
}

/// Converts a UTF-16 code unit offset into a code point offset.
int codeUnitToCodePointOffset(String text, int codeUnitOffset) {
  if (codeUnitOffset < 0 || codeUnitOffset > text.length) {
    throw RangeError.range(codeUnitOffset, 0, text.length, 'codeUnitOffset');
  }
  var codePoints = 0;
  var codeUnits = 0;
  while (codeUnits < codeUnitOffset) {
    final unit = text.codeUnitAt(codeUnits);
    final isHighSurrogate = unit >= 0xD800 && unit <= 0xDBFF;
    final hasLowSurrogate = isHighSurrogate &&
        codeUnits + 1 < text.length &&
        text.codeUnitAt(codeUnits + 1) >= 0xDC00 &&
        text.codeUnitAt(codeUnits + 1) <= 0xDFFF;
    codeUnits += hasLowSurrogate ? 2 : 1;
    codePoints++;
  }
  return codePoints;
}

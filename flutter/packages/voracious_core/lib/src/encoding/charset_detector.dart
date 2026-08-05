/// Guesses the character encoding of a subtitle file from its bytes.
///
/// Subtitle files carry no encoding declaration, and a large share of the
/// Japanese and Chinese material in circulation predates UTF-8. Getting this
/// wrong does not produce an error — it produces mojibake that then flows into
/// the tokeniser and the dictionary lookups — so detection runs before every
/// subtitle load.
///
/// The approach is the standard two stages: eliminate encodings whose byte
/// structure the file violates, then rank the survivors by how much of the file
/// lands in each encoding's high-frequency character ranges.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'charset.dart';

/// A candidate encoding with a confidence in `[0, 1]`.
@immutable
class CharsetGuess {
  const CharsetGuess(this.charset, this.confidence);

  final Charset charset;
  final double confidence;

  @override
  String toString() =>
      'CharsetGuess(${charset.name}, ${(confidence * 100).round()}%)';
}

/// Guesses the encoding of [bytes], best candidate first.
///
/// The returned list is never empty: [Charset.windows1252] is always present as
/// a last resort, since it can decode any byte sequence.
List<CharsetGuess> detectCharset(Uint8List bytes) {
  final bom = detectBom(bytes);
  if (bom != null) return [CharsetGuess(bom, 1)];

  if (bytes.isEmpty) return const [CharsetGuess(Charset.utf8, 1)];

  // UTF-16 without a BOM shows up as a regular pattern of NUL bytes, which no
  // byte-oriented encoding produces in text.
  final utf16 = _detectBomlessUtf16(bytes);
  if (utf16 != null) return [CharsetGuess(utf16, 0.9)];

  final ascii = bytes.every((b) => b < 0x80);
  if (ascii) {
    // Pure ASCII is valid in every candidate; UTF-8 is the useful answer.
    return const [CharsetGuess(Charset.utf8, 1)];
  }

  if (_isValidUtf8(bytes)) {
    // Multi-byte UTF-8 sequences are structurally strict enough that a false
    // positive on a long file is vanishingly unlikely.
    return const [CharsetGuess(Charset.utf8, 0.95)];
  }

  final guesses = <CharsetGuess>[];
  for (final scorer in _legacyScorers) {
    final score = scorer.score(bytes);
    if (score != null) guesses.add(CharsetGuess(scorer.charset, score));
  }
  guesses.sort((a, b) => b.confidence.compareTo(a.confidence));

  if (!guesses.any((g) => g.charset == Charset.windows1252)) {
    guesses.add(const CharsetGuess(Charset.windows1252, 0.1));
  }
  return guesses;
}

/// The single best guess for [bytes].
Charset detectCharsetBest(Uint8List bytes) =>
    detectCharset(bytes).first.charset;

/// Returns the encoding indicated by a byte order mark, or null if absent.
Charset? detectBom(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return Charset.utf8;
  }
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) return Charset.utf16le;
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) return Charset.utf16be;
  }
  return null;
}

/// Number of bytes the byte order mark for [charset] occupies.
int bomLength(Charset charset) => switch (charset) {
      Charset.utf8 => 3,
      Charset.utf16le || Charset.utf16be => 2,
      _ => 0,
    };

Charset? _detectBomlessUtf16(Uint8List bytes) {
  if (bytes.length < 16) return null;
  final sample = bytes.length > 4096 ? 4096 : bytes.length;
  var evenNuls = 0;
  var oddNuls = 0;
  for (var i = 0; i + 1 < sample; i += 2) {
    if (bytes[i] == 0) evenNuls++;
    if (bytes[i + 1] == 0) oddNuls++;
  }
  final pairs = sample ~/ 2;
  // Latin-script text in UTF-16 is roughly half NUL bytes, all on one side.
  if (oddNuls > pairs * 0.4 && evenNuls < pairs * 0.05) return Charset.utf16le;
  if (evenNuls > pairs * 0.4 && oddNuls < pairs * 0.05) return Charset.utf16be;
  return null;
}

bool _isValidUtf8(Uint8List bytes) {
  try {
    const Utf8Decoder(allowMalformed: false).convert(bytes);
    return true;
  } on FormatException {
    return false;
  }
}

/// Validates and scores one legacy encoding against a byte buffer.
class _LegacyScorer {
  const _LegacyScorer({
    required this.charset,
    required this.next,
    required this.frequentLeads,
    this.basePriority = 0,
  });

  final Charset charset;

  /// Consumes one character starting at [index], returning its byte length, or
  /// null if the bytes are not valid in this encoding.
  final int? Function(Uint8List bytes, int index) next;

  /// Lead bytes of the encoding's most common characters. For CJK encodings
  /// these are the kana or common-hanzi blocks, which dominate real text.
  final Set<int> frequentLeads;

  /// Nudges ties in favour of the encoding more likely to be seen in the wild.
  final double basePriority;

  /// Returns a confidence, or null if [bytes] are invalid in this encoding.
  double? score(Uint8List bytes) {
    var index = 0;
    var multiByte = 0;
    var frequent = 0;

    while (index < bytes.length) {
      final length = next(bytes, index);
      if (length == null) return null;
      if (length > 1) {
        multiByte++;
        if (frequentLeads.contains(bytes[index])) frequent++;
      }
      index += length;
    }

    if (multiByte == 0) return null;
    final ratio = frequent / multiByte;
    // Blend the frequency ratio with a floor, so an encoding that merely
    // validates still beats the Windows-1252 fallback.
    return (0.35 + 0.6 * ratio + basePriority).clamp(0.0, 1.0);
  }
}

bool _inRange(int value, int low, int high) => value >= low && value <= high;

int? _nextShiftJis(Uint8List bytes, int index) {
  final b = bytes[index];
  if (b < 0x80) return 1;
  // Half-width katakana occupy the single-byte high range.
  if (_inRange(b, 0xA1, 0xDF)) return 1;
  if (_inRange(b, 0x81, 0x9F) || _inRange(b, 0xE0, 0xFC)) {
    if (index + 1 >= bytes.length) return null;
    final t = bytes[index + 1];
    if (_inRange(t, 0x40, 0x7E) || _inRange(t, 0x80, 0xFC)) return 2;
  }
  return null;
}

int? _nextEucJp(Uint8List bytes, int index) {
  final b = bytes[index];
  if (b < 0x80) return 1;
  if (b == 0x8E) {
    // Half-width katakana.
    if (index + 1 >= bytes.length) return null;
    return _inRange(bytes[index + 1], 0xA1, 0xDF) ? 2 : null;
  }
  if (b == 0x8F) {
    if (index + 2 >= bytes.length) return null;
    return _inRange(bytes[index + 1], 0xA1, 0xFE) &&
            _inRange(bytes[index + 2], 0xA1, 0xFE)
        ? 3
        : null;
  }
  if (_inRange(b, 0xA1, 0xFE)) {
    if (index + 1 >= bytes.length) return null;
    return _inRange(bytes[index + 1], 0xA1, 0xFE) ? 2 : null;
  }
  return null;
}

int? _nextGb18030(Uint8List bytes, int index) {
  final b = bytes[index];
  if (b < 0x80) return 1;
  if (b == 0x80 || b == 0xFF) return null;
  if (index + 1 >= bytes.length) return null;
  final t = bytes[index + 1];
  // Four-byte form: lead, 0x30-0x39, lead, 0x30-0x39.
  if (_inRange(t, 0x30, 0x39)) {
    if (index + 3 >= bytes.length) return null;
    return _inRange(bytes[index + 2], 0x81, 0xFE) &&
            _inRange(bytes[index + 3], 0x30, 0x39)
        ? 4
        : null;
  }
  if (_inRange(t, 0x40, 0x7E) || _inRange(t, 0x80, 0xFE)) return 2;
  return null;
}

int? _nextBig5(Uint8List bytes, int index) {
  final b = bytes[index];
  if (b < 0x80) return 1;
  if (!_inRange(b, 0xA1, 0xF9)) return null;
  if (index + 1 >= bytes.length) return null;
  final t = bytes[index + 1];
  return _inRange(t, 0x40, 0x7E) || _inRange(t, 0xA1, 0xFE) ? 2 : null;
}

int? _nextEucKr(Uint8List bytes, int index) {
  final b = bytes[index];
  if (b < 0x80) return 1;
  if (!_inRange(b, 0x81, 0xFE)) return null;
  if (index + 1 >= bytes.length) return null;
  final t = bytes[index + 1];
  return _inRange(t, 0x41, 0x5A) ||
          _inRange(t, 0x61, 0x7A) ||
          _inRange(t, 0x81, 0xFE)
      ? 2
      : null;
}

final List<_LegacyScorer> _legacyScorers = [
  _LegacyScorer(
    charset: Charset.shiftJis,
    next: _nextShiftJis,
    // 0x82 covers hiragana, 0x83 katakana, 0x88-0x9F the common kanji block.
    frequentLeads: {0x82, 0x83, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F},
    basePriority: 0.05,
  ),
  _LegacyScorer(
    charset: Charset.eucJp,
    next: _nextEucJp,
    // 0xA4 hiragana, 0xA5 katakana, 0xB0-0xC6 the most common kanji rows.
    frequentLeads: {
      0xA4, 0xA5, 0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, //
      0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0xC1, 0xC2,
    },
  ),
  _LegacyScorer(
    charset: Charset.gb18030,
    next: _nextGb18030,
    // 0xB0-0xD7 is the GB2312 level-1 (most frequent) hanzi block.
    frequentLeads: {
      0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, //
      0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5,
      0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF, 0xD0,
      0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7,
    },
  ),
  _LegacyScorer(
    charset: Charset.big5,
    next: _nextBig5,
    // 0xA4-0xC6 is the frequently-used hanzi block.
    frequentLeads: {
      0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, //
      0xAF, 0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9,
      0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4,
      0xC5, 0xC6,
    },
  ),
  _LegacyScorer(
    charset: Charset.eucKr,
    next: _nextEucKr,
    // 0xB0-0xC8 holds the precomposed hangul syllables in common use.
    frequentLeads: {
      0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, //
      0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5,
      0xC6, 0xC7, 0xC8,
    },
  ),
];

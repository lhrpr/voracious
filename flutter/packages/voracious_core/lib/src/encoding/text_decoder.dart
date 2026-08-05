/// Decoding subtitle bytes to Dart strings.
///
/// Unicode and the single-byte Western encodings decode here, in pure Dart.
/// The CJK legacy encodings deliberately do not: their mapping tables run to
/// tens of thousands of entries each, and every platform Voracious targets
/// already ships them (`NSString` encodings on Apple, `Charset` on Android,
/// `MultiByteToWideChar` on Windows). The host application registers a decoder
/// backed by the OS through [TextDecoderRegistry], and core keeps the detection
/// logic — the part worth unit testing — to itself.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'charset.dart';
import 'charset_detector.dart';

/// Decodes bytes in one specific character set.
abstract interface class CharsetDecoder {
  /// The charset this decoder handles.
  Charset get charset;

  /// Decodes [bytes], substituting U+FFFD for anything unmappable.
  String decode(Uint8List bytes);
}

/// Thrown when a file needs a charset for which no decoder is registered.
class MissingCharsetDecoderException implements Exception {
  const MissingCharsetDecoderException(this.charset);

  final Charset charset;

  @override
  String toString() =>
      'MissingCharsetDecoderException: no decoder registered for '
      '${charset.name}. Register one with TextDecoderRegistry.instance.register '
      'during app start-up (see package documentation).';
}

/// Holds the decoders available to this process.
///
/// Built-in decoders for UTF-8, UTF-16 and the single-byte Western encodings
/// are present from the start; platform-backed CJK decoders are registered by
/// the host application.
class TextDecoderRegistry {
  TextDecoderRegistry() {
    for (final decoder in const [
      _Utf8Decoder(),
      _Utf16Decoder(Charset.utf16le),
      _Utf16Decoder(Charset.utf16be),
      _SingleByteDecoder(Charset.latin1, null),
      _SingleByteDecoder(Charset.windows1252, _windows1252High),
      _SingleByteDecoder(Charset.windows1251, _windows1251High),
    ]) {
      register(decoder);
    }
  }

  /// The registry used by [decodeSubtitleBytes].
  static final TextDecoderRegistry instance = TextDecoderRegistry();

  final Map<Charset, CharsetDecoder> _decoders = {};

  /// Registers [decoder], replacing any previous decoder for its charset.
  void register(CharsetDecoder decoder) => _decoders[decoder.charset] = decoder;

  bool supports(Charset charset) => _decoders.containsKey(charset);

  /// Charsets this registry can currently decode.
  Set<Charset> get supported => _decoders.keys.toSet();

  CharsetDecoder? decoderFor(Charset charset) => _decoders[charset];

  /// Decodes [bytes] as [charset], throwing
  /// [MissingCharsetDecoderException] if no decoder is registered.
  String decode(Uint8List bytes, Charset charset) {
    final decoder = _decoders[charset];
    if (decoder == null) throw MissingCharsetDecoderException(charset);
    return decoder.decode(_stripBom(bytes, charset));
  }

  static Uint8List _stripBom(Uint8List bytes, Charset charset) {
    final length = bomLength(charset);
    if (length == 0 || bytes.length < length) return bytes;
    final actual = detectBom(bytes);
    if (actual != charset) return bytes;
    return Uint8List.sublistView(bytes, length);
  }
}

/// The result of decoding a subtitle file: the text plus what it was read as.
class DecodedText {
  const DecodedText(this.text, this.charset, this.confidence);

  final String text;
  final Charset charset;
  final double confidence;

  @override
  String toString() =>
      'DecodedText(${charset.name}, ${(confidence * 100).round()}% confident, '
      '${text.length} chars)';
}

/// Detects the encoding of [bytes] and decodes them.
///
/// [override] forces a specific charset, for when the user has corrected a bad
/// guess. Otherwise the ranked guesses from [detectCharset] are tried in order
/// and the first one with a registered decoder wins, so a Shift_JIS file still
/// opens (as Windows-1252 mojibake, flagged by a low [DecodedText.confidence])
/// on a host that registered no CJK decoder rather than failing outright.
DecodedText decodeSubtitleBytes(
  Uint8List bytes, {
  Charset? override,
  TextDecoderRegistry? registry,
}) {
  final resolved = registry ?? TextDecoderRegistry.instance;

  if (override != null) {
    return DecodedText(resolved.decode(bytes, override), override, 1);
  }

  for (final guess in detectCharset(bytes)) {
    if (resolved.supports(guess.charset)) {
      return DecodedText(
        resolved.decode(bytes, guess.charset),
        guess.charset,
        guess.confidence,
      );
    }
  }

  // windows-1252 is always registered, so this is unreachable in practice.
  return DecodedText(
    resolved.decode(bytes, Charset.windows1252),
    Charset.windows1252,
    0,
  );
}

class _Utf8Decoder implements CharsetDecoder {
  const _Utf8Decoder();

  @override
  Charset get charset => Charset.utf8;

  @override
  String decode(Uint8List bytes) =>
      const Utf8Decoder(allowMalformed: true).convert(bytes);
}

class _Utf16Decoder implements CharsetDecoder {
  const _Utf16Decoder(this.charset);

  @override
  final Charset charset;

  bool get _littleEndian => charset == Charset.utf16le;

  @override
  String decode(Uint8List bytes) {
    final unitCount = bytes.length ~/ 2;
    final units = Uint16List(unitCount);
    for (var i = 0; i < unitCount; i++) {
      final low = bytes[i * 2];
      final high = bytes[i * 2 + 1];
      units[i] = _littleEndian ? (high << 8) | low : (low << 8) | high;
    }
    return String.fromCharCodes(units);
  }
}

/// Decodes an 8-bit encoding whose 0x00-0x7F range is ASCII.
///
/// [highTable] maps the 128 bytes from 0x80 upward to code points; a null table
/// means the byte value is the code point (ISO-8859-1).
class _SingleByteDecoder implements CharsetDecoder {
  const _SingleByteDecoder(this.charset, this.highTable);

  @override
  final Charset charset;

  final List<int>? highTable;

  @override
  String decode(Uint8List bytes) {
    final table = highTable;
    final codeUnits = List<int>.filled(bytes.length, 0);
    for (var i = 0; i < bytes.length; i++) {
      final byte = bytes[i];
      codeUnits[i] = byte < 0x80 || table == null ? byte : table[byte - 0x80];
    }
    return String.fromCharCodes(codeUnits);
  }
}

/// Windows-1252 upper half. Identical to ISO-8859-1 except for 0x80-0x9F,
/// where Microsoft placed typographic punctuation; those bytes are what turn
/// curly quotes into question marks when a file is misread.
const List<int> _windows1252High = [
  0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
  0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
  0x00A0, 0x00A1, 0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x00A6, 0x00A7,
  0x00A8, 0x00A9, 0x00AA, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF,
  0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7,
  0x00B8, 0x00B9, 0x00BA, 0x00BB, 0x00BC, 0x00BD, 0x00BE, 0x00BF,
  0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5, 0x00C6, 0x00C7,
  0x00C8, 0x00C9, 0x00CA, 0x00CB, 0x00CC, 0x00CD, 0x00CE, 0x00CF,
  0x00D0, 0x00D1, 0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6, 0x00D7,
  0x00D8, 0x00D9, 0x00DA, 0x00DB, 0x00DC, 0x00DD, 0x00DE, 0x00DF,
  0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, 0x00E6, 0x00E7,
  0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x00EC, 0x00ED, 0x00EE, 0x00EF,
  0x00F0, 0x00F1, 0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, 0x00F7,
  0x00F8, 0x00F9, 0x00FA, 0x00FB, 0x00FC, 0x00FD, 0x00FE, 0x00FF,
];

/// Windows-1251 upper half (Cyrillic).
const List<int> _windows1251High = [
  0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
  0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x0098, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
  0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
  0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
  0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
  0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
  0x0410, 0x0411, 0x0412, 0x0413, 0x0414, 0x0415, 0x0416, 0x0417,
  0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E, 0x041F,
  0x0420, 0x0421, 0x0422, 0x0423, 0x0424, 0x0425, 0x0426, 0x0427,
  0x0428, 0x0429, 0x042A, 0x042B, 0x042C, 0x042D, 0x042E, 0x042F,
  0x0430, 0x0431, 0x0432, 0x0433, 0x0434, 0x0435, 0x0436, 0x0437,
  0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E, 0x043F,
  0x0440, 0x0441, 0x0442, 0x0443, 0x0444, 0x0445, 0x0446, 0x0447,
  0x0448, 0x0449, 0x044A, 0x044B, 0x044C, 0x044D, 0x044E, 0x044F,
];

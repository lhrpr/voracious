import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group('BOM detection', () {
    test('recognises UTF-8 and UTF-16 marks', () {
      expect(detectBom(bytes([0xEF, 0xBB, 0xBF, 0x41])), Charset.utf8);
      expect(detectBom(bytes([0xFF, 0xFE, 0x41, 0x00])), Charset.utf16le);
      expect(detectBom(bytes([0xFE, 0xFF, 0x00, 0x41])), Charset.utf16be);
      expect(detectBom(bytes([0x41, 0x42])), isNull);
    });

    test('a BOM is decisive', () {
      final guesses = detectCharset(bytes([0xEF, 0xBB, 0xBF, 0x41]));
      expect(guesses.first.charset, Charset.utf8);
      expect(guesses.first.confidence, 1);
    });
  });

  group('charset detection', () {
    test('pure ASCII reads as UTF-8', () {
      expect(
          detectCharsetBest(bytes(utf8.encode('Hello, world!'))), Charset.utf8);
    });

    test('detects UTF-8 Japanese', () {
      final data = bytes(utf8.encode('こんにちは、世界。今日はいい天気ですね。'));
      expect(detectCharsetBest(data), Charset.utf8);
    });

    test('detects Shift_JIS over the alternatives', () {
      // 「こんにちは」 in Shift_JIS: lead bytes 0x82 (hiragana block).
      final data = bytes([
        0x82, 0xB1, 0x82, 0xF1, 0x82, 0xC9, 0x82, 0xBF, 0x82, 0xCD, //
        0x81, 0x41, 0x82, 0xB1, 0x82, 0xF1, 0x82, 0xC9, 0x82, 0xBF,
        0x82, 0xCD, 0x81, 0x41, 0x82, 0xB1, 0x82, 0xF1,
      ]);
      final guesses = detectCharset(data);
      expect(guesses.first.charset, Charset.shiftJis);
      expect(guesses.first.confidence, greaterThan(0.8));
    });

    test('detects EUC-JP over the alternatives', () {
      // 「こんにちは」 in EUC-JP: hiragana lead byte 0xA4.
      final data = bytes([
        0xA4, 0xB3, 0xA4, 0xF3, 0xA4, 0xCB, 0xA4, 0xC1, 0xA4, 0xCF, //
        0xA4, 0xB3, 0xA4, 0xF3, 0xA4, 0xCB, 0xA4, 0xC1, 0xA4, 0xCF,
        0xA4, 0xB3, 0xA4, 0xF3,
      ]);
      expect(detectCharset(data).first.charset, Charset.eucJp);
    });

    test('rejects encodings whose byte structure the data violates', () {
      // 0xFF is not a valid Shift_JIS lead byte.
      final data = bytes([0x41, 0xFF, 0xFF, 0x42]);
      final guesses = detectCharset(data);
      expect(guesses.map((g) => g.charset), isNot(contains(Charset.shiftJis)));
    });

    test('always offers windows-1252 as a last resort', () {
      final guesses = detectCharset(bytes([0x41, 0xFF, 0xFE, 0x42, 0xFF]));
      expect(guesses.map((g) => g.charset), contains(Charset.windows1252));
    });

    test('detects BOM-less UTF-16LE from its NUL pattern', () {
      final text = 'Hello there, this is a subtitle line.';
      final data = <int>[];
      for (final unit in text.codeUnits) {
        data
          ..add(unit & 0xFF)
          ..add(unit >> 8);
      }
      expect(detectCharsetBest(bytes(data)), Charset.utf16le);
    });

    test('an empty file is treated as UTF-8', () {
      expect(detectCharsetBest(bytes([])), Charset.utf8);
    });
  });

  group('decoding', () {
    test('decodes UTF-8 and strips the BOM', () {
      final data = bytes([0xEF, 0xBB, 0xBF, ...utf8.encode('こんにちは')]);
      final decoded = decodeSubtitleBytes(data);
      expect(decoded.charset, Charset.utf8);
      expect(decoded.text, 'こんにちは');
    });

    test('decodes UTF-16LE', () {
      final data = bytes([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00]);
      expect(decodeSubtitleBytes(data).text, 'Hi');
    });

    test('decodes windows-1252 typographic punctuation', () {
      // 0x93/0x94 are smart quotes in windows-1252 and control codes in
      // ISO-8859-1; getting this wrong is the classic subtitle mojibake.
      final decoded = TextDecoderRegistry.instance
          .decode(bytes([0x93, 0x41, 0x94]), Charset.windows1252);
      expect(decoded, '“A”');
    });

    test('decodes windows-1251 Cyrillic', () {
      final decoded = TextDecoderRegistry.instance.decode(
          bytes([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]), Charset.windows1251);
      expect(decoded, 'Привет');
    });

    test('reports a missing decoder rather than guessing', () {
      final registry = TextDecoderRegistry();
      expect(registry.supports(Charset.shiftJis), isFalse);
      expect(
        () => registry.decode(bytes([0x82, 0xB1]), Charset.shiftJis),
        throwsA(isA<MissingCharsetDecoderException>()),
      );
    });

    test(
        'falls back to a registered charset when the best guess has no '
        'decoder', () {
      final data = bytes([
        0x82, 0xB1, 0x82, 0xF1, 0x82, 0xC9, 0x82, 0xBF, 0x82, 0xCD, //
        0x82, 0xB1, 0x82, 0xF1, 0x82, 0xC9, 0x82, 0xBF, 0x82, 0xCD,
      ]);
      final decoded = decodeSubtitleBytes(data);
      // No Shift_JIS decoder is registered by default, so this comes back as
      // mojibake — but with a low confidence the UI can act on.
      expect(decoded.charset, Charset.windows1252);
      expect(decoded.confidence, lessThan(0.5));
    });

    test('a registered platform decoder is used', () {
      final registry = TextDecoderRegistry()..register(_FakeShiftJisDecoder());
      final data = bytes([0x82, 0xB1, 0x82, 0xF1]);
      final decoded = decodeSubtitleBytes(data, registry: registry);
      expect(decoded.charset, Charset.shiftJis);
      expect(decoded.text, 'こん');
    });

    test('an override wins over detection', () {
      final data = bytes(utf8.encode('Hello'));
      final decoded = decodeSubtitleBytes(data, override: Charset.latin1);
      expect(decoded.charset, Charset.latin1);
      expect(decoded.confidence, 1);
    });
  });

  group('Charset lookup', () {
    test('resolves aliases case-insensitively', () {
      expect(Charset.byName('shift-jis'), Charset.shiftJis);
      expect(Charset.byName('CP932'), Charset.shiftJis);
      expect(Charset.byName('utf-8'), Charset.utf8);
      expect(Charset.byName('nonsense'), isNull);
    });

    test('knows which charsets need a platform codec', () {
      expect(Charset.shiftJis.requiresPlatformCodec, isTrue);
      expect(Charset.utf8.requiresPlatformCodec, isFalse);
      expect(Charset.windows1252.requiresPlatformCodec, isFalse);
    });
  });
}

/// Stands in for a platform-backed decoder, covering just enough of Shift_JIS
/// to prove the registry wiring.
class _FakeShiftJisDecoder implements CharsetDecoder {
  static const Map<int, String> _table = {0x82B1: 'こ', 0x82F1: 'ん'};

  @override
  Charset get charset => Charset.shiftJis;

  @override
  String decode(Uint8List bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      buffer.write(_table[(bytes[i] << 8) | bytes[i + 1]] ?? '�');
    }
    return buffer.toString();
  }
}

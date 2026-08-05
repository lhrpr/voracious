import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

void main() {
  group('timestamps', () {
    test('parses every supported shape', () {
      expect(parseTimestamp('00:00:01,500'),
          const Duration(seconds: 1, milliseconds: 500));
      expect(parseTimestamp('0:00:01.50'),
          const Duration(seconds: 1, milliseconds: 500));
      expect(parseTimestamp('01:30.250'),
          const Duration(minutes: 1, seconds: 30, milliseconds: 250));
      expect(parseTimestamp('1:02:03.004'),
          const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 4));
    });

    test('pads a short fraction rather than misreading it', () {
      // ASS centiseconds: ".5" is 500ms, ".05" is 50ms.
      expect(parseTimestamp('0:00:00.5').inMilliseconds, 500);
      expect(parseTimestamp('0:00:00.05').inMilliseconds, 50);
    });

    test('rejects non-timestamps',
        () => expect(tryParseTimestamp('nope'), isNull));

    test('formats round trip', () {
      const duration =
          Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 4);
      expect(formatSrtTimestamp(duration), '01:02:03,004');
      expect(formatVttTimestamp(duration), '01:02:03.004');
      expect(parseTimestamp(formatSrtTimestamp(duration)), duration);
    });
  });

  group('text cleaning', () {
    test('strips ASS override blocks', () {
      expect(cleanSubtitleText(r'{\i1}Hello{\i0} there'), 'Hello there');
    });

    test('strips HTML-ish inline tags', () {
      expect(cleanSubtitleText('<i>Hello</i> <font color="#fff">there</font>'),
          'Hello there');
    });

    test('turns hard line breaks into newlines', () {
      expect(cleanSubtitleText(r'One\NTwo'), 'One\nTwo');
      expect(cleanSubtitleText('One<br>Two'), 'One\nTwo');
      expect(cleanSubtitleText(r'One\hTwo'), 'One Two');
    });

    test('drops ASS vector drawing commands', () {
      // A sign drawn as a vector shape would otherwise leak coordinates into
      // the text and then into the tokeniser.
      expect(
        cleanSubtitleText(
            r'{\p1}m 0 0 l 100 0 100 100 0 100{\p0}Real dialogue'),
        'Real dialogue',
      );
    });

    test('keeps a literal brace that is not markup', () {
      expect(cleanSubtitleText('the set {1, 2, 3'), 'the set {1, 2, 3');
    });

    test('keeps text that merely looks like a tag', () {
      expect(cleanSubtitleText('a < b and c > d'), 'a < b and c > d');
    });

    test('strips WebVTT inline timing tags', () {
      expect(
        cleanSubtitleText('<00:00:01.000>Hello', stripOverrideBlocks: false),
        'Hello',
      );
    });

    test('decodes entities', () {
      expect(cleanSubtitleText('Tom &amp; Jerry &#65;'), 'Tom & Jerry A');
    });

    test('trims surrounding blank lines but keeps interior ones', () {
      expect(cleanSubtitleText('\n\nOne\n\nTwo\n\n'), 'One\n\nTwo');
    });
  });

  group('SRT', () {
    test('parses a normal file', () {
      final cues = parseSrt('''
1
00:00:01,000 --> 00:00:04,000
Hello there
Second line

2
00:00:05,000 --> 00:00:06,500
Goodbye
''');

      expect(cues, hasLength(2));
      expect(cues[0].begin, const Duration(seconds: 1));
      expect(cues[0].end, const Duration(seconds: 4));
      expect(cues[0].text, 'Hello there\nSecond line');
      expect(cues[1].text, 'Goodbye');
    });

    test('tolerates CRLF, a BOM and missing sequence numbers', () {
      final cues = parseSrt(
        '﻿00:00:01,000 --> 00:00:02,000\r\nHello\r\n\r\n'
        '2\r\n00:00:03,000 --> 00:00:04,000\r\nWorld\r\n',
      );
      expect(cues.map((c) => c.text), ['Hello', 'World']);
    });

    test('skips a malformed block rather than failing the file', () {
      final cues = parseSrt('''
1
this is not a timing line
Broken

2
00:00:05,000 --> 00:00:06,000
Fine
''');
      expect(cues, hasLength(1));
      expect(cues.single.text, 'Fine');
    });

    test('clamps an end time that precedes its start', () {
      final cues = parseSrt('''
1
00:00:05,000 --> 00:00:01,000
Backwards
''');
      expect(cues.single.end, cues.single.begin);
    });

    test('accepts a dot as the decimal separator', () {
      final cues = parseSrt('1\n00:00:01.000 --> 00:00:02.000\nHello\n');
      expect(cues.single.begin, const Duration(seconds: 1));
    });
  });

  group('WebVTT', () {
    test('parses cues and skips header and note blocks', () {
      final cues = parseVtt('''
WEBVTT - Some title

NOTE this is a comment
spanning two lines

STYLE
::cue { color: yellow }

intro
00:00:01.000 --> 00:00:04.000 align:start position:0%
Hello there

00:00:05.000 --> 00:00:06.000
<v Narrator>Goodbye
''');

      expect(cues, hasLength(2));
      expect(cues[0].text, 'Hello there');
      expect(cues[1].text, 'Goodbye');
    });

    test('accepts timestamps without an hours field', () {
      final cues = parseVtt('WEBVTT\n\n01:30.000 --> 01:32.000\nHello\n');
      expect(cues.single.begin, const Duration(minutes: 1, seconds: 30));
    });
  });

  group('ASS', () {
    const sample = '''
[Script Info]
Title: Example

[V4+ Styles]
Format: Name, Fontname
Style: Default,Arial
Style: Sign,Arial

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\\i1}Hello, there{\\i0}
Comment: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,translator note
Dialogue: 1,0:00:05.00,0:00:06.00,Sign,,0,0,0,,Shop sign
''';

    test('parses dialogue and ignores comments', () {
      final cues = parseAss(sample);
      expect(cues, hasLength(2));
      expect(cues[0].text, 'Hello, there',
          reason: 'commas inside the text field must survive the split');
      expect(cues[0].styleName, 'Default');
      expect(cues[1].layer, 1);
    });

    test('excludes styles on request', () {
      final cues = parseAss(sample, excludeStyles: {'sign'});
      expect(cues, hasLength(1));
      expect(cues.single.styleName, 'Default');
    });

    test('finds fields by name, so SSA v4 works too', () {
      final cues = parseAss('''
[Events]
Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: Marked=0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hello
''');
      expect(cues.single.text, 'Hello');
      expect(cues.single.begin, const Duration(seconds: 1));
    });

    test('returns nothing when there is no Events section', () {
      expect(parseAss('[Script Info]\nTitle: nothing here\n'), isEmpty);
    });
  });

  group('format detection', () {
    test('identifies by extension', () {
      expect(SubtitleFormat.fromPath('a.srt'), SubtitleFormat.srt);
      expect(SubtitleFormat.fromPath('a.ASS'), SubtitleFormat.ass);
      expect(SubtitleFormat.fromPath('a.ssa'), SubtitleFormat.ass);
      expect(SubtitleFormat.fromPath('a.mkv'), isNull);
    });

    test('sniffs content when the extension is wrong', () {
      expect(SubtitleFormat.sniff('[Script Info]\n'), SubtitleFormat.ass);
      expect(SubtitleFormat.sniff('WEBVTT\n\n'), SubtitleFormat.vtt);
      expect(
        SubtitleFormat.sniff('1\n00:00:01,000 --> 00:00:02,000\nx'),
        SubtitleFormat.srt,
      );
      expect(SubtitleFormat.sniff('nothing here'), isNull);
    });

    test('parseSubtitlesForPath falls back to sniffing', () {
      final cues = parseSubtitlesForPath(
        '1\n00:00:01,000 --> 00:00:02,000\nHello\n',
        'mystery.txt',
      );
      expect(cues.single.text, 'Hello');
    });

    test('parseSubtitlesForPath reports an unknown format', () {
      expect(
        () => parseSubtitlesForPath('nothing', 'mystery.txt'),
        throwsA(isA<UnsupportedSubtitleFormatException>()),
      );
    });
  });

  group('SubtitleCue', () {
    test('shifts timings and clamps at zero', () {
      const cue = SubtitleCue(
        begin: Duration(seconds: 1),
        end: Duration(seconds: 2),
        text: 'x',
      );
      expect(cue.shifted(const Duration(seconds: -5)).begin, Duration.zero);
      expect(cue.shifted(const Duration(seconds: 1)).begin,
          const Duration(seconds: 2));
    });
  });
}

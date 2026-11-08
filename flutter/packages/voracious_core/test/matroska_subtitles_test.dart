import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

// A tiny EBML writer, so each test builds exactly the Matroska file it needs.

List<int> _vintSize(int size) {
  for (var length = 1; length <= 8; length++) {
    if (size < (1 << (7 * length)) - 1) {
      final bytes = List<int>.filled(length, 0);
      var v = size;
      for (var i = length - 1; i >= 0; i--) {
        bytes[i] = v & 0xFF;
        v >>= 8;
      }
      bytes[0] |= 0x80 >> (length - 1);
      return bytes;
    }
  }
  throw ArgumentError(size);
}

List<int> _id(int id) {
  final bytes = <int>[];
  while (id > 0) {
    bytes.insert(0, id & 0xFF);
    id >>= 8;
  }
  return bytes;
}

List<int> el(int id, List<int> payload) =>
    [..._id(id), ..._vintSize(payload.length), ...payload];

/// An element whose size is written as "unknown".
List<int> elUnknown(int id, List<int> payload) =>
    [..._id(id), 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, ...payload];

List<int> uint(int id, int value) {
  final bytes = <int>[];
  do {
    bytes.insert(0, value & 0xFF);
    value >>= 8;
  } while (value > 0);
  return el(id, bytes);
}

List<int> str(int id, String value) => el(id, utf8.encode(value));

List<int> blockPayload(int track, int relative, List<int> data) => [
      0x80 | track,
      (relative >> 8) & 0xFF,
      relative & 0xFF,
      0x00,
      ...data,
    ];

List<int> simpleBlock(int track, int relative, List<int> data) =>
    el(0xA3, blockPayload(track, relative, data));

List<int> blockGroup(int track, int relative, int duration, List<int> data) =>
    el(0xA0, [
      ...el(0xA1, blockPayload(track, relative, data)),
      ...uint(0x9B, duration)
    ]);

List<int> cluster(int timestamp, List<List<int>> blocks) =>
    el(0x1F43B675, [...uint(0xE7, timestamp), for (final b in blocks) ...b]);

List<int> trackEntry({
  required int number,
  required int type,
  required String codec,
  String? language,
  String? bcp47,
  String? name,
  bool? forced,
  List<int>? codecPrivate,
  List<int>? encodings,
}) =>
    el(0xAE, [
      ...uint(0xD7, number),
      ...uint(0x83, type),
      ...str(0x86, codec),
      if (language != null) ...str(0x22B59C, language),
      if (bcp47 != null) ...str(0x22B59D, bcp47),
      if (name != null) ...str(0x536E, name),
      if (forced != null) ...uint(0x55AA, forced ? 1 : 0),
      if (codecPrivate != null) ...el(0x63A2, codecPrivate),
      if (encodings != null) ...encodings,
    ]);

List<int> compression(int algorithm, [List<int>? settings]) => el(0x6D80, [
      ...el(0x6240, [
        ...el(0x5034, [
          ...uint(0x4254, algorithm),
          if (settings != null) ...el(0x4255, settings),
        ]),
      ]),
    ]);

Uint8List mkv({
  required List<List<int>> tracks,
  required List<List<int>> clusters,
  bool unknownSizeSegment = false,
}) {
  final body = [
    ...el(0x1549A966, uint(0x2AD7B1, 1000000)), // 1 ms timestamps.
    ...el(0x1654AE6B, [for (final t in tracks) ...t]),
    for (final c in clusters) ...c,
  ];
  return Uint8List.fromList([
    ...el(0x1A45DFA3, str(0x4282, 'matroska')),
    ...(unknownSizeSegment
        ? elUnknown(0x18538067, body)
        : el(0x18538067, body)),
  ]);
}

const _video = 1;
const _subtitle = 0x11;

/// A fake video frame, big enough that skipping it unread matters.
final _frame = List<int>.filled(3000, 0x42);

MatroskaSubtitleReader reader(Uint8List bytes) => MatroskaSubtitleReader(
      MemoryByteSource(bytes),
      inflate: (b) => Uint8List.fromList(zlib.decode(b)),
    );

void main() {
  test('recognises the EBML magic number', () {
    expect(
      MatroskaSubtitleReader.looksLikeMatroska(
          Uint8List.fromList([0x1A, 0x45, 0xDF, 0xA3, 0])),
      isTrue,
    );
    expect(
      MatroskaSubtitleReader.looksLikeMatroska(utf8.encode('ftypisom')),
      isFalse,
    );
  });

  test('lists subtitle tracks with their metadata', () {
    final file = mkv(
      tracks: [
        trackEntry(number: 1, type: _video, codec: 'V_MPEG4/ISO/AVC'),
        trackEntry(
            number: 2, type: _subtitle, codec: 'S_TEXT/ASS', language: 'fre'),
        trackEntry(
          number: 3,
          type: _subtitle,
          codec: 'S_TEXT/UTF8',
          language: 'und',
          bcp47: 'ja-JP',
          name: 'Signs [Forced]',
        ),
        trackEntry(number: 4, type: _subtitle, codec: 'S_HDMV/PGS'),
      ],
      clusters: [],
    );

    final tracks = reader(file).subtitleTracks();
    expect(tracks.map((t) => t.number), [2, 3, 4]);

    // Bibliographic ISO 639-2 codes map to the canonical form.
    expect(tracks[0].languageCode, 'fra');
    expect(tracks[0].format, SubtitleFormat.ass);

    // BCP 47 wins over the legacy field; the title marks it forced.
    expect(tracks[1].languageCode, 'jpn');
    expect(tracks[1].isForced, isTrue);
    expect(tracks[1].name, 'Signs [Forced]');

    // Image-based: listed, but not text.
    expect(tracks[2].isText, isFalse);
    expect(tracks[2].languageCode, isNull);
  });

  test('rebuilds an SRT track, skipping video blocks', () {
    final file = mkv(
      tracks: [
        trackEntry(number: 1, type: _video, codec: 'V_MPEG4/ISO/AVC'),
        trackEntry(number: 2, type: _subtitle, codec: 'S_TEXT/UTF8'),
      ],
      clusters: [
        cluster(0, [
          simpleBlock(1, 0, _frame),
          blockGroup(2, 500, 1000, utf8.encode('Hello, there')),
          simpleBlock(1, 40, _frame),
        ]),
        cluster(60000, [
          simpleBlock(1, 0, _frame),
          blockGroup(2, 1500, 2250, utf8.encode('Line one\nLine two')),
        ]),
      ],
    );

    final [extracted] = reader(file).extract();
    expect(extracted.cueCount, 2);
    expect(
      extracted.contents,
      '1\n00:00:00,500 --> 00:00:01,500\nHello, there\n\n'
      '2\n00:01:01,500 --> 00:01:03,750\nLine one\nLine two\n\n',
    );

    // And it round-trips through the ordinary parser.
    final cues = parseSubtitles(extracted.contents, SubtitleFormat.srt);
    expect(cues.map((c) => c.text), ['Hello, there', 'Line one\nLine two']);
    expect(cues[1].begin, const Duration(minutes: 1, milliseconds: 1500));
  });

  test('rebuilds an ASS track with its styles, in time order', () {
    const header = '[Script Info]\r\nScriptType: v4.00+\r\n\r\n'
        '[V4+ Styles]\r\nFormat: Name, Fontname, Fontsize\r\n'
        'Style: Default,Arial,20\r\nStyle: Sign,Arial,30\r\n\r\n'
        '[Events]\r\nFormat: Layer, Start, End, Style, Name, MarginL, '
        'MarginR, MarginV, Effect, Text';
    final file = mkv(
      tracks: [
        trackEntry(
          number: 3,
          type: _subtitle,
          codec: 'S_TEXT/ASS',
          codecPrivate: utf8.encode(header),
        ),
      ],
      clusters: [
        cluster(0, [
          // Muxed out of time order, as happens with overlapping lines.
          blockGroup(3, 4000, 1000,
              utf8.encode('1,0,Default,,0,0,0,,Second, with a comma')),
          blockGroup(3, 1000, 2000,
              utf8.encode(r'0,0,Default,,0,0,0,,{\i1}First{\i0}')),
          blockGroup(3, 1000, 2000, utf8.encode('2,1,Sign,,0,0,0,,EXIT')),
        ]),
      ],
    );

    final [extracted] = reader(file).extract();
    final lines = extracted.contents
        .split('\n')
        .where((l) => l.startsWith('Dialogue:'))
        .toList();
    expect(lines, [
      r'Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\i1}First{\i0}',
      'Dialogue: 1,0:00:01.00,0:00:03.00,Sign,,0,0,0,,EXIT',
      'Dialogue: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,Second, with a comma',
    ]);
    expect(extracted.contents, contains('Style: Sign,Arial,30'));

    // Through the real parser, with sign styles filtered as the app does.
    final cues = parseSubtitles(
      extracted.contents,
      SubtitleFormat.ass,
      excludeAssStyles: {'sign'},
    );
    expect(cues.map((c) => c.text), ['First', 'Second, with a comma']);
  });

  test('inflates zlib-compressed tracks and restores stripped headers', () {
    final file = mkv(
      tracks: [
        trackEntry(
          number: 2,
          type: _subtitle,
          codec: 'S_TEXT/UTF8',
          encodings: compression(0),
        ),
        trackEntry(
          number: 3,
          type: _subtitle,
          codec: 'S_TEXT/UTF8',
          encodings: compression(3, utf8.encode('Hel')),
        ),
      ],
      clusters: [
        cluster(0, [
          blockGroup(2, 0, 1000, zlib.encode(utf8.encode('Compressed line'))),
          blockGroup(3, 0, 1000, utf8.encode('lo world')),
        ]),
      ],
    );

    final extracted = reader(file).extract();
    expect(extracted[0].contents, contains('Compressed line'));
    expect(extracted[1].contents, contains('Hello world'));
  });

  test('skips compressed tracks when no inflater is available', () {
    final file = mkv(
      tracks: [
        trackEntry(
          number: 2,
          type: _subtitle,
          codec: 'S_TEXT/UTF8',
          encodings: compression(0),
        ),
      ],
      clusters: [],
    );
    expect(
      MatroskaSubtitleReader(MemoryByteSource(file)).extract(),
      isEmpty,
    );
  });

  test('handles unknown-size segments and clusters', () {
    final body = [
      ...el(0x1549A966, uint(0x2AD7B1, 1000000)),
      ...el(0x1654AE6B, [
        ...trackEntry(number: 1, type: _video, codec: 'V_VP9'),
        ...trackEntry(number: 2, type: _subtitle, codec: 'S_TEXT/WEBVTT'),
      ]),
      ...elUnknown(0x1F43B675, [
        ...uint(0xE7, 0),
        ...simpleBlock(1, 0, _frame),
        ...blockGroup(2, 100, 900, utf8.encode('One')),
      ]),
      ...elUnknown(0x1F43B675, [
        ...uint(0xE7, 10000),
        ...simpleBlock(1, 0, _frame),
        ...blockGroup(2, 0, 500, utf8.encode('Two')),
      ]),
    ];
    final file = Uint8List.fromList([
      ...el(0x1A45DFA3, str(0x4282, 'webm')),
      ...elUnknown(0x18538067, body),
    ]);

    final [extracted] = reader(file).extract();
    expect(extracted.cueCount, 2);
    final cues = parseSubtitles(extracted.contents, SubtitleFormat.vtt);
    expect(cues.map((c) => c.text), ['One', 'Two']);
    expect(cues[1].begin, const Duration(seconds: 10));
    expect(cues[1].end, const Duration(seconds: 10, milliseconds: 500));
  });

  test('gives blocks without a duration an end at the next line', () {
    final file = mkv(
      tracks: [trackEntry(number: 2, type: _subtitle, codec: 'S_TEXT/UTF8')],
      clusters: [
        cluster(0, [
          simpleBlock(2, 0, utf8.encode('A')),
          simpleBlock(2, 2000, utf8.encode('B')),
        ]),
      ],
    );
    final cues = parseSubtitles(
      reader(file).extract().single.contents,
      SubtitleFormat.srt,
    );
    expect(cues[0].end, const Duration(seconds: 2));
    expect(cues[1].end, const Duration(seconds: 7)); // Five-second fallback.
  });

  test('rejects files that are not Matroska', () {
    expect(
      () => reader(Uint8List.fromList(utf8.encode('not a video at all')))
          .subtitleTracks(),
      throwsFormatException,
    );
  });
}

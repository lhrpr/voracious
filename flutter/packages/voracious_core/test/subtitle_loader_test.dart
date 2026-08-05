/// End-to-end through the library layer: scan a collection, then load one of
/// its subtitle files all the way to a studyable cue index.
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

const String japaneseSrt = '''
1
00:00:01,000 --> 00:00:04,000
<i>お茶を飲む。</i>

2
00:00:05,000 --> 00:00:08,000
食べる。
''';

const String englishSrt = '''
1
00:00:01,000 --> 00:00:04,000
I drink tea.

2
00:00:05,000 --> 00:00:08,000
I eat.
''';

/// Tokenises the two sentences above from a fixed table.
class ScriptedJapaneseTokenizer implements Tokenizer {
  @override
  String get languageCode => 'jpn';

  @override
  bool get isReady => true;

  @override
  Future<void> ensureReady() async {}

  @override
  Future<List<LanguageToken>> tokenize(String text) async => switch (text) {
        'お茶を飲む。' => const [
            LanguageToken(
              surface: 'お茶',
              cpBegin: 0,
              cpEnd: 2,
              lemma: 'お茶',
              reading: 'オチャ',
            ),
            LanguageToken(surface: 'を', cpBegin: 2, cpEnd: 3),
            LanguageToken(
              surface: '飲む',
              cpBegin: 3,
              cpEnd: 5,
              lemma: '飲む',
              reading: 'ノム',
            ),
            LanguageToken(
              surface: '。',
              cpBegin: 5,
              cpEnd: 6,
              isPunctuation: true,
            ),
          ],
        '食べる。' => const [
            LanguageToken(
              surface: '食べる',
              cpBegin: 0,
              cpEnd: 3,
              lemma: '食べる',
              reading: 'タベル',
            ),
            LanguageToken(
              surface: '。',
              cpBegin: 3,
              cpEnd: 4,
              isPunctuation: true,
            ),
          ],
        _ => const [],
      };
}

void main() {
  late InMemoryFileSystem fs;
  late MediaCollectionIndex index;
  late SubtitleTrackLoader loader;

  setUp(() async {
    fs = InMemoryFileSystem({
      '/media/Some Show/Some Show S01E01.mkv': '',
      '/media/Some Show/Some Show S01E01.ja.srt': japaneseSrt,
      '/media/Some Show/Some Show S01E01.en.srt': englishSrt,
      '/media/Some Show/Some Show S01E02.mkv': '',
    });

    index = await MediaScanner(fileSystem: fs).scan('/media');

    loader = SubtitleTrackLoader(
      fileSystem: fs,
      analyzer: TextAnalyzer()..register(ScriptedJapaneseTokenizer()),
    );
  });

  test('scanning finds the episodes and pairs their subtitles', () {
    expect(index.videos, hasLength(2));
    final first = index.videoById('Some Show/Some Show S01E01.mkv')!;
    expect(first.subtitleFiles, hasLength(2));
    expect(index.videoById('Some Show/Some Show S01E02.mkv')!.subtitleFiles,
        isEmpty);
  });

  test('loads, decodes, parses and analyses a Japanese track', () async {
    final video = index.videoById('Some Show/Some Show S01E01.mkv')!;
    final reference =
        video.subtitleFiles.firstWhere((s) => s.languageCode == 'jpn');

    final track = await loader.load(reference);

    expect(track.languageCode, 'jpn');
    expect(track.languageSource, LanguageSource.fileName);
    expect(track.charset, Charset.utf8);
    expect(track.cues, hasLength(2));

    final first = track.cues[0];
    expect(first.begin, const Duration(seconds: 1));
    expect(first.text.text, 'お茶を飲む。',
        reason: 'the italic tags must be stripped');

    // Word annotations drive tap-to-look-up; ruby drives furigana.
    expect(first.text.ofKind(AnnotationKind.word), hasLength(3));
    final ruby = first.text.ofKind(AnnotationKind.ruby).cast<RubyAnnotation>();
    expect(ruby.map((r) => r.text), ['ちゃ', 'の'],
        reason: 'お茶 -> お+茶[ちゃ], 飲む -> 飲[の]+む');
  });

  test('a track with no analyzer still loads as plain text', () async {
    final video = index.videoById('Some Show/Some Show S01E01.mkv')!;
    final reference =
        video.subtitleFiles.firstWhere((s) => s.languageCode == 'eng');

    final track = await loader.load(reference);

    expect(track.languageCode, 'eng');
    expect(track.cues, hasLength(2));
    expect(track.cues[0].text.text, 'I drink tea.');
    expect(track.cues[0].text.annotations, isEmpty);
  });

  test('detects the language when the file name carries no tag', () async {
    final bare = InMemoryFileSystem({
      '/media/Movie/Movie.mkv': '',
      '/media/Movie/Movie.srt': '''
1
00:00:01,000 --> 00:00:04,000
I am not sure that this is the right thing to do with all of them.

2
00:00:05,000 --> 00:00:08,000
When they are here we can ask them what they want to do about it.
''',
    });

    final scanned = await MediaScanner(fileSystem: bare).scan('/media');
    final track = await SubtitleTrackLoader(
      fileSystem: bare,
      analyzer: TextAnalyzer(),
    ).load(scanned.videos.single.subtitleFiles.single);

    expect(track.languageSource, LanguageSource.detected);
    expect(track.languageCode, 'eng');
  });

  test('reports load progress by stage', () async {
    final video = index.videoById('Some Show/Some Show S01E01.mkv')!;
    final stages = <SubtitleLoadStage>[];

    await loader.load(
      video.subtitleFiles.first,
      onProgress: (stage, _) {
        if (stages.isEmpty || stages.last != stage) stages.add(stage);
      },
    );

    expect(stages, [
      SubtitleLoadStage.reading,
      SubtitleLoadStage.decoding,
      SubtitleLoadStage.parsing,
      SubtitleLoadStage.detectingLanguage,
      SubtitleLoadStage.analyzing,
    ]);
  });

  test('a loaded track drives a study session', () async {
    final video = index.videoById('Some Show/Some Show S01E01.mkv')!;
    final japanese = await loader.load(
      video.subtitleFiles.firstWhere((s) => s.languageCode == 'jpn'),
    );
    final english = await loader.load(
      video.subtitleFiles.firstWhere((s) => s.languageCode == 'eng'),
    );

    final ordered = orderSubtitleTracks(
      [japanese, english],
      languageOf: (t) => t.languageCode,
      idOf: (t) => t.id,
      preferredOrder: const ['jpn', 'eng'],
    );

    final session = StudySession(
      playback: _StubPlayback(),
      tracks: [
        for (final track in ordered)
          StudyTrack(
            id: track.id,
            cues: track.cues,
            languageCode: track.languageCode,
          ),
      ],
      mode: SubtitleMode.listen,
    );

    await session.onPositionChanged(
      const Duration(seconds: 2),
      isPlaying: false,
    );

    expect(session.snapshot.tracks, hasLength(2));
    expect(session.snapshot.primaryCue?.text.text, 'お茶を飲む。',
        reason: 'the studied language must come first');
    expect(session.snapshot.tracks[1].cue?.text.text, 'I drink tea.');
    expect(session.snapshot.tracks.every((t) => t.isHidden), isTrue);
  });

  test('handles a subtitle file that is not valid UTF-8', () async {
    // Latin-1 bytes: "Voilà" with 0xE0 for à, which is not valid UTF-8.
    final latin1 = <int>[
      ...utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nVoil'),
      0xE0,
      ...utf8.encode('\n'),
    ];

    final store = InMemoryFileSystem()
      ..addFile('/media/Movie/Movie.mkv')
      ..addFile('/media/Movie/Movie.fr.srt', latin1);

    final scanned = await MediaScanner(fileSystem: store).scan('/media');
    final track = await SubtitleTrackLoader(
      fileSystem: store,
      analyzer: TextAnalyzer(),
    ).load(scanned.videos.single.subtitleFiles.single);

    expect(track.cues, hasLength(1));
    expect(track.cues[0].text.text, 'Voilà');
    expect(track.charset, Charset.windows1252);
  });

  test('an empty subtitle file loads as an empty track', () async {
    final store = InMemoryFileSystem({
      '/media/Movie/Movie.mkv': '',
      '/media/Movie/Movie.en.srt': '',
    });

    final scanned = await MediaScanner(fileSystem: store).scan('/media');
    final track = await SubtitleTrackLoader(
      fileSystem: store,
      analyzer: TextAnalyzer(),
    ).load(scanned.videos.single.subtitleFiles.single);

    expect(track.isEmpty, isTrue);
    expect(track.languageCode, 'eng', reason: 'from the file name');
  });
}

class _StubPlayback implements StudyPlaybackController {
  @override
  Duration position = Duration.zero;

  @override
  bool isPlaying = false;

  @override
  Future<void> play() async => isPlaying = true;

  @override
  Future<void> pause() async => isPlaying = false;

  @override
  Future<void> seek(Duration target) async => position = target;
}

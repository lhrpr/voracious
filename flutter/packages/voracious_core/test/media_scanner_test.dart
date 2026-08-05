import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

void main() {
  group('episode numbering', () {
    test('reads SxxExx in its various spellings', () {
      expect(parseEpisodeNumbering('Show.S01E02.mkv'),
          const EpisodeNumbering(season: 1, episode: 2));
      expect(parseEpisodeNumbering('Show s1e2'),
          const EpisodeNumbering(season: 1, episode: 2));
      expect(parseEpisodeNumbering('Show S01.E02')?.episode, 2);
      expect(parseEpisodeNumbering('Show 1x02')?.season, 1);
      expect(parseEpisodeNumbering('Show Season 2 Episode 5'),
          const EpisodeNumbering(season: 2, episode: 5));
    });

    test('reads flat anime numbering', () {
      expect(parseEpisodeNumbering('Show Name - 05')?.episode, 5);
      expect(parseEpisodeNumbering('Show Name - 05 - The Title')?.episode, 5);
      expect(parseEpisodeNumbering('Show Name [12]')?.episode, 12);
      expect(parseEpisodeNumbering('Show Name 07v2')?.episode, 7);
      expect(parseEpisodeNumbering('Show Ep05')?.episode, 5);
    });

    test('captures the episode title', () {
      final numbering = parseEpisodeNumbering('Show - 05 - The Title');
      expect(numbering?.title, 'The Title');
    });

    test('does not mistake a resolution or codec for an episode', () {
      expect(parseEpisodeNumbering('Movie 1080p x264'), isNull);
      expect(parseEpisodeNumbering('Movie 2019'), isNull);
    });

    test('returns null for a plain film name', () {
      expect(parseEpisodeNumbering('Spirited Away'), isNull);
    });

    test('reads season directory names', () {
      expect(parseSeasonDirectory('Season 1'), 1);
      expect(parseSeasonDirectory('Season01'), 1);
      expect(parseSeasonDirectory('S2'), 2);
      expect(parseSeasonDirectory('Specials'), 0);
      expect(parseSeasonDirectory('Extras'), isNull);
    });
  });

  group('title prettifying', () {
    test('strips release group and metadata', () {
      expect(
          prettifyTitle('[Group] Show Name (2019) [1080p][x265]'), 'Show Name');
      expect(prettifyTitle('Movie.Name.2019.1080p.BluRay.x264'), 'Movie Name');
      expect(prettifyTitle('Show_Name_S01'), 'Show Name S01');
    });

    test('leaves an already clean name alone', () {
      expect(prettifyTitle('Spirited Away'), 'Spirited Away');
    });

    test('never returns an empty string', () {
      expect(prettifyTitle('[1080p]'), isNotEmpty);
    });
  });

  group('MediaScanner', () {
    Future<MediaCollectionIndex> scan(
      Map<String, Object> files, {
      ScanOptions options = const ScanOptions(),
    }) {
      final fs = InMemoryFileSystem(files);
      return MediaScanner(fileSystem: fs, options: options).scan('/media');
    }

    test('a missing root yields an empty index rather than throwing', () async {
      final index =
          await MediaScanner(fileSystem: InMemoryFileSystem()).scan('/nowhere');
      expect(index.videos, isEmpty);
      expect(index.titles, isEmpty);
    });

    test('videos in the root become standalone titles', () async {
      final index = await scan({
        '/media/Spirited Away.mkv': '',
        '/media/Spirited Away.ja.srt': '',
        '/media/Spirited Away.en.srt': '',
      });

      expect(index.videos, hasLength(1));
      expect(index.titles, hasLength(1));
      expect(index.titles.single.isSeries, isFalse);
      expect(index.titles.single.name, 'Spirited Away');

      final video = index.videos.single;
      expect(video.id, 'Spirited Away.mkv');
      expect(video.subtitleFiles, hasLength(2));
      expect(
        video.subtitleFiles.map((s) => s.languageCode).toSet(),
        {'jpn', 'eng'},
      );
    });

    test('a directory with one video is a standalone title', () async {
      final index = await scan({
        '/media/Spirited Away (2001)/Spirited Away.mkv': '',
        '/media/Spirited Away (2001)/Spirited Away.ja.srt': '',
      });

      expect(index.titles, hasLength(1));
      expect(index.titles.single.isSeries, isFalse);
      expect(index.titles.single.name, 'Spirited Away');
    });

    test('a directory of episodes is a series', () async {
      final index = await scan({
        '/media/Some Show/Some Show S01E01.mkv': '',
        '/media/Some Show/Some Show S01E01.ja.srt': '',
        '/media/Some Show/Some Show S01E02.mkv': '',
        '/media/Some Show/Some Show S01E03.mkv': '',
      });

      expect(index.titles, hasLength(1));
      final title = index.titles.single;
      expect(title.isSeries, isTrue);
      expect(title.episodes, hasLength(3));
      expect(title.episodes.map((e) => e.episode), [1, 2, 3]);
      expect(title.seasons, [1]);
    });

    test('season directories supply the season number', () async {
      final index = await scan({
        '/media/Some Show/Season 1/Some Show - 01.mkv': '',
        '/media/Some Show/Season 1/Some Show - 02.mkv': '',
        '/media/Some Show/Season 2/Some Show - 01.mkv': '',
      });

      final title = index.titles.single;
      expect(title.isSeries, isTrue);
      expect(title.seasons, [1, 2]);
      expect(title.episodesInSeason(2), hasLength(1));
      expect(title.episodes.first.season, 1);
      expect(title.episodes.first.episode, 1);
    });

    test('episodes sort by season then episode, extras last within a season',
        () async {
      final index = await scan({
        '/media/Show/Season 2/Show S02E01.mkv': '',
        '/media/Show/Season 1/Show S01E02.mkv': '',
        '/media/Show/Season 1/Show S01E01.mkv': '',
        '/media/Show/Season 1/Behind the scenes.mkv': '',
      });

      final episodes = index.titles.single.episodes;
      expect(
        episodes.map((e) => '${e.season}-${e.episode}'),
        ['1-1', '1-2', '1-null', '2-1'],
      );
    });

    test('subtitles pair by exact base name', () async {
      final index = await scan({
        '/media/Show/Show S01E01.mkv': '',
        '/media/Show/Show S01E01.en.srt': '',
        '/media/Show/Show S01E02.mkv': '',
        '/media/Show/Show S01E02.en.srt': '',
      });

      for (final video in index.videos) {
        expect(video.subtitleFiles, hasLength(1));
        expect(
          video.subtitleFiles.single.id,
          contains(video.name),
          reason: 'each subtitle must go to its own episode',
        );
      }
    });

    test('a Subs folder attaches to the only video in the directory', () async {
      final index = await scan({
        '/media/Some Movie/Some Movie.mkv': '',
        '/media/Some Movie/Subs/2_English.srt': '',
        '/media/Some Movie/Subs/3_Japanese.srt': '',
      });

      expect(index.videos.single.subtitleFiles, hasLength(2));
      expect(index.unmatchedSubtitles, isEmpty);
    });

    test('reports subtitles it could not attach', () async {
      final index = await scan({
        '/media/Show/Show S01E01.mkv': '',
        '/media/Show/Show S01E02.mkv': '',
        '/media/Show/Completely Different Name.en.srt': '',
      });

      expect(index.unmatchedSubtitles, hasLength(1));
      for (final video in index.videos) {
        expect(video.subtitleFiles, isEmpty);
      }
    });

    test('records forced and SDH flags', () async {
      final index = await scan({
        '/media/Movie/Movie.mkv': '',
        '/media/Movie/Movie.en.forced.srt': '',
        '/media/Movie/Movie.en.sdh.srt': '',
        '/media/Movie/Movie.ja.srt': '',
      });

      final subtitles = index.videos.single.subtitleFiles;
      expect(subtitles, hasLength(3));
      expect(subtitles.where((s) => s.isGoodStudyTrack), hasLength(1));
      expect(index.videos.single.hasStudyableSubtitles, isTrue);
    });

    test('ignores files that are neither video nor subtitle', () async {
      final index = await scan({
        '/media/Movie/Movie.mkv': '',
        '/media/Movie/poster.jpg': '',
        '/media/Movie/Movie.nfo': '',
      });
      expect(index.videos.single.subtitleFiles, isEmpty);
    });

    test('skips small sample files when asked', () async {
      final fs = InMemoryFileSystem()
        ..addFile('/media/Movie/Movie.mkv', List.filled(5000, 0))
        ..addFile('/media/Movie/sample.mkv', List.filled(10, 0));

      final index = await MediaScanner(
        fileSystem: fs,
        options: const ScanOptions(minimumVideoBytes: 1000),
      ).scan('/media');

      expect(index.videos, hasLength(1));
      expect(index.videos.single.name, 'Movie');
    });

    test('titles come back sorted', () async {
      final index = await scan({
        '/media/Zulu/Zulu.mkv': '',
        '/media/alpha/alpha.mkv': '',
        '/media/Mike/Mike.mkv': '',
      });
      expect(index.titles.map((t) => t.name), ['alpha', 'Mike', 'Zulu']);
    });

    test('reports progress while scanning', () async {
      final fs = InMemoryFileSystem({
        '/media/A/A.mkv': '',
        '/media/B/B.mkv': '',
      });
      final progress = <ScanProgress>[];
      await MediaScanner(fileSystem: fs)
          .scan('/media', onProgress: progress.add);

      expect(progress, isNotEmpty);
      expect(progress.last.videosFound, 2);
      expect(progress.last.directoriesScanned, 3);
    });

    test('videoById and titleForVideo resolve', () async {
      final index = await scan({
        '/media/Show/Show S01E01.mkv': '',
        '/media/Show/Show S01E02.mkv': '',
      });

      final id = index.videos.first.id;
      expect(index.videoById(id), isNotNull);
      expect(index.titleForVideo(id)?.isSeries, isTrue);
      expect(index.videoById('nope'), isNull);
    });

    test('a lone numbered episode is still a series', () async {
      final index = await scan({
        '/media/Some Show/Some Show S01E01.mkv': '',
      });
      expect(index.titles.single.isSeries, isTrue);
    });
  });

  group('InMemoryFileSystem', () {
    test('lists files and directories', () async {
      final fs = InMemoryFileSystem({
        '/a/b/file.txt': 'hello',
        '/a/other.txt': '',
      });

      final entries = await fs.list('/a');
      expect(entries.map((e) => e.name), ['b', 'other.txt']);
      expect(entries.first.isDirectory, isTrue);
      expect(await fs.directoryExists('/a/b'), isTrue);
      expect(await fs.fileExists('/a/b/file.txt'), isTrue);
    });

    test('reports extensions and base names', () async {
      final fs = InMemoryFileSystem({'/a/Movie.Name.mkv': ''});
      final entry = (await fs.list('/a')).single;
      expect(entry.extension, 'mkv');
      expect(entry.baseName, 'Movie.Name');
    });

    test('throws on a missing directory or file', () async {
      final fs = InMemoryFileSystem();
      expect(() => fs.list('/nope'), throwsA(isA<FileSystemException>()));
      expect(
        () => fs.readBytes('/nope.txt'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}

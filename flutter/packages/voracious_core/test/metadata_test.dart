import 'dart:convert';

import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

/// Answers GETs from a table of path → JSON, recording every request.
class FakeTransport implements MetadataTransport {
  FakeTransport(this.routes);

  /// Keyed by path; a value may be a function of the full URL.
  final Map<String, Object? Function(Uri url)> routes;
  final List<Uri> requests = [];
  final List<Map<String, String>> headers = [];

  /// Status codes to return before succeeding, per path.
  final Map<String, List<int>> failures = {};

  @override
  Future<MetadataHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    requests.add(url);
    this.headers.add(headers);
    final queued = failures[url.path];
    if (queued != null && queued.isNotEmpty) {
      return MetadataHttpResponse(queued.removeAt(0), '');
    }
    final route = routes[url.path];
    if (route == null) return const MetadataHttpResponse(404, '');
    return MetadataHttpResponse(200, jsonEncode(route(url)));
  }
}

Map<String, Object?> _tvmazeShow(
  int id,
  String name,
  String premiered, {
  String? country,
}) =>
    {
      'id': id,
      'name': name,
      'premiered': premiered,
      'summary': '<p>A show about <b>$name</b> &amp; friends.</p>',
      'genres': ['Drama'],
      'image': {
        'medium': 'http://static.tvmaze.com/$id/medium.jpg',
        'original': 'https://static.tvmaze.com/$id/original.jpg',
      },
      if (country != null)
        'network': {
          'country': {'code': country},
        },
    };

FakeTransport _tvmaze() => FakeTransport({
      '/search/shows': (url) => switch (url.queryParameters['q']) {
            'Mad Men' => [
                {'score': 0.9, 'show': _tvmazeShow(385, 'Mad Men', '2007-07-19')},
              ],
            'The Office' => [
                {
                  'score': 0.9,
                  'show': _tvmazeShow(526, 'The Office', '2005-03-24',
                      country: 'US'),
                },
                {
                  'score': 0.9,
                  'show': _tvmazeShow(1292, 'The Office', '2001-07-09',
                      country: 'GB'),
                },
              ],
            _ => <Object?>[],
          },
      '/shows/385': (_) => {
            ..._tvmazeShow(385, 'Mad Men', '2007-07-19'),
            '_embedded': {
              'episodes': [
                {
                  'season': 3,
                  'number': 7,
                  'name': 'Seven Twenty Three',
                  'airdate': '2009-09-27',
                  'runtime': 60,
                  'summary': '<p>Betty meets a man.</p>',
                  'image': {'medium': 'http://static.tvmaze.com/s3e7.jpg'},
                },
                {'season': 0, 'number': null, 'name': 'A special'},
              ],
            },
          },
    });

MetadataQuery _series(String name, {int? year, String? country}) =>
    MetadataQuery(
        kind: MetadataKind.series, name: name, year: year, country: country);

MetadataCandidate _candidate(
  String name, {
  int? year,
  Set<String> countries = const {},
  MetadataKind kind = MetadataKind.series,
}) =>
    MetadataCandidate(
      source: MetadataSource.tvmaze,
      id: name,
      kind: kind,
      name: name,
      year: year,
      countries: countries,
    );

void main() {
  group('name parsing', () {
    test('reads a release year from brackets or before release metadata', () {
      expect(parseReleaseYear('Mad Men (2007)'), 2007);
      expect(parseReleaseYear('Mad.Men.2007.1080p.BluRay'), 2007);
      expect(parseReleaseYear('Doctor.Who.2005.S01E01.mkv'), 2005);
      expect(parseReleaseYear('Doctor Who 2005'), 2005);
    });

    test('does not read a year out of a title', () {
      expect(parseReleaseYear('Blade Runner 2049'), isNull);
      expect(parseReleaseYear('2001 A Space Odyssey'), isNull);
      expect(parseReleaseYear('Mad Men'), isNull);
    });

    test('takes the series name from in front of episode numbering', () {
      expect(seriesNameFromEpisodeFile('Mad.Men.S03E07.720p.mkv'), 'Mad Men');
      expect(seriesNameFromEpisodeFile('Doctor.Who.2005.S01E01.mkv'),
          'Doctor Who');
      expect(seriesNameFromEpisodeFile('S01E01.mkv'), isNull);
      expect(seriesNameFromEpisodeFile('Spirited Away.mkv'), isNull);
    });

    test('reads country tags but not words that look like them', () {
      expect(parseCountryTag('The Office (US)'), 'US');
      expect(parseCountryTag('The.Office.US.S02E01'), 'US');
      expect(parseCountryTag('Shameless UK'), 'GB');
      expect(parseCountryTag('Between Us'), isNull);
      expect(parseCountryTag('US'), isNull);
    });

    test('normalises titles for comparison', () {
      expect(normalizeTitle('The Office'), 'office');
      expect(normalizeTitle("Grey's Anatomy"), normalizeTitle('Greys Anatomy'));
      expect(normalizeTitle('Law & Order'), 'law and order');
      expect(normalizeTitle('進撃の巨人'), '進撃の巨人');
    });
  });

  group('MetadataQuery.forTitle', () {
    MediaCollectionIndex index(List<VideoEntry> videos) => MediaCollectionIndex(
          rootPath: '/lib',
          videos: videos,
          titles: const [],
        );

    VideoEntry video(String name) => VideoEntry(
        id: '$name.mkv', name: name, path: '/lib/$name.mkv', subtitleFiles: const []);

    test('looks a series folder up by its name, year and country', () {
      const title = MediaTitle.series(
        name: 'The Office',
        episodes: [],
        year: 2005,
        sourceName: 'The Office (US) (2005)',
      );
      final query = MetadataQuery.forTitle(title, index(const []))!;
      expect(query.kind, MetadataKind.series);
      expect(query.name, 'The Office');
      expect(query.year, 2005);
      expect(query.country, 'US');
    });

    test('drops a year left in the display name', () {
      const title = MediaTitle.series(
          name: 'Doctor Who 2005', episodes: [], year: 2005);
      expect(MetadataQuery.forTitle(title, index(const []))!.name, 'Doctor Who');
    });

    test('treats a loose episode file as its series', () {
      final file = video('Mad.Men.S03E07.720p');
      final title = MediaTitle.standalone(
          name: prettifyTitle(file.name), videoId: file.id);
      final query = MetadataQuery.forTitle(title, index([file]))!;
      expect(query.kind, MetadataKind.series);
      expect(query.name, 'Mad Men');
    });

    test('treats a lone file without numbering as a film', () {
      final file = video('Spirited.Away.2001.1080p');
      final title = MediaTitle.standalone(
          name: 'Spirited Away', videoId: file.id, year: 2001);
      final query = MetadataQuery.forTitle(title, index([file]))!;
      expect(query.kind, MetadataKind.movie);
      expect(query.year, 2001);
    });
  });

  group('choosing a candidate', () {
    test('takes an exact name match', () {
      final best = bestCandidate(_series('Mad Men'), [
        _candidate('Mad Max'),
        _candidate('Mad Men'),
      ]);
      expect(best?.name, 'Mad Men');
    });

    test('uses the year to pick between remakes', () {
      final best = bestCandidate(_series('Doctor Who', year: 2005), [
        _candidate('Doctor Who', year: 1963),
        _candidate('Doctor Who', year: 2005),
      ]);
      expect(best?.year, 2005);
    });

    test('uses the country to pick between same-named shows', () {
      final best = bestCandidate(_series('The Office', country: 'GB'), [
        _candidate('The Office', year: 2005, countries: {'US'}),
        _candidate('The Office', year: 2001, countries: {'GB'}),
      ]);
      expect(best?.year, 2001);
    });

    test('prefers the earlier of equal results', () {
      final best = bestCandidate(_series('The Office'), [
        _candidate('The Office', year: 2005),
        _candidate('The Office', year: 2001),
      ]);
      expect(best?.year, 2005);
    });

    test('rejects a weak match rather than guessing', () {
      expect(
        bestCandidate(_series('Mad Men'), [_candidate('Madagascar')]),
        isNull,
      );
      // Right name, plainly the wrong year.
      expect(
        bestCandidate(_series('Dune', year: 2021),
            [_candidate('Dune', year: 1984)]),
        isNull,
      );
    });

    test('ignores results of the other kind', () {
      expect(
        bestCandidate(
            _series('Fargo'), [_candidate('Fargo', kind: MetadataKind.movie)]),
        isNull,
      );
    });
  });

  group('TvMazeProvider', () {
    test('searches and reads candidates', () async {
      final provider = TvMazeProvider(transport: _tvmaze());
      final results = await provider.search('The Office', MetadataKind.series);
      expect(results.map((r) => r.id), ['526', '1292']);
      expect(results.last.countries, {'GB'});
      expect(results.first.year, 2005);
      // Old http image URLs are upgraded.
      expect(results.first.posterUrl, startsWith('https://'));
    });

    test('has no films', () async {
      final transport = _tvmaze();
      final provider = TvMazeProvider(transport: transport);
      expect(await provider.search('Mad Men', MetadataKind.movie), isEmpty);
      expect(transport.requests, isEmpty);
    });

    test('fetches a series with its episodes, skipping unnumbered specials',
        () async {
      final provider = TvMazeProvider(transport: _tvmaze());
      final show = (await provider.fetch('385', MetadataKind.series))!;
      expect(show.name, 'Mad Men');
      expect(show.year, 2007);
      expect(show.overview, 'A show about Mad Men & friends.');
      expect(show.episodes, hasLength(1));
      final episode = show.episode(3, 7)!;
      expect(episode.name, 'Seven Twenty Three');
      expect(episode.overview, 'Betty meets a man.');
      expect(episode.stillUrl, 'https://static.tvmaze.com/s3e7.jpg');
    });

    test('waits and retries when rate-limited', () async {
      final transport = _tvmaze()..failures['/search/shows'] = [429, 429];
      final waits = <Duration>[];
      final provider = TvMazeProvider(
        transport: transport,
        delay: (d) async => waits.add(d),
      );
      final results = await provider.search('Mad Men', MetadataKind.series);
      expect(results, hasLength(1));
      expect(waits, hasLength(2));
    });
  });

  group('TmdbProvider', () {
    FakeTransport tmdb() => FakeTransport({
          '/3/search/movie': (_) => {
                'results': [
                  {
                    'id': 129,
                    'title': '千と千尋の神隠し',
                    'release_date': '2001-07-20',
                    'poster_path': '/poster.jpg',
                  },
                ],
              },
          '/3/tv/1104': (url) {
            final appended = url.queryParameters['append_to_response'];
            return {
              'id': 1104,
              'name': 'Mad Men',
              'first_air_date': '2007-07-19',
              'genres': [
                {'name': 'Drama'},
              ],
              'poster_path': '/mm.jpg',
              'seasons': [
                for (var n = 0; n <= 25; n++) {'season_number': n},
              ],
              if (appended != null)
                for (final part in appended.split(','))
                  part: {
                    'episodes': [
                      {
                        'season_number': int.parse(part.split('/')[1]),
                        'episode_number': 1,
                        'name': 'Episode of $part',
                        'still_path': '/still.jpg',
                      },
                    ],
                  },
            };
          },
        });

    test('sends a v3 key as a query parameter, with the language', () async {
      final transport = tmdb();
      final provider = TmdbProvider(
          transport: transport, apiKey: 'abc123', language: 'ja-JP');
      final results =
          await provider.search('Spirited Away', MetadataKind.movie);
      expect(results.single.name, '千と千尋の神隠し');
      expect(results.single.year, 2001);
      expect(results.single.posterUrl,
          'https://image.tmdb.org/t/p/w342/poster.jpg');
      final url = transport.requests.single;
      expect(url.queryParameters['api_key'], 'abc123');
      expect(url.queryParameters['language'], 'ja-JP');
      expect(transport.headers.single.containsKey('Authorization'), isFalse);
    });

    test('sends a read access token as a bearer header', () async {
      final transport = tmdb();
      final provider =
          TmdbProvider(transport: transport, apiKey: 'eyJhbGciOi.token');
      await provider.search('Spirited Away', MetadataKind.movie);
      expect(transport.requests.single.queryParameters.containsKey('api_key'),
          isFalse);
      expect(transport.headers.single['Authorization'],
          'Bearer eyJhbGciOi.token');
    });

    test('fetches every season, twenty per request', () async {
      final transport = tmdb();
      final provider = TmdbProvider(transport: transport, apiKey: 'k');
      final show = (await provider.fetch('1104', MetadataKind.series))!;
      // One details request, then two batches for 26 seasons.
      expect(transport.requests, hasLength(3));
      expect(show.seasonNumbers, hasLength(26));
      expect(show.episode(25, 1)?.name, 'Episode of season/25');
      expect(show.episode(3, 1)?.stillUrl,
          'https://image.tmdb.org/t/p/w300/still.jpg');
      expect(show.genres, ['Drama']);
    });

    test('reports a refused key', () async {
      final transport = tmdb()..failures['/3/search/movie'] = [401];
      final provider = TmdbProvider(transport: transport, apiKey: 'bad');
      await expectLater(
        provider.search('x', MetadataKind.movie),
        throwsA(isA<MetadataException>()
            .having((e) => e.isAuthFailure, 'isAuthFailure', isTrue)),
      );
    });
  });

  group('TitleMetadata', () {
    test('maps season-less numbering onto a single-season series', () {
      final show = TitleMetadata(
        source: MetadataSource.tvmaze,
        id: '1',
        kind: MetadataKind.series,
        name: 'Mini',
        episodes: const [
          EpisodeMetadata(season: 0, number: 1, name: 'Special'),
          EpisodeMetadata(season: 1, number: 1, name: 'One'),
          EpisodeMetadata(season: 1, number: 2, name: 'Two'),
        ],
      );
      expect(show.episode(null, 2)?.name, 'Two');
      expect(show.episode(0, 1)?.name, 'Special');
    });

    test('does not guess season-less numbering across seasons', () {
      final show = TitleMetadata(
        source: MetadataSource.tvmaze,
        id: '1',
        kind: MetadataKind.series,
        name: 'Long',
        episodes: const [
          EpisodeMetadata(season: 1, number: 1, name: 'One'),
          EpisodeMetadata(season: 2, number: 1, name: 'Two'),
        ],
      );
      expect(show.episode(null, 1), isNull);
    });

    test('round-trips through JSON', () async {
      final show = (await TvMazeProvider(transport: _tvmaze())
          .fetch('385', MetadataKind.series))!;
      final copy = TitleMetadata.fromJson(
          (jsonDecode(jsonEncode(show.toJson())) as Map)
              .cast<String, Object?>());
      expect(copy.name, show.name);
      expect(copy.posterUrl, show.posterUrl);
      expect(copy.episode(3, 7)?.airDate, '2009-09-27');
    });
  });

  group('MetadataService', () {
    late FakeTransport transport;
    late InMemoryKeyValueStore cache;
    late DateTime now;

    MetadataService service({String signature = 'tvmaze'}) => MetadataService(
          cache: cache,
          providers: [TvMazeProvider(transport: transport)],
          signature: signature,
          clock: () => now,
        );

    setUp(() {
      transport = _tvmaze();
      cache = InMemoryKeyValueStore();
      now = DateTime(2026, 1, 1);
    });

    test('matches, then answers from the cache', () async {
      final result = await service().match(_series('Mad Men'));
      expect(result?.id, '385');
      final requests = transport.requests.length;

      final again = await service().match(_series('Mad Men'));
      expect(again?.id, '385');
      expect(transport.requests, hasLength(requests));
    });

    test('remembers a miss for a few days', () async {
      expect(await service().match(_series('Nonexistent Show')), isNull);
      expect(transport.requests, hasLength(1));

      now = now.add(const Duration(days: 1));
      await service().match(_series('Nonexistent Show'));
      expect(transport.requests, hasLength(1));

      now = now.add(const Duration(days: 3));
      await service().match(_series('Nonexistent Show'));
      expect(transport.requests, hasLength(2));
    });

    test('refreshes a listing that lacks an episode on disk, but not on '
        'every scan', () async {
      await service().match(_series('Mad Men'));
      final after = transport.requests.length;

      await service().match(_series('Mad Men'), episodes: const [(3, 8)]);
      expect(transport.requests, hasLength(after),
          reason: 'checked less than a day ago');

      now = now.add(const Duration(days: 2));
      await service().match(_series('Mad Men'), episodes: const [(3, 7)]);
      expect(transport.requests, hasLength(after),
          reason: 'everything on disk is listed');

      await service().match(_series('Mad Men'), episodes: const [(3, 8)]);
      expect(transport.requests.length, greaterThan(after));
    });

    test('looks up again when the settings change', () async {
      await service().match(_series('Mad Men'));
      final after = transport.requests.length;
      await service(signature: 'tmdb:ja-JP').match(_series('Mad Men'));
      expect(transport.requests.length, greaterThan(after));
    });

    test('keeps a hand-picked match over the automatic one', () async {
      final query = _series('The Office');
      expect((await service().match(query))?.id, isNot('1292'));

      transport.routes['/shows/1292'] =
          (_) => _tvmazeShow(1292, 'The Office', '2001-07-09', country: 'GB');
      await service().choose(query, _candidate('The Office').copyWithId('1292'));

      // Even after the cache expires, the choice stands.
      now = now.add(const Duration(days: 60));
      expect((await service().match(query))?.id, '1292');
      expect((await service().cached(query))?.isManual, isTrue);
    });

    test('never looks up a title marked as having no match', () async {
      final query = _series('Mad Men');
      await service().chooseNone(query);
      expect(await service().match(query), isNull);
      expect(transport.requests, isEmpty);

      await service().reset(query);
      expect((await service().match(query))?.id, '385');
    });

    test('falls back to the stale answer when the service is down', () async {
      await service().match(_series('Mad Men'));
      now = now.add(const Duration(days: 60));
      transport.failures['/search/shows'] = [500];
      expect((await service().match(_series('Mad Men')))?.id, '385');
    });

    test('throws when the service is down and nothing is cached', () async {
      transport.failures['/search/shows'] = [500];
      await expectLater(
        service().match(_series('Mad Men')),
        throwsA(isA<MetadataException>()),
      );
      // And the failure was not cached as a miss.
      expect(await service().cached(_series('Mad Men')), isNull);
    });

    test('asks the next service when the first fails', () async {
      final failing = FakeTransport({})..failures['/3/search/tv'] = [401];
      final service = MetadataService(
        cache: cache,
        providers: [
          TmdbProvider(transport: failing, apiKey: 'bad'),
          TvMazeProvider(transport: transport),
        ],
        signature: 'tmdb:en-US',
        clock: () => now,
      );
      expect((await service.match(_series('Mad Men')))?.id, '385');
    });
  });

  group('scanner', () {
    test('keeps the year and source name of a series folder', () async {
      final fs = InMemoryFileSystem({
        '/lib/Mad Men (2007)/Season 3/Mad.Men.S03E07.mkv': '',
      });
      final index = await MediaScanner(fileSystem: fs).scan('/lib');
      final title = index.titles.single;
      expect(title.name, 'Mad Men');
      expect(title.year, 2007);
      expect(title.sourceName, 'Mad Men (2007)');
    });
  });
}

extension on MetadataCandidate {
  MetadataCandidate copyWithId(String id) => MetadataCandidate(
        source: source,
        id: id,
        kind: kind,
        name: name,
        year: year,
        countries: countries,
      );
}

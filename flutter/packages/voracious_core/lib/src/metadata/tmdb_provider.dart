/// The Movie Database (themoviedb.org): films and TV, with text in the
/// language asked for.
///
/// Free for non-commercial use with a personal API key. Either kind of key
/// works: a v3 "API key" (32 hex characters, sent as a query parameter) or a
/// v4 "read access token" (a JWT, sent as a bearer token).
library;

import 'metadata_http.dart';
import 'metadata_models.dart';
import 'metadata_provider.dart';

class TmdbProvider implements MetadataProvider {
  TmdbProvider({
    required this.transport,
    required this.apiKey,
    this.language = 'en-US',
    Uri? baseUrl,
    Future<void> Function(Duration)? delay,
  })  : baseUrl = baseUrl ?? Uri.parse('https://api.themoviedb.org/3/'),
        _delay = delay;

  final MetadataTransport transport;
  final String apiKey;

  /// BCP 47, e.g. `en-US` or `ja-JP`. Titles, overviews and episode names come
  /// back in this language where TMDB has a translation.
  final String language;
  final Uri baseUrl;
  final Future<void> Function(Duration)? _delay;

  static const String imageBase = 'https://image.tmdb.org/t/p/';

  /// TMDB caps `append_to_response` at 20 items per request.
  static const int _maxAppended = 20;

  @override
  MetadataSource get source => MetadataSource.tmdb;

  @override
  bool supports(MetadataKind kind) => true;

  bool get _isBearerToken => apiKey.trim().startsWith('eyJ');

  @override
  Future<List<MetadataCandidate>> search(
    String query,
    MetadataKind kind,
  ) async {
    if (query.trim().isEmpty) return const [];
    final json = await _get(
      kind == MetadataKind.series ? 'search/tv' : 'search/movie',
      {'query': query.trim(), 'include_adult': 'false'},
    );
    final results = json is Map ? json['results'] : null;
    if (results is! List) return const [];
    return [
      for (final result in results)
        if (result is Map) _candidate(result.cast<String, Object?>(), kind),
    ];
  }

  @override
  Future<TitleMetadata?> fetch(String id, MetadataKind kind) =>
      kind == MetadataKind.series ? _fetchSeries(id) : _fetchMovie(id);

  Future<TitleMetadata?> _fetchMovie(String id) async {
    final json = await _get('movie/${Uri.encodeComponent(id)}', const {});
    if (json is! Map) return null;
    final movie = json.cast<String, Object?>();
    return TitleMetadata(
      source: source,
      id: '${movie['id']}',
      kind: MetadataKind.movie,
      name: nonEmpty(movie['title']) ?? nonEmpty(movie['original_title']) ?? '',
      year: yearOfDate(movie['release_date']),
      overview: nonEmpty(movie['overview']),
      posterUrl: _image(movie['poster_path'], 'w342'),
      backdropUrl: _image(movie['backdrop_path'], 'w780'),
      genres: _genres(movie['genres']),
    );
  }

  Future<TitleMetadata?> _fetchSeries(String id) async {
    final path = 'tv/${Uri.encodeComponent(id)}';
    final json = await _get(path, const {});
    if (json is! Map) return null;
    final show = json.cast<String, Object?>();

    final seasonNumbers = [
      for (final season in (show['seasons'] as List?) ?? const [])
        if (season is Map && season['season_number'] is num)
          (season['season_number']! as num).toInt(),
    ];

    // Seasons are fetched by appending them to a details request, twenty at
    // a time, rather than one request each.
    final episodes = <EpisodeMetadata>[];
    for (var i = 0; i < seasonNumbers.length; i += _maxAppended) {
      final chunk = seasonNumbers.skip(i).take(_maxAppended);
      final withSeasons = await _get(path, {
        'append_to_response': chunk.map((n) => 'season/$n').join(','),
      });
      if (withSeasons is! Map) continue;
      for (final number in chunk) {
        final season = withSeasons['season/$number'];
        if (season is! Map) continue;
        for (final episode in (season['episodes'] as List?) ?? const []) {
          if (episode is! Map || episode['episode_number'] is! num) continue;
          episodes.add(EpisodeMetadata(
            season: (episode['season_number'] as num?)?.toInt() ?? number,
            number: (episode['episode_number']! as num).toInt(),
            name: episode['name'] as String? ?? '',
            overview: nonEmpty(episode['overview']),
            airDate: nonEmpty(episode['air_date']),
            stillUrl: _image(episode['still_path'], 'w300'),
            runtimeMinutes: (episode['runtime'] as num?)?.toInt(),
          ));
        }
      }
    }

    return TitleMetadata(
      source: source,
      id: '${show['id']}',
      kind: MetadataKind.series,
      name: nonEmpty(show['name']) ?? nonEmpty(show['original_name']) ?? '',
      year: yearOfDate(show['first_air_date']),
      overview: nonEmpty(show['overview']),
      posterUrl: _image(show['poster_path'], 'w342'),
      backdropUrl: _image(show['backdrop_path'], 'w780'),
      genres: _genres(show['genres']),
      episodes: episodes,
    );
  }

  MetadataCandidate _candidate(Map<String, Object?> json, MetadataKind kind) {
    final isSeries = kind == MetadataKind.series;
    return MetadataCandidate(
      source: source,
      id: '${json['id']}',
      kind: kind,
      name: nonEmpty(json[isSeries ? 'name' : 'title']) ??
          nonEmpty(json[isSeries ? 'original_name' : 'original_title']) ??
          '',
      year: yearOfDate(json[isSeries ? 'first_air_date' : 'release_date']),
      posterUrl: _image(json['poster_path'], 'w342'),
      overview: nonEmpty(json['overview']),
      countries: {
        for (final code in (json['origin_country'] as List?) ?? const [])
          if (code is String) code.toUpperCase(),
      },
    );
  }

  static String? _image(Object? path, String size) {
    final value = nonEmpty(path);
    return value == null ? null : '$imageBase$size$value';
  }

  static List<String> _genres(Object? genres) => [
        for (final genre in genres is List ? genres : const [])
          if (genre is Map && genre['name'] is String) genre['name']! as String,
      ];

  Future<Object?> _get(String path, Map<String, String> query) {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw const MetadataException('no TMDB API key is set', statusCode: 401);
    }
    return getJson(
      transport,
      baseUrl.resolve(path).replace(queryParameters: {
        ...query,
        'language': language,
        if (!_isBearerToken) 'api_key': key,
      }),
      service: 'TMDB',
      headers: {
        'Accept': 'application/json',
        if (_isBearerToken) 'Authorization': 'Bearer $key',
      },
      delay: _delay ?? (d) => Future<void>.delayed(d),
    );
  }
}

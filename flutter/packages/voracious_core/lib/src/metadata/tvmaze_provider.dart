/// TVmaze (tvmaze.com): TV series and episodes, no API key.
///
/// Its data is CC BY-SA 4.0, so the app credits it wherever this metadata is
/// shown (the About screen).
library;

import 'metadata_http.dart';
import 'metadata_models.dart';
import 'metadata_provider.dart';

class TvMazeProvider implements MetadataProvider {
  TvMazeProvider({
    required this.transport,
    Uri? baseUrl,
    Future<void> Function(Duration)? delay,
  })  : baseUrl = baseUrl ?? Uri.parse('https://api.tvmaze.com/'),
        _delay = delay;

  final MetadataTransport transport;
  final Uri baseUrl;
  final Future<void> Function(Duration)? _delay;

  @override
  MetadataSource get source => MetadataSource.tvmaze;

  @override
  bool supports(MetadataKind kind) => kind == MetadataKind.series;

  @override
  Future<List<MetadataCandidate>> search(
    String query,
    MetadataKind kind,
  ) async {
    if (!supports(kind) || query.trim().isEmpty) return const [];
    final json = await _get('search/shows', {'q': query.trim()});
    if (json is! List) return const [];
    return [
      for (final result in json)
        if (result is Map && result['show'] is Map)
          _candidate((result['show']! as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<TitleMetadata?> fetch(String id, MetadataKind kind) async {
    if (!supports(kind)) return null;
    final json = await _get('shows/${Uri.encodeComponent(id)}', {
      'embed': 'episodes',
    });
    if (json is! Map) return null;
    final show = json.cast<String, Object?>();
    final embedded = show['_embedded'];
    final episodes = embedded is Map ? embedded['episodes'] : null;

    return TitleMetadata(
      source: source,
      id: '${show['id']}',
      kind: MetadataKind.series,
      name: show['name'] as String? ?? '',
      year: yearOfDate(show['premiered']),
      overview: plainTextFromHtml(show['summary']),
      posterUrl: _image(show['image'], 'medium'),
      backdropUrl: _image(show['image'], 'original'),
      genres: [
        for (final genre in (show['genres'] as List?) ?? const [])
          if (genre is String) genre,
      ],
      episodes: [
        for (final episode in episodes is List ? episodes : const [])
          // Specials have no number; they are not in the embedded list, but
          // guard anyway so one cannot become episode 0.
          if (episode is Map && episode['number'] is num)
            EpisodeMetadata(
              season: (episode['season'] as num?)?.toInt() ?? 0,
              number: (episode['number']! as num).toInt(),
              name: episode['name'] as String? ?? '',
              overview: plainTextFromHtml(episode['summary']),
              airDate: nonEmpty(episode['airdate']),
              stillUrl: _image(episode['image'], 'medium'),
              runtimeMinutes: (episode['runtime'] as num?)?.toInt(),
            ),
      ],
    );
  }

  MetadataCandidate _candidate(Map<String, Object?> show) => MetadataCandidate(
        source: source,
        id: '${show['id']}',
        kind: MetadataKind.series,
        name: show['name'] as String? ?? '',
        year: yearOfDate(show['premiered']),
        posterUrl: _image(show['image'], 'medium'),
        overview: plainTextFromHtml(show['summary']),
        countries: {
          for (final channel in [show['network'], show['webChannel']])
            if (channel is Map &&
                channel['country'] is Map &&
                (channel['country']! as Map)['code'] is String)
              ((channel['country']! as Map)['code']! as String).toUpperCase(),
        },
      );

  /// TVmaze serves images over plain http in older records.
  static String? _image(Object? image, String size) {
    if (image is! Map) return null;
    final url = nonEmpty(image[size]) ?? nonEmpty(image['medium']);
    return url?.replaceFirst(RegExp('^http:'), 'https:');
  }

  Future<Object?> _get(String path, Map<String, String> query) => getJson(
        transport,
        baseUrl.resolve(path).replace(queryParameters: query),
        service: 'TVmaze',
        delay: _delay ?? (d) => Future<void>.delayed(d),
      );
}

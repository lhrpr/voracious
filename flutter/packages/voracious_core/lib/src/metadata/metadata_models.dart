/// What a metadata lookup returns: a series or film with its artwork, and for a
/// series, its episodes.
///
/// Everything here round-trips through JSON, because a match is looked up once
/// and then read from the cache on every later scan.
library;

import 'package:meta/meta.dart';

/// Which service a match came from.
enum MetadataSource {
  /// tvmaze.com: TV only, no API key.
  tvmaze('TVmaze'),

  /// themoviedb.org: films and TV, free API key, localised text.
  tmdb('TMDB');

  const MetadataSource(this.label);

  final String label;

  static MetadataSource? byName(Object? name) {
    for (final source in values) {
      if (source.name == name) return source;
    }
    return null;
  }
}

/// Whether a title is looked up as a series or a film.
enum MetadataKind {
  series,
  movie;

  static MetadataKind? byName(Object? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// A search result: enough to recognise the right title in a list.
@immutable
class MetadataCandidate {
  const MetadataCandidate({
    required this.source,
    required this.id,
    required this.kind,
    required this.name,
    this.year,
    this.posterUrl,
    this.overview,
    this.countries = const {},
  });

  final MetadataSource source;

  /// The service's own id, as a string so both services fit.
  final String id;
  final MetadataKind kind;
  final String name;
  final int? year;
  final String? posterUrl;
  final String? overview;

  /// ISO 3166-1 alpha-2 codes of where it was made, upper case. Tells the
  /// American "The Office" from the British one.
  final Set<String> countries;

  @override
  String toString() =>
      'MetadataCandidate(${source.name}:$id $name${year != null ? ' ($year)' : ''})';
}

/// One episode as the service lists it.
@immutable
class EpisodeMetadata {
  const EpisodeMetadata({
    required this.season,
    required this.number,
    required this.name,
    this.overview,
    this.airDate,
    this.stillUrl,
    this.runtimeMinutes,
  });

  factory EpisodeMetadata.fromJson(Map<String, Object?> json) =>
      EpisodeMetadata(
        season: (json['season'] as num?)?.toInt() ?? 0,
        number: (json['number'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        overview: json['overview'] as String?,
        airDate: json['airDate'] as String?,
        stillUrl: json['stillUrl'] as String?,
        runtimeMinutes: (json['runtime'] as num?)?.toInt(),
      );

  final int season;
  final int number;

  /// May be empty: a service sometimes lists an episode before it has a title,
  /// and a localised listing may have no translation for it.
  final String name;
  final String? overview;

  /// `YYYY-MM-DD`.
  final String? airDate;
  final String? stillUrl;
  final int? runtimeMinutes;

  Map<String, Object?> toJson() => {
        'season': season,
        'number': number,
        'name': name,
        if (overview != null) 'overview': overview,
        if (airDate != null) 'airDate': airDate,
        if (stillUrl != null) 'stillUrl': stillUrl,
        if (runtimeMinutes != null) 'runtime': runtimeMinutes,
      };
}

/// A matched title.
@immutable
class TitleMetadata {
  TitleMetadata({
    required this.source,
    required this.id,
    required this.kind,
    required this.name,
    this.year,
    this.overview,
    this.posterUrl,
    this.backdropUrl,
    this.genres = const [],
    this.episodes = const [],
  });

  factory TitleMetadata.fromJson(Map<String, Object?> json) => TitleMetadata(
        source: MetadataSource.byName(json['source']) ?? MetadataSource.tvmaze,
        id: json['id']! as String,
        kind: MetadataKind.byName(json['kind']) ?? MetadataKind.series,
        name: json['name']! as String,
        year: (json['year'] as num?)?.toInt(),
        overview: json['overview'] as String?,
        posterUrl: json['posterUrl'] as String?,
        backdropUrl: json['backdropUrl'] as String?,
        genres: [
          for (final genre in (json['genres'] as List?) ?? const [])
            if (genre is String) genre,
        ],
        episodes: [
          for (final episode in (json['episodes'] as List?) ?? const [])
            if (episode is Map)
              EpisodeMetadata.fromJson(episode.cast<String, Object?>()),
        ],
      );

  final MetadataSource source;
  final String id;
  final MetadataKind kind;
  final String name;
  final int? year;
  final String? overview;
  final String? posterUrl;
  final String? backdropUrl;
  final List<String> genres;

  /// Every episode the service lists, specials as season 0. Empty for a film.
  final List<EpisodeMetadata> episodes;

  late final Map<(int, int), EpisodeMetadata> _bySeasonAndNumber = {
    for (final episode in episodes) (episode.season, episode.number): episode,
  };

  /// The listed episode for a file's numbering, or null.
  ///
  /// A file numbered without a season (`Show - 05`) is taken as season 1 when
  /// the series has only one season; otherwise the numbering is ambiguous and
  /// nothing is guessed.
  EpisodeMetadata? episode(int? season, int? number) {
    if (number == null) return null;
    if (season != null) return _bySeasonAndNumber[(season, number)];
    final seasons = {
      for (final e in episodes)
        if (e.season > 0) e.season,
    };
    if (seasons.length != 1) return null;
    return _bySeasonAndNumber[(seasons.single, number)];
  }

  /// Season numbers the service lists, ascending.
  Set<int> get seasonNumbers => {for (final e in episodes) e.season};

  /// The [MetadataCandidate] this was fetched from, for showing the current
  /// match in a search list.
  MetadataCandidate get asCandidate => MetadataCandidate(
        source: source,
        id: id,
        kind: kind,
        name: name,
        year: year,
        posterUrl: posterUrl,
        overview: overview,
      );

  Map<String, Object?> toJson() => {
        'source': source.name,
        'id': id,
        'kind': kind.name,
        'name': name,
        if (year != null) 'year': year,
        if (overview != null) 'overview': overview,
        if (posterUrl != null) 'posterUrl': posterUrl,
        if (backdropUrl != null) 'backdropUrl': backdropUrl,
        if (genres.isNotEmpty) 'genres': genres,
        if (episodes.isNotEmpty)
          'episodes': [for (final e in episodes) e.toJson()],
      };

  @override
  String toString() => 'TitleMetadata(${source.name}:$id $name, '
      '${episodes.length} episodes)';
}

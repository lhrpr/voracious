/// Whether and how titles are matched to online metadata.
library;

import 'package:meta/meta.dart';

import 'metadata_http.dart';
import 'metadata_models.dart';
import 'metadata_provider.dart';
import 'tmdb_provider.dart';
import 'tvmaze_provider.dart';

@immutable
class MetadataSettings {
  const MetadataSettings({
    this.enabled = true,
    this.tmdbApiKey = '',
    this.language = 'en-US',
  });

  /// Look titles up after each scan. Off means no network requests at all.
  final bool enabled;

  /// Optional. Without it, series come from TVmaze and films are not matched.
  final String tmdbApiKey;

  /// BCP 47 language for TMDB titles and overviews, e.g. `ja-JP`. TVmaze is
  /// English only.
  final String language;

  bool get hasTmdb => tmdbApiKey.trim().isNotEmpty;

  /// Whether [source] can be used with these settings.
  bool allows(MetadataSource source) => switch (source) {
        MetadataSource.tvmaze => true,
        MetadataSource.tmdb => hasTmdb,
      };

  /// What a cached lookup was made with. When it changes — a TMDB key added,
  /// a different language — cached matches are looked up again.
  String get signature => hasTmdb ? 'tmdb:${language.trim()}' : 'tvmaze';

  /// The services to ask, most preferred first.
  ///
  /// TMDB goes first when there is a key, because it covers films and can give
  /// titles in the language being studied; TVmaze stays as the fallback for
  /// series TMDB does not find.
  List<MetadataProvider> providers(MetadataTransport transport) => [
        if (hasTmdb)
          TmdbProvider(
            transport: transport,
            apiKey: tmdbApiKey.trim(),
            language: language.trim().isEmpty ? 'en-US' : language.trim(),
          ),
        TvMazeProvider(transport: transport),
      ];

  MetadataSettings copyWith({
    bool? enabled,
    String? tmdbApiKey,
    String? language,
  }) =>
      MetadataSettings(
        enabled: enabled ?? this.enabled,
        tmdbApiKey: tmdbApiKey ?? this.tmdbApiKey,
        language: language ?? this.language,
      );

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'tmdbApiKey': tmdbApiKey,
        'language': language,
      };

  static MetadataSettings fromJson(Map<String, Object?> json) =>
      MetadataSettings(
        enabled: json['enabled'] is bool ? json['enabled']! as bool : true,
        tmdbApiKey:
            json['tmdbApiKey'] is String ? json['tmdbApiKey']! as String : '',
        language:
            json['language'] is String ? json['language']! as String : 'en-US',
      );
}

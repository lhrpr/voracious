/// A metadata service: search it for a title, then fetch the full listing.
library;

import 'metadata_models.dart';

abstract interface class MetadataProvider {
  MetadataSource get source;

  /// Whether this service can look up [kind] at all. TVmaze has no films.
  bool supports(MetadataKind kind);

  /// Titles matching [query], in the service's own order of relevance.
  Future<List<MetadataCandidate>> search(String query, MetadataKind kind);

  /// The full listing for a search result: artwork, overview and, for a
  /// series, every episode. Null when the service no longer has it.
  Future<TitleMetadata?> fetch(String id, MetadataKind kind);
}

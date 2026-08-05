/// Decides which subtitle tracks are shown, and in what order.
///
/// The order matters more than it looks: study modes reveal tracks one at a
/// time and take their timing from the first one, so "first" has to be the
/// language being studied, not whichever file the scanner happened to read
/// first.
library;

/// Orders and filters [tracks] by the user's language preferences.
///
/// [preferredOrder] is a list of ISO 639-3 codes, most important first;
/// anything not in it sorts after everything in it. [ignored] languages are
/// dropped entirely. Ties break on language code and then on id, so the result
/// is stable across scans.
List<T> orderSubtitleTracks<T>(
  Iterable<T> tracks, {
  required String? Function(T track) languageOf,
  required String Function(T track) idOf,
  List<String> preferredOrder = const [],
  Set<String> ignored = const {},
}) {
  final result = tracks
      .where((track) => !ignored.contains(languageOf(track) ?? ''))
      .toList();

  int rank(T track) {
    final language = languageOf(track);
    if (language == null) return preferredOrder.length + 1;
    final index = preferredOrder.indexOf(language);
    return index < 0 ? preferredOrder.length : index;
  }

  result.sort((a, b) {
    final rankComparison = rank(a).compareTo(rank(b));
    if (rankComparison != 0) return rankComparison;

    final languageComparison =
        (languageOf(a) ?? '').compareTo(languageOf(b) ?? '');
    if (languageComparison != 0) return languageComparison;

    return idOf(a).compareTo(idOf(b));
  });

  return result;
}

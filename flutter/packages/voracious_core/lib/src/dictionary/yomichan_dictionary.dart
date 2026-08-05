/// Reads dictionaries in the Yomichan/Yomitan term bank format.
///
/// That format won: JMdict, JMnedict, the Kenkyusha exports and every EPWING
/// conversion are all distributed in it, so supporting it is the difference
/// between shipping one built-in dictionary and letting a learner use the ones
/// they already have.
///
/// Reading the ZIP container is left to the host application — core takes the
/// decoded JSON — which keeps an archive library out of the dependency set of
/// a package that otherwise has none.
library;

import 'dart:convert';

import 'dictionary.dart';

/// Metadata from a dictionary's `index.json`.
class YomichanIndexInfo {
  const YomichanIndexInfo({
    required this.title,
    required this.format,
    this.revision,
    this.author,
    this.description,
    this.isSequenced = false,
  });

  final String title;

  /// Term bank schema version. Versions 1 and 3 both occur; the difference is
  /// in the term bank entry shape.
  final int format;

  final String? revision;
  final String? author;
  final String? description;

  /// Whether entries carry sequence numbers that group alternative spellings.
  final bool isSequenced;

  static YomichanIndexInfo fromJson(Map<String, Object?> json) {
    // Yomitan renamed `format` to `version`; both appear in the wild.
    final format = (json['format'] ?? json['version']) as num?;
    return YomichanIndexInfo(
      title: (json['title'] as String?) ?? 'Untitled dictionary',
      format: format?.toInt() ?? 1,
      revision: json['revision'] as String?,
      author: json['author'] as String?,
      description: json['description'] as String?,
      isSequenced: json['sequenced'] == true,
    );
  }

  static YomichanIndexInfo parse(String indexJson) =>
      fromJson(jsonDecode(indexJson) as Map<String, Object?>);

  @override
  String toString() => 'YomichanIndexInfo($title, format $format)';
}

/// An in-memory Yomichan dictionary.
class YomichanDictionary implements Dictionary {
  YomichanDictionary._({
    required this.name,
    required this.isBuiltIn,
    required Map<int, DictionaryEntry> entries,
    required Map<String, Set<int>> formIndex,
  })  : _entries = entries,
        _formIndex = formIndex;

  @override
  final String name;

  @override
  final bool isBuiltIn;

  final Map<int, DictionaryEntry> _entries;

  /// Word or reading -> the sequences that use it.
  final Map<String, Set<int>> _formIndex;

  @override
  int get entryCount => _entries.length;

  /// Distinct searchable forms.
  int get formCount => _formIndex.length;

  @override
  List<DictionaryEntry> lookupExact(String form) {
    final sequences = _formIndex[form];
    if (sequences == null) return const [];
    return [
      for (final sequence in sequences)
        if (_entries[sequence] case final entry?) entry,
    ];
  }

  /// Builds a dictionary from decoded term bank arrays.
  ///
  /// [termBanks] is the concatenation of every `term_bank_N.json` in the
  /// archive, each of which is a list of entry arrays. Entries sharing a
  /// sequence number are merged, so 見る and みる resolve to one entry with
  /// both forms rather than two entries with the same definition.
  factory YomichanDictionary.fromTermBanks({
    required String name,
    required List<List<Object?>> termBanks,
    bool isBuiltIn = false,
  }) {
    final entries = <int, _MutableEntry>{};
    final formIndex = <String, Set<int>>{};

    // Entries without a sequence number get a synthetic negative one, so an
    // unsequenced dictionary still produces one entry per row.
    var syntheticSequence = -1;

    for (final row in termBanks) {
      if (row.length < 6) continue;

      final word = row[0] as String?;
      final reading = row[1] as String?;
      if (word == null || word.isEmpty) continue;

      final glosses = _extractGlosses(row[5]);
      if (glosses.isEmpty) continue;

      final sequence = row.length > 6 && row[6] is num
          ? (row[6]! as num).toInt()
          : syntheticSequence--;

      final entry = entries.putIfAbsent(sequence, _MutableEntry.new)
        ..words.add(word)
        ..glosses.addAll(glosses);

      final definitionTags = row[2];
      if (definitionTags is String && definitionTags.isNotEmpty) {
        entry.tags.addAll(definitionTags.split(RegExp(r'\s+')));
      }

      formIndex.putIfAbsent(word, () => <int>{}).add(sequence);

      if (reading != null && reading.isNotEmpty) {
        entry.readings.add(reading);
        formIndex.putIfAbsent(reading, () => <int>{}).add(sequence);
      }
    }

    return YomichanDictionary._(
      name: name,
      isBuiltIn: isBuiltIn,
      entries: {
        for (final entry in entries.entries)
          entry.key: DictionaryEntry(
            sequence: entry.key,
            words: entry.value.words,
            readings: entry.value.readings,
            glosses: entry.value.glosses.toList(),
            tags: entry.value.tags.toList(),
          ),
      },
      formIndex: formIndex,
    );
  }

  /// Convenience for callers holding the raw JSON of each term bank file.
  factory YomichanDictionary.fromTermBankJson({
    required String name,
    required List<String> termBankJson,
    bool isBuiltIn = false,
  }) =>
      YomichanDictionary.fromTermBanks(
        name: name,
        isBuiltIn: isBuiltIn,
        termBanks: [
          for (final json in termBankJson)
            (jsonDecode(json) as List<Object?>)
                .whereType<List<Object?>>()
                .toList(),
        ].expand((banks) => banks).map((row) => row).toList(),
      );

  @override
  String toString() =>
      'YomichanDictionary($name, $entryCount entries, $formCount forms)';
}

class _MutableEntry {
  final Set<String> words = {};
  final Set<String> readings = {};

  /// A LinkedHashSet keeps the dictionary's own ordering while removing the
  /// duplicates that merging alternative spellings produces.
  final Set<String> glosses = {};
  final Set<String> tags = {};
}

/// Pulls plain text out of a glossary field.
///
/// Format 1 glossaries are lists of strings. Format 3 allows structured
/// content — objects with a `type` and nested children — for tables and
/// images. Definitions still carry their text, so it is extracted and the
/// presentation discarded.
List<String> _extractGlosses(Object? glossary) {
  if (glossary is String) return [glossary];
  if (glossary is! List) return const [];

  final result = <String>[];
  for (final item in glossary) {
    final text = _glossText(item);
    if (text != null && text.trim().isNotEmpty) result.add(text.trim());
  }
  return result;
}

String? _glossText(Object? item) {
  if (item is String) return item;
  if (item is List) {
    final parts = item.map(_glossText).whereType<String>();
    return parts.isEmpty ? null : parts.join('; ');
  }
  if (item is Map) {
    final map = item.cast<String, Object?>();
    // {"type": "text", "text": "..."}
    final text = map['text'];
    if (text is String) return text;
    // {"type": "structured-content", "content": ...}
    final content = map['content'];
    if (content != null) return _glossText(content);
  }
  return null;
}

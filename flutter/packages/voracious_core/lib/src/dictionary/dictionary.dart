/// Dictionary lookup.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// One dictionary entry: a set of surface forms that share a meaning.
///
/// A single JMdict entry covers several spellings and readings — 見る, みる,
/// ミル — which is why words and readings are sets rather than strings.
@immutable
class DictionaryEntry {
  const DictionaryEntry({
    required this.sequence,
    required this.words,
    required this.readings,
    required this.glosses,
    this.tags = const [],
  });

  /// Identifier within its dictionary; entries are merged on it.
  final int sequence;

  final Set<String> words;
  final Set<String> readings;

  /// Definitions, in the dictionary's own order.
  final List<String> glosses;

  /// Part-of-speech and usage tags, as the dictionary wrote them.
  final List<String> tags;

  /// The form to show as the headword.
  String get headword =>
      words.isNotEmpty ? words.first : (readings.firstOrNull ?? '');

  @override
  String toString() => 'DictionaryEntry($sequence, $headword)';
}

/// One hit from a search.
@immutable
class DictionaryResult {
  const DictionaryResult({
    required this.dictionaryName,
    required this.entry,
    required this.matchedForm,
    this.deinflectionReasons = const [],
  });

  final String dictionaryName;
  final DictionaryEntry entry;

  /// The form actually found in the dictionary, which may differ from what the
  /// user tapped once deinflection has run.
  final String matchedForm;

  /// How the search got from the surface form to [matchedForm], outermost
  /// first — `['past', 'polite']`. Empty for a direct hit. Worth showing: it
  /// is half the answer to "why does this word look like that".
  final List<String> deinflectionReasons;

  bool get wasDeinflected => deinflectionReasons.isNotEmpty;

  @override
  String toString() =>
      'DictionaryResult($dictionaryName, $matchedForm, ${entry.headword})';
}

/// A searchable dictionary.
abstract interface class Dictionary {
  /// Display name, from the dictionary's own metadata.
  String get name;

  /// True for dictionaries shipped with the app rather than imported, which
  /// the user is not allowed to delete.
  bool get isBuiltIn;

  /// Number of entries, for the settings screen.
  int get entryCount;

  /// Entries whose word or reading is exactly [form].
  List<DictionaryEntry> lookupExact(String form);
}

/// The dictionaries available, in the user's chosen order.
///
/// Order matters: results are shown in it, and the first dictionary to define
/// a word is the one a learner reads. Disabled dictionaries stay loaded so
/// that toggling one back on is instant.
class DictionarySet {
  DictionarySet({
    List<Dictionary> dictionaries = const [],
    Set<String> disabled = const {},
  })  : _dictionaries = List.of(dictionaries),
        _disabled = Set.of(disabled);

  final List<Dictionary> _dictionaries;
  final Set<String> _disabled;

  List<Dictionary> get all => List.unmodifiable(_dictionaries);

  List<Dictionary> get enabled =>
      _dictionaries.where((d) => !_disabled.contains(d.name)).toList();

  Set<String> get disabledNames => Set.unmodifiable(_disabled);

  bool isEnabled(String name) => !_disabled.contains(name);

  void add(Dictionary dictionary) {
    _dictionaries.removeWhere((d) => d.name == dictionary.name);
    _dictionaries.add(dictionary);
  }

  bool remove(String name) {
    final before = _dictionaries.length;
    _dictionaries.removeWhere((d) => d.name == name);
    return _dictionaries.length != before;
  }

  void setEnabled(String name, bool enabled) {
    if (enabled) {
      _disabled.remove(name);
    } else {
      _disabled.add(name);
    }
  }

  /// Reorders dictionaries to match [names]; anything not listed keeps its
  /// relative position at the end.
  void reorder(List<String> names) {
    final byName = {for (final d in _dictionaries) d.name: d};
    final ordered = <Dictionary>[
      for (final name in names)
        if (byName.containsKey(name)) byName.remove(name)!,
      ...byName.values,
    ];
    _dictionaries
      ..clear()
      ..addAll(ordered);
  }

  /// Looks [form] up in every enabled dictionary.
  ///
  /// [deinflect] supplies alternative forms to try when the surface form is
  /// not found directly — see `JapaneseDeinflector`. It is only consulted if
  /// the exact form yields nothing, so a word that is both a dictionary form
  /// and an inflection of something else is not buried under the latter.
  List<DictionaryResult> lookup(
    String form, {
    List<DeinflectionCandidate> Function(String form)? deinflect,
  }) {
    final results = <DictionaryResult>[];

    for (final dictionary in enabled) {
      for (final entry in dictionary.lookupExact(form)) {
        results.add(DictionaryResult(
          dictionaryName: dictionary.name,
          entry: entry,
          matchedForm: form,
        ));
      }
    }

    if (results.isNotEmpty || deinflect == null) return results;

    for (final candidate in deinflect(form)) {
      if (candidate.form == form) continue;
      for (final dictionary in enabled) {
        for (final entry in dictionary.lookupExact(candidate.form)) {
          results.add(DictionaryResult(
            dictionaryName: dictionary.name,
            entry: entry,
            matchedForm: candidate.form,
            deinflectionReasons: candidate.reasons,
          ));
        }
      }
      // Stop at the first candidate that hits: deinflection candidates are
      // generated shortest-chain-first, and a longer chain that also matches
      // is almost always a coincidence.
      if (results.isNotEmpty) break;
    }

    return results;
  }
}

/// A possible uninflected form, with the chain of inflections undone to reach
/// it.
@immutable
class DeinflectionCandidate {
  const DeinflectionCandidate({
    required this.form,
    required this.reasons,
    this.wordTypes = const {},
  });

  final String form;

  /// Inflection names, most recently applied first.
  final List<String> reasons;

  /// Word classes this form could belong to, used to reject impossible
  /// chains.
  final Set<String> wordTypes;

  @override
  String toString() => 'DeinflectionCandidate($form, ${reasons.join(' < ')})';
}

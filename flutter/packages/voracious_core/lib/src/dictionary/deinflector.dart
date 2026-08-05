/// Undoes Japanese inflection so that conjugated words can be looked up.
///
/// A dictionary is indexed by dictionary form. Subtitles are not: 食べたかった
/// has to become 食べる before JMdict has anything to say about it. The
/// tokeniser usually supplies a lemma and this is not needed — but tokenisers
/// are optional here, they fail on names and slang, and a user tapping a word
/// gets nothing at all when it does.
///
/// The approach is the standard one: a table of (suffix in, suffix out, word
/// class in, word class out) rules applied repeatedly, breadth-first, keeping
/// only chains whose word classes stay consistent. The word class constraint is
/// what stops 見た from deinflecting as though it were a godan verb.
library;

import 'dictionary.dart';

/// Word classes a rule can consume or produce.
abstract final class WordType {
  /// Ichidan (る) verb: 食べる, 見る.
  static const String ichidan = 'v1';

  /// Godan verb, by its dictionary-form ending.
  static const String godanU = 'v5u';
  static const String godanKu = 'v5k';
  static const String godanGu = 'v5g';
  static const String godanSu = 'v5s';
  static const String godanTsu = 'v5t';
  static const String godanNu = 'v5n';
  static const String godanBu = 'v5b';
  static const String godanMu = 'v5m';
  static const String godanRu = 'v5r';

  /// する and 来る, which are irregular.
  static const String suru = 'vs';
  static const String kuru = 'vk';

  /// い-adjective.
  static const String adjI = 'adj-i';

  /// Every godan class.
  static const Set<String> allGodan = {
    godanU, godanKu, godanGu, godanSu, godanTsu, //
    godanNu, godanBu, godanMu, godanRu,
  };

  /// Every verb class.
  static const Set<String> allVerbs = {
    ichidan, suru, kuru, //
    godanU, godanKu, godanGu, godanSu, godanTsu,
    godanNu, godanBu, godanMu, godanRu,
  };

  /// Verbs and い-adjectives — what most rules accept as input.
  static const Set<String> inflectable = {...allVerbs, adjI};
}

/// One deinflection rule: replace [suffixIn] with [suffixOut].
class DeinflectionRule {
  const DeinflectionRule({
    required this.reason,
    required this.suffixIn,
    required this.suffixOut,
    required this.resultTypes,
    required this.requiredTypes,
  });

  /// Name of the inflection being undone.
  final String reason;

  /// What the inflected form ends with.
  final String suffixIn;

  /// What it ends with once undone.
  final String suffixOut;

  /// Word classes the *result* belongs to. `食べた` -> `食べる` produces an
  /// ichidan verb, so this is `{v1}`. Empty means unconstrained.
  final Set<String> resultTypes;

  /// Word classes the *inflected* form must already have for this rule to
  /// apply. `-くない` -> `-い` only applies to an い-adjective, which is how a
  /// chain like `食べたくなかった` stays on the rails. Empty means any.
  final Set<String> requiredTypes;

  @override
  String toString() => '$reason: -$suffixIn -> -$suffixOut';
}

/// Deinflects Japanese words.
class JapaneseDeinflector {
  const JapaneseDeinflector({this.maxDepth = 6, this.rules = defaultRules});

  /// How many inflections deep to search. 食べさせられたくなかった is five;
  /// six covers everything that occurs in practice without the search
  /// exploding.
  final int maxDepth;

  final List<DeinflectionRule> rules;

  /// Returns candidate uninflected forms for [word], shortest chain first.
  ///
  /// The word itself is always the first candidate: it may already be a
  /// dictionary form.
  List<DeinflectionCandidate> deinflect(String word) {
    if (word.isEmpty) return const [];

    final results = <DeinflectionCandidate>[
      DeinflectionCandidate(
        form: word,
        reasons: const [],
        wordTypes: WordType.inflectable,
      ),
    ];
    final seen = <String>{word};

    // Breadth-first, so shorter chains are found first and the caller can stop
    // at the first hit.
    var frontier = <DeinflectionCandidate>[results.first];

    for (var depth = 0; depth < maxDepth && frontier.isNotEmpty; depth++) {
      final next = <DeinflectionCandidate>[];

      for (final candidate in frontier) {
        for (final rule in rules) {
          if (!candidate.form.endsWith(rule.suffixIn)) continue;

          // The rule's output classes have to overlap what the candidate can
          // be, or the chain is grammatically impossible.
          if (candidate.reasons.isNotEmpty &&
              rule.requiredTypes.isNotEmpty &&
              candidate.wordTypes.isNotEmpty &&
              !rule.requiredTypes.any(candidate.wordTypes.contains)) {
            continue;
          }

          final stem = candidate.form
              .substring(0, candidate.form.length - rule.suffixIn.length);
          final form = stem + rule.suffixOut;

          // A rule that eats the whole word has produced a suffix, not a word.
          if (form.isEmpty || stem.isEmpty && rule.suffixOut.isEmpty) continue;
          if (!seen.add(form)) continue;

          final produced = DeinflectionCandidate(
            form: form,
            reasons: [rule.reason, ...candidate.reasons],
            wordTypes: rule.resultTypes.isEmpty
                ? WordType.inflectable
                : rule.resultTypes,
          );
          results.add(produced);
          next.add(produced);
        }
      }

      frontier = next;
    }

    return results;
  }

  /// Just the forms, in order.
  List<String> deinflectForms(String word) =>
      deinflect(word).map((c) => c.form).toList();

  /// The rule table.
  ///
  /// Ordering within the list does not matter — the search is breadth-first
  /// over all rules — but grouping does, for anyone maintaining it.
  static const List<DeinflectionRule> defaultRules = [
    // ---- Polite forms -------------------------------------------------
    ..._politeRules,
    // ---- Past and て-form ---------------------------------------------
    ..._pastRules,
    // ---- Negative ------------------------------------------------------
    ..._negativeRules,
    // ---- Passive, causative, potential ---------------------------------
    ..._voiceRules,
    // ---- Conditional, volitional, imperative ---------------------------
    ..._moodRules,
    // ---- Adjectives ----------------------------------------------------
    ..._adjectiveRules,
    // ---- Auxiliaries that attach to the ます-stem -----------------------
    ..._auxiliaryRules,
  ];
}

/// Builds the nine godan variants of a rule that differs only in the row.
///
/// Godan conjugation is regular across rows — 書かない/泳がない/話さない all
/// replace the same vowel — so writing out nine near-identical rules by hand
/// is how typos get in.
List<DeinflectionRule> _godan(
  String reason,
  String inflectedEnding,
  String dictionaryEnding, {
  Set<String> requiredTypes = const {},
}) {
  const rows = <String, (String, String)>{
    // dictionary ending -> (a-row, godan type)
    'う': ('わ', WordType.godanU),
    'く': ('か', WordType.godanKu),
    'ぐ': ('が', WordType.godanGu),
    'す': ('さ', WordType.godanSu),
    'つ': ('た', WordType.godanTsu),
    'ぬ': ('な', WordType.godanNu),
    'ぶ': ('ば', WordType.godanBu),
    'む': ('ま', WordType.godanMu),
    'る': ('ら', WordType.godanRu),
  };

  return [
    for (final entry in rows.entries)
      DeinflectionRule(
        reason: reason,
        suffixIn: entry.value.$1 + inflectedEnding,
        suffixOut: entry.key + dictionaryEnding,
        resultTypes: {entry.value.$2},
        requiredTypes: requiredTypes,
      ),
  ];
}

/// ます-stem forms of godan verbs: 書き, 泳ぎ, 話し ...
List<DeinflectionRule> _godanMasuStem(
  String reason,
  String inflectedEnding, {
  Set<String> requiredTypes = const {},
}) {
  const rows = <String, (String, String)>{
    'う': ('い', WordType.godanU),
    'く': ('き', WordType.godanKu),
    'ぐ': ('ぎ', WordType.godanGu),
    'す': ('し', WordType.godanSu),
    'つ': ('ち', WordType.godanTsu),
    'ぬ': ('に', WordType.godanNu),
    'ぶ': ('び', WordType.godanBu),
    'む': ('み', WordType.godanMu),
    'る': ('り', WordType.godanRu),
  };

  return [
    for (final entry in rows.entries)
      DeinflectionRule(
        reason: reason,
        suffixIn: entry.value.$1 + inflectedEnding,
        suffixOut: entry.key,
        resultTypes: {entry.value.$2},
        requiredTypes: const {},
      ),
  ];
}

const List<DeinflectionRule> _politeRules = [
  // Ichidan and the irregulars drop ます from the bare stem.
  DeinflectionRule(
    reason: 'polite',
    suffixIn: 'ます',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'polite past',
    suffixIn: 'ました',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'polite negative',
    suffixIn: 'ません',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'polite negative past',
    suffixIn: 'ませんでした',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'polite',
    suffixIn: 'します',
    suffixOut: 'する',
    resultTypes: {WordType.suru},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'polite',
    suffixIn: '来ます',
    suffixOut: '来る',
    resultTypes: {WordType.kuru},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'polite',
    suffixIn: 'きます',
    suffixOut: 'くる',
    resultTypes: {WordType.kuru},
    requiredTypes: {},
  ),
];

const List<DeinflectionRule> _pastRules = [
  DeinflectionRule(
    reason: 'past',
    suffixIn: 'た',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: '-te',
    suffixIn: 'て',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {},
  ),
  // Godan past and て-form involve sound changes that are not row-regular,
  // so they are written out.
  DeinflectionRule(
    reason: 'past',
    suffixIn: 'いた',
    suffixOut: 'く',
    resultTypes: {WordType.godanKu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'past',
    suffixIn: 'いだ',
    suffixOut: 'ぐ',
    resultTypes: {WordType.godanGu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'past',
    suffixIn: 'した',
    suffixOut: 'す',
    resultTypes: {WordType.godanSu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'past',
    suffixIn: 'んだ',
    suffixOut: 'ぬ',
    resultTypes: {WordType.godanNu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'past',
    suffixIn: 'んだ',
    suffixOut: 'ぶ',
    resultTypes: {WordType.godanBu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'past',
    suffixIn: 'んだ',
    suffixOut: 'む',
    resultTypes: {WordType.godanMu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'past',
    suffixIn: 'った',
    suffixOut: 'う',
    resultTypes: {WordType.godanU},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'past',
    suffixIn: 'った',
    suffixOut: 'つ',
    resultTypes: {WordType.godanTsu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'past',
    suffixIn: 'った',
    suffixOut: 'る',
    resultTypes: {WordType.godanRu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: '-te',
    suffixIn: 'いて',
    suffixOut: 'く',
    resultTypes: {WordType.godanKu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: '-te',
    suffixIn: 'いで',
    suffixOut: 'ぐ',
    resultTypes: {WordType.godanGu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: '-te',
    suffixIn: 'して',
    suffixOut: 'す',
    resultTypes: {WordType.godanSu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: '-te',
    suffixIn: 'んで',
    suffixOut: 'ぬ',
    resultTypes: {WordType.godanNu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: '-te',
    suffixIn: 'んで',
    suffixOut: 'ぶ',
    resultTypes: {WordType.godanBu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: '-te',
    suffixIn: 'んで',
    suffixOut: 'む',
    resultTypes: {WordType.godanMu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: '-te',
    suffixIn: 'って',
    suffixOut: 'う',
    resultTypes: {WordType.godanU},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: '-te',
    suffixIn: 'って',
    suffixOut: 'つ',
    resultTypes: {WordType.godanTsu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: '-te',
    suffixIn: 'って',
    suffixOut: 'る',
    resultTypes: {WordType.godanRu},
    requiredTypes: {},
  ),
  // 行く is the one godan-ku verb with a っ past.
  DeinflectionRule(
    reason: 'past',
    suffixIn: '行った',
    suffixOut: '行く',
    resultTypes: {WordType.godanKu},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'past',
    suffixIn: 'した',
    suffixOut: 'する',
    resultTypes: {WordType.suru},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: '-te',
    suffixIn: 'して',
    suffixOut: 'する',
    resultTypes: {WordType.suru},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'past',
    suffixIn: '来た',
    suffixOut: '来る',
    resultTypes: {WordType.kuru},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'past',
    suffixIn: 'きた',
    suffixOut: 'くる',
    resultTypes: {WordType.kuru},
    requiredTypes: {},
  ),
];

const List<DeinflectionRule> _negativeRules = [
  DeinflectionRule(
    reason: 'negative',
    suffixIn: 'ない',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {WordType.adjI},
  ),
  DeinflectionRule(
    reason: 'negative',
    suffixIn: 'しない',
    suffixOut: 'する',
    resultTypes: {WordType.suru},
    requiredTypes: {WordType.adjI},
  ),
  DeinflectionRule(
    reason: 'negative',
    suffixIn: '来ない',
    suffixOut: '来る',
    resultTypes: {WordType.kuru},
    requiredTypes: {WordType.adjI},
  ),
  DeinflectionRule(
    reason: 'negative',
    suffixIn: 'こない',
    suffixOut: 'くる',
    resultTypes: {WordType.kuru},
    requiredTypes: {WordType.adjI},
  ),
];

const List<DeinflectionRule> _voiceRules = [
  DeinflectionRule(
    reason: 'passive',
    suffixIn: 'られる',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {WordType.ichidan},
  ),
  DeinflectionRule(
    reason: 'causative',
    suffixIn: 'させる',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {WordType.ichidan},
  ),
  DeinflectionRule(
    reason: 'potential',
    suffixIn: 'られる',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {WordType.ichidan},
  ),
  DeinflectionRule(
    reason: 'causative',
    suffixIn: 'させる',
    suffixOut: 'する',
    resultTypes: {WordType.suru},
    requiredTypes: {WordType.ichidan},
  ),
  DeinflectionRule(
    reason: 'passive',
    suffixIn: 'される',
    suffixOut: 'する',
    resultTypes: {WordType.suru},
    requiredTypes: {WordType.ichidan},
  ),
];

const List<DeinflectionRule> _moodRules = [
  DeinflectionRule(
    reason: 'conditional',
    suffixIn: 'たら',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'volitional',
    suffixIn: 'よう',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'imperative',
    suffixIn: 'ろ',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'volitional',
    suffixIn: 'しよう',
    suffixOut: 'する',
    resultTypes: {WordType.suru},
    requiredTypes: {},
  ),
];

const List<DeinflectionRule> _adjectiveRules = [
  DeinflectionRule(
    reason: 'adjective past',
    suffixIn: 'かった',
    suffixOut: 'い',
    resultTypes: {WordType.adjI},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'adjective negative',
    suffixIn: 'くない',
    suffixOut: 'い',
    resultTypes: {WordType.adjI},
    requiredTypes: {WordType.adjI},
  ),
  DeinflectionRule(
    reason: 'adverbial',
    suffixIn: 'く',
    suffixOut: 'い',
    resultTypes: {WordType.adjI},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'adjective -te',
    suffixIn: 'くて',
    suffixOut: 'い',
    resultTypes: {WordType.adjI},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'adjective conditional',
    suffixIn: 'ければ',
    suffixOut: 'い',
    resultTypes: {WordType.adjI},
    requiredTypes: {},
  ),
  // いい is irregular: its stem is よ-.
  DeinflectionRule(
    reason: 'adjective past',
    suffixIn: 'よかった',
    suffixOut: 'いい',
    resultTypes: {WordType.adjI},
    requiredTypes: {},
  ),
];

const List<DeinflectionRule> _auxiliaryRules = [
  // The -たい form is an い-adjective built on the ます-stem, so undoing it has
  // to reach the dictionary form in one step. A rule that merely stripped
  // -たい would leave the bare stem 食べ, which is not a word and cannot be
  // deinflected further.
  DeinflectionRule(
    reason: 'desire',
    suffixIn: 'たい',
    suffixOut: 'る',
    resultTypes: {WordType.ichidan},
    requiredTypes: {WordType.adjI},
  ),
  DeinflectionRule(
    reason: 'desire',
    suffixIn: 'したい',
    suffixOut: 'する',
    resultTypes: {WordType.suru},
    requiredTypes: {WordType.adjI},
  ),
  DeinflectionRule(
    reason: 'desire',
    suffixIn: '来たい',
    suffixOut: '来る',
    resultTypes: {WordType.kuru},
    requiredTypes: {WordType.adjI},
  ),
  DeinflectionRule(
    reason: 'progressive',
    suffixIn: 'ている',
    suffixOut: 'て',
    resultTypes: {WordType.ichidan},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'progressive',
    suffixIn: 'てる',
    suffixOut: 'て',
    resultTypes: {WordType.ichidan},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'progressive',
    suffixIn: 'でいる',
    suffixOut: 'で',
    resultTypes: {WordType.ichidan},
    requiredTypes: {},
  ),
  DeinflectionRule(
    reason: 'progressive',
    suffixIn: 'でる',
    suffixOut: 'で',
    resultTypes: {WordType.ichidan},
    requiredTypes: {},
  ),
];

/// The godan rules, built from the row tables above.
///
/// Kept separate from [JapaneseDeinflector.defaultRules] because they are
/// generated rather than constant, and appended by [japaneseDeinflectionRules].
final List<DeinflectionRule> _generatedGodanRules = [
  ..._godanMasuStem('polite', 'ます'),
  ..._godanMasuStem('polite past', 'ました'),
  ..._godanMasuStem('polite negative', 'ません'),
  ..._godanMasuStem('polite negative past', 'ませんでした'),
  ..._godanMasuStem('desire', 'たい', requiredTypes: {WordType.adjI}),
  ..._godan('negative', 'ない', '', requiredTypes: {WordType.adjI}),
  ..._godan('passive', 'れる', '', requiredTypes: {WordType.ichidan}),
  ..._godan('causative', 'せる', '', requiredTypes: {WordType.ichidan}),
  ..._godanPotential(),
  ..._godanVolitional(),
  ..._godanConditional(),
];

/// Godan potential: 書く → 書ける (e-row + る).
List<DeinflectionRule> _godanPotential() {
  const rows = <String, (String, String)>{
    'う': ('え', WordType.godanU),
    'く': ('け', WordType.godanKu),
    'ぐ': ('げ', WordType.godanGu),
    'す': ('せ', WordType.godanSu),
    'つ': ('て', WordType.godanTsu),
    'ぬ': ('ね', WordType.godanNu),
    'ぶ': ('べ', WordType.godanBu),
    'む': ('め', WordType.godanMu),
    'る': ('れ', WordType.godanRu),
  };
  return [
    for (final entry in rows.entries) ...[
      DeinflectionRule(
        reason: 'potential',
        suffixIn: '${entry.value.$1}る',
        suffixOut: entry.key,
        resultTypes: {entry.value.$2},
        requiredTypes: const {WordType.ichidan},
      ),
      // The same e-row form is the imperative on its own.
      DeinflectionRule(
        reason: 'imperative',
        suffixIn: entry.value.$1,
        suffixOut: entry.key,
        resultTypes: {entry.value.$2},
        requiredTypes: const {},
      ),
    ],
  ];
}

/// Godan volitional: 書く → 書こう (o-row + う).
List<DeinflectionRule> _godanVolitional() {
  const rows = <String, (String, String)>{
    'う': ('お', WordType.godanU),
    'く': ('こ', WordType.godanKu),
    'ぐ': ('ご', WordType.godanGu),
    'す': ('そ', WordType.godanSu),
    'つ': ('と', WordType.godanTsu),
    'ぬ': ('の', WordType.godanNu),
    'ぶ': ('ぼ', WordType.godanBu),
    'む': ('も', WordType.godanMu),
    'る': ('ろ', WordType.godanRu),
  };
  return [
    for (final entry in rows.entries)
      DeinflectionRule(
        reason: 'volitional',
        suffixIn: '${entry.value.$1}う',
        suffixOut: entry.key,
        resultTypes: {entry.value.$2},
        requiredTypes: const {},
      ),
  ];
}

/// Godan provisional conditional: 書く → 書けば.
List<DeinflectionRule> _godanConditional() {
  const rows = <String, (String, String)>{
    'う': ('え', WordType.godanU),
    'く': ('け', WordType.godanKu),
    'ぐ': ('げ', WordType.godanGu),
    'す': ('せ', WordType.godanSu),
    'つ': ('て', WordType.godanTsu),
    'ぬ': ('ね', WordType.godanNu),
    'ぶ': ('べ', WordType.godanBu),
    'む': ('め', WordType.godanMu),
    'る': ('れ', WordType.godanRu),
  };
  return [
    for (final entry in rows.entries)
      DeinflectionRule(
        reason: 'conditional',
        suffixIn: '${entry.value.$1}ば',
        suffixOut: entry.key,
        resultTypes: {entry.value.$2},
        requiredTypes: const {},
      ),
  ];
}

/// The full rule table: the hand-written rules plus the generated godan ones.
final List<DeinflectionRule> japaneseDeinflectionRules = [
  ...JapaneseDeinflector.defaultRules,
  ..._generatedGodanRules,
];

/// A deinflector using the full rule table.
final JapaneseDeinflector japaneseDeinflector =
    JapaneseDeinflector(rules: japaneseDeinflectionRules);

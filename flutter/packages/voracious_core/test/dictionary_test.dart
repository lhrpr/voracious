import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

/// Two JMdict-style entries sharing a sequence, plus one standalone.
final termBank = <List<Object?>>[
  [
    '見る',
    'みる',
    'v1 vt',
    'v1',
    100,
    ['to see', 'to look'],
    1000,
    ''
  ],
  [
    '観る',
    'みる',
    'v1 vt',
    'v1',
    100,
    ['to watch (a movie)'],
    1000,
    ''
  ],
  [
    '食べる',
    'たべる',
    'v1 vt',
    'v1',
    100,
    ['to eat'],
    2000,
    ''
  ],
  [
    '書く',
    'かく',
    'v5k vt',
    'v5k',
    100,
    ['to write'],
    3000,
    ''
  ],
  [
    '高い',
    'たかい',
    'adj-i',
    'adj-i',
    100,
    ['expensive', 'tall'],
    4000,
    ''
  ],
];

YomichanDictionary buildDictionary(
        {String name = 'JMdict', bool builtIn = true}) =>
    YomichanDictionary.fromTermBanks(
      name: name,
      termBanks: termBank,
      isBuiltIn: builtIn,
    );

void main() {
  group('Yomichan index', () {
    final dictionary = buildDictionary();

    test('merges entries that share a sequence', () {
      final results = dictionary.lookupExact('見る');
      expect(results, hasLength(1));
      expect(results.single.words, containsAll(['見る', '観る']));
      expect(
        results.single.glosses,
        ['to see', 'to look', 'to watch (a movie)'],
        reason: 'both spellings contribute their definitions',
      );
    });

    test('indexes readings as well as spellings', () {
      expect(dictionary.lookupExact('みる'), hasLength(1));
      expect(dictionary.lookupExact('たべる').single.headword, '食べる');
    });

    test('an alternative spelling finds the same entry', () {
      expect(
        dictionary.lookupExact('観る').single.sequence,
        dictionary.lookupExact('見る').single.sequence,
      );
    });

    test('keeps part-of-speech tags', () {
      expect(dictionary.lookupExact('書く').single.tags, contains('v5k'));
    });

    test('reports nothing for an unknown word', () {
      expect(dictionary.lookupExact('存在しない'), isEmpty);
    });

    test('counts entries and forms', () {
      expect(dictionary.entryCount, 4);
      expect(dictionary.formCount, greaterThan(4));
    });

    test('parses index metadata', () {
      final info = YomichanIndexInfo.parse(
        '{"title":"JMdict (English)","format":3,"revision":"2026-01-01",'
        '"sequenced":true}',
      );
      expect(info.title, 'JMdict (English)');
      expect(info.format, 3);
      expect(info.isSequenced, isTrue);
    });

    test('accepts the Yomitan "version" spelling of format', () {
      expect(YomichanIndexInfo.parse('{"title":"x","version":3}').format, 3);
    });

    test('extracts text from structured-content glossaries', () {
      final dictionary = YomichanDictionary.fromTermBanks(
        name: 'structured',
        termBanks: [
          [
            '犬',
            'いぬ',
            '',
            '',
            0,
            [
              {'type': 'text', 'text': 'dog'},
              'canine',
            ],
            1,
            '',
          ],
        ],
      );
      expect(dictionary.lookupExact('犬').single.glosses, ['dog', 'canine']);
    });

    test('skips rows with no usable definition', () {
      final dictionary = YomichanDictionary.fromTermBanks(
        name: 'partial',
        termBanks: [
          ['犬', 'いぬ', '', '', 0, <Object?>[], 1, ''],
          [
            '猫',
            'ねこ',
            '',
            '',
            0,
            ['cat'],
            2,
            ''
          ],
        ],
      );
      expect(dictionary.entryCount, 1);
      expect(dictionary.lookupExact('猫'), hasLength(1));
    });
  });

  group('deinflection', () {
    List<String> forms(String word) => japaneseDeinflector.deinflectForms(word);
    List<String> reasons(String word, String target) => japaneseDeinflector
        .deinflect(word)
        .firstWhere((c) => c.form == target)
        .reasons;

    test('the word itself is always a candidate', () {
      expect(forms('食べる').first, '食べる');
    });

    test('undoes ichidan inflections', () {
      expect(forms('食べた'), contains('食べる'));
      expect(forms('食べて'), contains('食べる'));
      expect(forms('食べない'), contains('食べる'));
      expect(forms('食べます'), contains('食べる'));
      expect(forms('食べました'), contains('食べる'));
      expect(forms('食べません'), contains('食べる'));
    });

    test('undoes godan inflections across the rows', () {
      expect(forms('書いた'), contains('書く'));
      expect(forms('泳いだ'), contains('泳ぐ'));
      expect(forms('話した'), contains('話す'));
      expect(forms('待った'), contains('待つ'));
      expect(forms('飲んだ'), contains('飲む'));
      expect(forms('遊んだ'), contains('遊ぶ'));
      expect(forms('死んだ'), contains('死ぬ'));
      expect(forms('買った'), contains('買う'));
      expect(forms('帰った'), contains('帰る'));
    });

    test('undoes the godan ます-stem', () {
      expect(forms('書きます'), contains('書く'));
      expect(forms('飲みました'), contains('飲む'));
      expect(forms('話しません'), contains('話す'));
    });

    test('undoes godan negatives, potentials and volitionals', () {
      expect(forms('書かない'), contains('書く'));
      expect(forms('書ける'), contains('書く'));
      expect(forms('書こう'), contains('書く'));
      expect(forms('書けば'), contains('書く'));
    });

    test('undoes the irregular verbs', () {
      expect(forms('した'), contains('する'));
      expect(forms('して'), contains('する'));
      expect(forms('しない'), contains('する'));
      expect(forms('来た'), contains('来る'));
      expect(forms('来ない'), contains('来る'));
    });

    test('undoes adjective inflections', () {
      expect(forms('高かった'), contains('高い'));
      expect(forms('高くない'), contains('高い'));
      expect(forms('高くて'), contains('高い'));
      expect(forms('よかった'), contains('いい'));
    });

    test('undoes chains several inflections deep', () {
      expect(forms('食べたくなかった'), contains('食べる'));
      expect(forms('書かなかった'), contains('書く'));
    });

    test('records how it got there', () {
      expect(reasons('食べた', '食べる'), ['past']);
      expect(reasons('食べました', '食べる'), ['polite past']);
      expect(reasons('高かった', '高い'), ['adjective past']);
    });

    test('undoes the progressive', () {
      expect(forms('食べている'), contains('食べる'));
      expect(forms('飲んでる'), contains('飲む'));
    });

    test('never produces an empty form', () {
      for (final word in ['た', 'て', 'ない', 'る', 'い']) {
        expect(
            japaneseDeinflector.deinflectForms(word).every((f) => f.isNotEmpty),
            isTrue);
      }
    });

    test('an empty word yields nothing', () {
      expect(forms(''), isEmpty);
    });
  });

  group('DictionarySet', () {
    test('searches every enabled dictionary', () {
      final set = DictionarySet(dictionaries: [buildDictionary()]);
      final results = set.lookup('食べる');
      expect(results, hasLength(1));
      expect(results.single.dictionaryName, 'JMdict');
      expect(results.single.wasDeinflected, isFalse);
    });

    test('skips disabled dictionaries', () {
      final set = DictionarySet(dictionaries: [buildDictionary()])
        ..setEnabled('JMdict', false);
      expect(set.lookup('食べる'), isEmpty);

      set.setEnabled('JMdict', true);
      expect(set.lookup('食べる'), hasLength(1));
    });

    test('deinflects only when the exact form is not found', () {
      final set = DictionarySet(dictionaries: [buildDictionary()]);

      final direct = set.lookup(
        '食べる',
        deinflect: japaneseDeinflector.deinflect,
      );
      expect(direct.single.wasDeinflected, isFalse);

      final inflected = set.lookup(
        '食べました',
        deinflect: japaneseDeinflector.deinflect,
      );
      expect(inflected, hasLength(1));
      expect(inflected.single.matchedForm, '食べる');
      expect(inflected.single.deinflectionReasons, ['polite past']);
    });

    test('finds nothing for a word in no dictionary', () {
      final set = DictionarySet(dictionaries: [buildDictionary()]);
      expect(
        set.lookup('存在しない', deinflect: japaneseDeinflector.deinflect),
        isEmpty,
      );
    });

    test('reorders dictionaries and keeps unlisted ones at the end', () {
      final set = DictionarySet(dictionaries: [
        buildDictionary(name: 'A'),
        buildDictionary(name: 'B'),
        buildDictionary(name: 'C'),
      ])
        ..reorder(['C', 'A']);

      expect(set.all.map((d) => d.name), ['C', 'A', 'B']);
    });

    test('adding a dictionary of the same name replaces it', () {
      final set = DictionarySet(dictionaries: [buildDictionary(name: 'A')])
        ..add(buildDictionary(name: 'A', builtIn: false));
      expect(set.all, hasLength(1));
      expect(set.all.single.isBuiltIn, isFalse);
    });

    test('removes by name', () {
      final set = DictionarySet(dictionaries: [buildDictionary(name: 'A')]);
      expect(set.remove('A'), isTrue);
      expect(set.remove('A'), isFalse);
      expect(set.all, isEmpty);
    });

    test('results carry the dictionary they came from', () {
      final set = DictionarySet(dictionaries: [
        buildDictionary(name: 'First'),
        buildDictionary(name: 'Second'),
      ]);
      final results = set.lookup('食べる');
      expect(results.map((r) => r.dictionaryName), ['First', 'Second']);
    });
  });
}

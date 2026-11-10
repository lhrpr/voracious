import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voracious_app/src/widgets/vocab_line_view.dart';
import 'package:voracious_app/src/widgets/vocab_word_editor.dart';
import 'package:voracious_core/voracious_core.dart';

VocabWord word(String term, VocabStatus? status, {VocabParent? parent}) =>
    VocabWord(
      id: term,
      language: 'Spanish',
      term: term,
      translation: '',
      modifiedMs: 7,
      status: status,
      parent: parent,
    );

Color? backgroundOf(WidgetTester tester, String text) {
  final container = tester.widget<Container>(find
      .ancestor(of: find.text(text), matching: find.byType(Container))
      .first);
  return (container.decoration as BoxDecoration?)?.color;
}

void main() {
  const text = '¿El gobierno gobernaba bien?';
  final tokens = [
    const VocabToken(start: 1, end: 3, text: 'El'),
    VocabToken(
        start: 4,
        end: 12,
        text: 'gobierno',
        word: word('gobierno', VocabStatus.s3)),
    VocabToken(
      start: 13,
      end: 22,
      text: 'gobernaba',
      word: word('gobernaba', null,
          parent: const VocabParent(
              id: 'p',
              term: 'gobernar',
              translation: '',
              status: VocabStatus.s1)),
    ),
    VocabToken(
        start: 23,
        end: 27,
        text: 'bien',
        word: word('bien', VocabStatus.known)),
  ];

  testWidgets('words are coloured by status, a child by its parent',
      (tester) async {
    VocabToken? tapped;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VocabLineView(
          text: text,
          tokens: tokens,
          style: const TextStyle(fontSize: 20),
          onTap: (token, _) => tapped = token,
        ),
      ),
    ));

    expect(backgroundOf(tester, 'El'),
        vocabStatusColor(null, inCollection: false));
    expect(backgroundOf(tester, 'gobierno'),
        vocabStatusColor(VocabStatus.s3, inCollection: true));
    expect(backgroundOf(tester, 'gobernaba'),
        vocabStatusColor(VocabStatus.s1, inCollection: true));
    expect(backgroundOf(tester, 'bien'), isNull);

    await tester.tap(find.text('gobierno'));
    expect(tapped?.text, 'gobierno');
  });

  testWidgets('a status button saves straight away with the word\'s version',
      (tester) async {
    final edits = <VocabEdit>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showVocabWordEditor(
              context: context,
              token: tokens[1],
              wordRect: const Rect.fromLTWH(300, 500, 80, 30),
              settings: const VocabSettings(language: 'Spanish'),
              save: (edit) async {
                edits.add(edit);
                return const VocabSaveResult(outcome: VocabOutcome.updated);
              },
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('4'));
    await tester.pumpAndSettle();
    expect(edits.single.toJson(), {
      'language': 'Spanish',
      'term': 'gobierno',
      'status': '4',
      'expect_modified_ms': 7,
    });
    expect(find.text('Save'), findsNothing, reason: 'closed after saving');
  });

  testWidgets('a new word is saved in lower case with its parent',
      (tester) async {
    final edits = <VocabEdit>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showVocabWordEditor(
              context: context,
              token: const VocabToken(start: 0, end: 7, text: 'Hablaba'),
              wordRect: const Rect.fromLTWH(300, 500, 80, 30),
              settings: const VocabSettings(language: 'Spanish', deck: 'Films'),
              save: (edit) async {
                edits.add(edit);
                return const VocabSaveResult(outcome: VocabOutcome.created);
              },
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('New word'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Parent form (e.g. the infinitive)'),
        'hablar');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(edits.single.toJson(), {
      'language': 'Spanish',
      'term': 'hablaba',
      'parent': 'hablar',
      'deck': 'Films',
    });
  });
}

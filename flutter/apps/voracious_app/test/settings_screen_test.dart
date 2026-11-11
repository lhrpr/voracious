import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voracious_app/src/screens/settings_screen.dart';
import 'package:voracious_core/voracious_core.dart';

void main() {
  late List<Preferences> saved;

  Future<void> pump(WidgetTester tester, Preferences initial) async {
    saved = [];
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(
        initial: initial,
        onChanged: (p) async => saved.add(p),
      ),
    ));
  }

  testWidgets('a toggle saves the whole set with only that field changed',
      (tester) async {
    const initial = Preferences(subtitleOrder: ['spa'], playbackSpeed: 0.9);
    await pump(tester, initial);

    await tester.tap(find.text('Resume where I left off'));
    await tester.pump();

    expect(saved, hasLength(1));
    expect(saved.single.resumePlayback, isFalse);
    expect(saved.single.toJson(),
        initial.copyWith(resumePlayback: false).toJson());
  });

  testWidgets('choosing a starting mode saves it', (tester) async {
    await pump(tester, const Preferences());

    await tester.tap(find.byKey(const Key('subtitleMode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reading Practice').last);
    await tester.pumpAndSettle();

    expect(saved.last.subtitleMode, SubtitleMode.read);
    expect(find.text(SubtitleMode.read.description), findsOneWidget);
  });

  testWidgets('languages are added by name and removed', (tester) async {
    await pump(tester, const Preferences(subtitleOrder: ['eng']));
    expect(find.textContaining('English'), findsOneWidget);

    final field = find.widgetWithText(
        TextField, 'Add a language to “Language priority”');
    await tester.enterText(field, 'japan');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Japanese (jpn)'));
    await tester.pumpAndSettle();

    expect(saved.last.subtitleOrder, ['eng', 'jpn']);
    // The field is emptied for the next one.
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);

    await tester.tap(find.byTooltip('Remove English'));
    await tester.pump();
    expect(saved.last.subtitleOrder, ['jpn']);
  });

  testWidgets('furigana style is disabled while furigana is off',
      (tester) async {
    await pump(tester, const Preferences(showRuby: false));

    await tester.tap(find.text('カタカナ'));
    await tester.pump();
    expect(saved, isEmpty);

    await tester.tap(find.text('Show furigana'));
    await tester.pump();
    await tester.tap(find.text('カタカナ'));
    await tester.pump();
    expect(saved.last.showRuby, isTrue);
    expect(saved.last.rubyStyle, RubyStyle.katakana);
  });
}

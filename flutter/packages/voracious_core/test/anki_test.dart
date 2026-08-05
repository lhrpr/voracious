import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

/// Answers AnkiConnect requests from a script.
class FakeAnkiTransport implements AnkiTransport {
  FakeAnkiTransport(this.responder);

  final String Function(Map<String, Object?> request) responder;
  final List<Map<String, Object?>> requests = [];

  @override
  Future<String> post(Uri endpoint, String body) async {
    final request = jsonDecode(body) as Map<String, Object?>;
    requests.add(request);
    return responder(request);
  }
}

class UnreachableTransport implements AnkiTransport {
  @override
  Future<String> post(Uri endpoint, String body) async =>
      throw const SocketExceptionStub();
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'connection refused';
}

StudyCue makeCue() => StudyCue(
      id: 'cue1',
      begin: const Duration(seconds: 61),
      end: const Duration(seconds: 64),
      text: AnnotatedText.strict('食べる', const [
        WordAnnotation(cpBegin: 0, cpEnd: 3, lemma: '食べる'),
        RubyAnnotation(cpBegin: 0, cpEnd: 1, text: 'た'),
      ]),
    );

void main() {
  group('furigana bracket rendering', () {
    test('renders the notation the Japanese Support add-on expects', () {
      expect(renderWithFuriganaBrackets(makeCue().text), '食[た]べる');
    });

    test('separates a bracketed reading from preceding text', () {
      final text = AnnotatedText.strict('お食べる', const [
        RubyAnnotation(cpBegin: 1, cpEnd: 2, text: 'た'),
      ]);
      expect(renderWithFuriganaBrackets(text), 'お 食[た]べる');
    });

    test('plain text passes through', () {
      expect(renderWithFuriganaBrackets(AnnotatedText.plain('Hello')), 'Hello');
    });
  });

  group('card building', () {
    const settings = AnkiExportSettings(
      deckName: 'Japanese',
      modelName: 'Sentence',
      fieldMap: {
        'Expression': AnkiFieldSource.text,
        'Reading': AnkiFieldSource.textWithReadings,
        'Word': AnkiFieldSource.selectedText,
        'Meaning': AnkiFieldSource.definition,
        'English': AnkiFieldSource.translation,
        'Source': AnkiFieldSource.sourceTitle,
        'Time': AnkiFieldSource.timestamp,
        'Audio': AnkiFieldSource.audio,
        'Image': AnkiFieldSource.image,
      },
    );

    CardContext context() => CardContext(
          cue: makeCue(),
          translationCue: StudyCue(
            begin: const Duration(seconds: 61),
            end: const Duration(seconds: 64),
            text: AnnotatedText.plain('I eat.'),
          ),
          selectedText: '食べる',
          definitions: const ['to eat', 'to consume'],
          sourceTitle: 'Some Show S01E01',
          position: const Duration(minutes: 1, seconds: 2),
        );

    test('fills every text field from its source', () {
      final card = buildCard(context(), settings);

      expect(card.fields['Expression'], '食べる');
      expect(card.fields['Reading'], '食[た]べる');
      expect(card.fields['Word'], '食べる');
      expect(card.fields['Meaning'], 'to eat<br>to consume');
      expect(card.fields['English'], 'I eat.');
      expect(card.fields['Source'], 'Some Show S01E01');
      expect(card.fields['Time'], '00:01:02');
    });

    test('media fields start empty and are listed as pending', () {
      final card = buildCard(context(), settings);

      expect(card.fields['Audio'], '');
      expect(card.fields['Image'], '');
      expect(card.pendingMedia, hasLength(2));
      expect(card.needsMedia, isTrue);
      expect(
        card.pendingMedia.map((m) => m.suggestedFileName),
        everyElement(startsWith('voracious_')),
      );
    });

    test('media file names are unique per export', () {
      final first = buildCard(context(), settings).pendingMedia.first;
      final second = buildCard(context(), settings).pendingMedia.first;
      expect(first.suggestedFileName, isNot(second.suggestedFileName));
    });

    test('withMedia writes the markup Anki expects', () {
      final card = buildCard(context(), settings)
          .withMedia('Audio', AnkiFieldSource.audio, 'clip.mp3')
          .withMedia('Image', AnkiFieldSource.image, 'frame.jpg');

      expect(card.fields['Audio'], '[sound:clip.mp3]');
      expect(card.fields['Image'], '<img src="frame.jpg">');
      expect(card.needsMedia, isFalse);
    });

    test('an unconfigured deck is refused rather than guessed', () {
      expect(
        () => buildCard(context(), const AnkiExportSettings()),
        throwsStateError,
      );
    });

    test('missing optional context becomes an empty field', () {
      final card = buildCard(
        CardContext(cue: makeCue()),
        const AnkiExportSettings(
          deckName: 'd',
          modelName: 'm',
          fieldMap: {
            'Word': AnkiFieldSource.selectedText,
            'English': AnkiFieldSource.translation,
          },
        ),
      );
      expect(card.fields['Word'], '');
      expect(card.fields['English'], '');
    });

    test('audio range is padded and clamped at zero', () {
      final (begin, end) = audioRangeFor(makeCue(), settings);
      expect(begin, const Duration(milliseconds: 60750));
      expect(end, const Duration(milliseconds: 64250));

      final early = StudyCue(
        begin: const Duration(milliseconds: 100),
        end: const Duration(seconds: 1),
        text: AnnotatedText.plain('x'),
      );
      expect(audioRangeFor(early, settings).$1, Duration.zero);
    });

    test('settings know what media they need', () {
      expect(settings.needsAudio, isTrue);
      expect(settings.needsImage, isTrue);
      expect(const AnkiExportSettings().needsAudio, isFalse);
    });

    test('settings survive a JSON round trip', () {
      final restored = AnkiExportSettings.fromJson(settings.toJson());
      expect(restored.deckName, 'Japanese');
      expect(restored.fieldMap['Expression'], AnkiFieldSource.text);
      expect(restored.fieldMap['Audio'], AnkiFieldSource.audio);
      expect(restored.audioPadding, settings.audioPadding);
    });

    test('an unknown field source reads back as none', () {
      final restored = AnkiExportSettings.fromJson({
        'deckName': 'd',
        'modelName': 'm',
        'fieldMap': {'X': 'something_removed'},
      });
      expect(restored.fieldMap['X'], AnkiFieldSource.none);
    });
  });

  group('AnkiConnect client', () {
    test('sends the action, version and params', () async {
      final transport = FakeAnkiTransport((_) => '{"result":6,"error":null}');
      final client = AnkiConnectClient(transport: transport);

      expect(await client.version(), 6);
      expect(transport.requests.single['action'], 'version');
      expect(transport.requests.single['version'], 6);
    });

    test('reads list results', () async {
      final client = AnkiConnectClient(
        transport: FakeAnkiTransport(
          (_) => '{"result":["Default","Japanese"],"error":null}',
        ),
      );
      expect(await client.deckNames(), ['Default', 'Japanese']);
    });

    test('turns an error field into an exception', () async {
      final client = AnkiConnectClient(
        transport: FakeAnkiTransport(
          (_) => '{"result":null,"error":"deck was not found"}',
        ),
      );
      await expectLater(
        client.deckNames(),
        throwsA(isA<AnkiConnectException>().having(
          (e) => e.message,
          'message',
          contains('deck was not found'),
        )),
      );
    });

    test('a null result from addNote is reported clearly', () async {
      final client = AnkiConnectClient(
        transport: FakeAnkiTransport((_) => '{"result":null,"error":null}'),
      );
      await expectLater(
        client.addNote(const AnkiNote(
          deckName: 'd',
          modelName: 'm',
          fields: {'Front': 'x'},
        )),
        throwsA(isA<AnkiConnectException>().having(
          (e) => e.message,
          'message',
          contains('duplicate'),
        )),
      );
    });

    test('an unreachable Anki produces an actionable message', () async {
      final client = AnkiConnectClient(transport: UnreachableTransport());
      await expectLater(
        client.version(),
        throwsA(isA<AnkiConnectException>().having(
          (e) => e.message,
          'message',
          contains('Is Anki running'),
        )),
      );
      expect(await client.isAvailable(), isFalse);
    });

    test('non-JSON is reported rather than crashing', () async {
      final client = AnkiConnectClient(
        transport: FakeAnkiTransport((_) => '<html>404</html>'),
      );
      await expectLater(
        client.version(),
        throwsA(isA<AnkiConnectException>()),
      );
    });

    test('stores media as base64 and returns the stored name', () async {
      late Map<String, Object?> captured;
      final client = AnkiConnectClient(
        transport: FakeAnkiTransport((request) {
          captured = request;
          return '{"result":"clip_1.mp3","error":null}';
        }),
      );

      final stored = await client.storeMediaFile(
        'clip.mp3',
        Uint8List.fromList([1, 2, 3]),
      );

      expect(stored, 'clip_1.mp3');
      final params = captured['params']! as Map<String, Object?>;
      expect(params['data'], base64Encode([1, 2, 3]));
    });

    test('includes the API key when configured', () async {
      final transport = FakeAnkiTransport((_) => '{"result":6,"error":null}');
      await AnkiConnectClient(transport: transport, apiKey: 'secret').version();
      expect(transport.requests.single['key'], 'secret');
    });
  });

  group('exportCard', () {
    test('uploads media, rewrites the fields, then adds the note', () async {
      final actions = <String>[];
      final client = AnkiConnectClient(
        transport: FakeAnkiTransport((request) {
          final action = request['action']! as String;
          actions.add(action);
          if (action == 'storeMediaFile') {
            final params = request['params']! as Map<String, Object?>;
            return jsonEncode({'result': params['filename'], 'error': null});
          }
          return '{"result":12345,"error":null}';
        }),
      );

      final card = buildCard(
        CardContext(cue: makeCue()),
        const AnkiExportSettings(
          deckName: 'Japanese',
          modelName: 'Sentence',
          fieldMap: {
            'Expression': AnkiFieldSource.text,
            'Audio': AnkiFieldSource.audio,
          },
        ),
      );

      final noteId = await exportCard(
        card,
        client,
        mediaProvider: (field) async => Uint8List.fromList([1, 2, 3]),
      );

      expect(noteId, 12345);
      expect(actions, ['storeMediaFile', 'addNote']);
    });

    test('skips media the platform could not produce', () async {
      final actions = <String>[];
      final client = AnkiConnectClient(
        transport: FakeAnkiTransport((request) {
          actions.add(request['action']! as String);
          return '{"result":1,"error":null}';
        }),
      );

      final card = buildCard(
        CardContext(cue: makeCue()),
        const AnkiExportSettings(
          deckName: 'd',
          modelName: 'm',
          fieldMap: {'Audio': AnkiFieldSource.audio},
        ),
      );

      await exportCard(card, client, mediaProvider: (_) async => null);
      expect(actions, ['addNote'], reason: 'no upload without bytes');
    });
  });
}

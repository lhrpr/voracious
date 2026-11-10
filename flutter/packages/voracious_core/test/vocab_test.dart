import 'dart:convert';

import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

class FakeVocabTransport implements VocabTransport {
  FakeVocabTransport(this.responder);

  final VocabHttpResponse Function(Uri endpoint, Map<String, Object?> body)
      responder;
  final List<(Uri, Map<String, Object?>, Map<String, String>)> requests = [];

  @override
  Future<VocabHttpResponse> post(
    Uri endpoint,
    String body, {
    required Map<String, String> headers,
  }) async {
    final json = jsonDecode(body) as Map<String, Object?>;
    requests.add((endpoint, json, headers));
    return responder(endpoint, json);
  }
}

VocabClient clientFor(FakeVocabTransport transport) => VocabClient(
      transport: transport,
      baseUrl: Uri.parse('https://vocab.test/'),
      token: 'tok',
    );

void main() {
  test('annotate sends the texts and reads tokens with parents', () async {
    final transport = FakeVocabTransport((_, __) => VocabHttpResponse(
        200,
        jsonEncode({
          'texts': [
            [
              {
                'start': 0,
                'end': 8,
                'text': 'Gobierno',
                'word': {
                  'id': 'e1',
                  'language': 'Spanish',
                  'term': 'gobierno',
                  'translation': 'government',
                  'status': '3',
                  'modified_ms': 5,
                  'senses': <Object>[],
                  'sources': <Object>[],
                  'parent': null,
                }
              },
              {
                'start': 9,
                'end': 18,
                'text': 'gobernaba',
                'word': {
                  'id': 'e2',
                  'language': 'Spanish',
                  'term': 'gobernaba',
                  'translation': '',
                  'status': null,
                  'modified_ms': 6,
                  'parent': {
                    'id': 'e3',
                    'term': 'gobernar',
                    'translation': 'to govern',
                    'status': '4'
                  },
                }
              },
              {'start': 19, 'end': 22, 'text': 'mal', 'word': null},
            ],
          ],
        })));
    final tokens = await clientFor(transport)
        .annotate('Spanish', ['Gobierno gobernaba mal']);

    final (endpoint, body, headers) = transport.requests.single;
    expect(endpoint.toString(), 'https://vocab.test/v1/ext/annotate');
    expect(body, {
      'language': 'Spanish',
      'texts': ['Gobierno gobernaba mal']
    });
    expect(headers['Authorization'], 'Bearer tok');

    final line = tokens.single;
    expect(line.map((t) => t.displayStatus),
        [VocabStatus.s3, VocabStatus.s4, null]);
    expect(line[1].word!.parent!.term, 'gobernar');
    expect(line[2].word, isNull);
  });

  test('save sends only the fields being changed', () async {
    final transport = FakeVocabTransport((_, __) => VocabHttpResponse(
        200,
        jsonEncode({
          'results': [
            {
              'outcome': 'updated',
              'word': {
                'id': 'e1',
                'term': 'gobierno',
                'status': 'K',
                'modified_ms': 9
              }
            },
          ],
        })));
    final result = await clientFor(transport).save(const VocabEdit(
      language: 'Spanish',
      term: 'gobierno',
      status: VocabStatus.known,
      parent: '',
      expectModifiedMs: 5,
    ));

    expect(transport.requests.single.$2, {
      'version': vocabExtVersion,
      'words': [
        {
          'language': 'Spanish',
          'term': 'gobierno',
          'status': 'K',
          'parent': '',
          'expect_modified_ms': 5
        },
      ],
    });
    expect(result.outcome, VocabOutcome.updated);
    expect(result.word!.status, VocabStatus.known);
  });

  test('clearing a status sends null', () {
    const edit = VocabEdit(language: 'es', term: 'x', clearStatus: true);
    expect(edit.toJson().containsKey('status'), isTrue);
    expect(edit.toJson()['status'], isNull);
  });

  test('HTTP errors become VocabExceptions', () async {
    final transport =
        FakeVocabTransport((_, __) => const VocabHttpResponse(401, 'no'));
    await expectLater(
      clientFor(transport).annotate('es', ['hola']),
      throwsA(isA<VocabException>()
          .having((e) => e.message, 'message', contains('token'))),
    );
  });

  test('settings round-trip through preferences', () {
    const prefs = Preferences(
      vocab: VocabSettings(
          serverUrl: 'https://v.test', token: 't', language: 'Spanish'),
    );
    final back = Preferences.fromJson(
        jsonDecode(jsonEncode(prefs.toJson())) as Map<String, Object?>);
    expect(back.vocab.serverUrl, 'https://v.test');
    expect(back.vocab.isConfigured, isTrue);
    expect(const VocabSettings().isConfigured, isFalse);
  });
}

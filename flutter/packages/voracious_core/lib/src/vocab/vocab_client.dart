/// Talks to the vocab server (anki-alternative's sync server, `/v1/ext`), which
/// is the source of truth for word statuses, translations and parent forms.
///
/// Voracious asks it two things: how the words in a subtitle line stand
/// (`/v1/ext/annotate`, which also does the tokenizing, so multiword terms
/// match the way the server stores them), and to change a word
/// (`/v1/ext/words`). The transport is abstract so the request and response
/// handling can be tested without a server.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

/// The request format version the server expects on writes.
const int vocabExtVersion = 2;

/// Sends a JSON body and returns the status code and response body.
abstract interface class VocabTransport {
  Future<VocabHttpResponse> post(
    Uri endpoint,
    String body, {
    required Map<String, String> headers,
  });
}

@immutable
class VocabHttpResponse {
  const VocabHttpResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

/// Thrown when the server can't be reached or refuses a request.
class VocabException implements Exception {
  const VocabException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'VocabException: $message';
}

/// The I12345K scale, shared with Lute and the vocab server.
enum VocabStatus {
  ignored('I'),
  s1('1'),
  s2('2'),
  s3('3'),
  s4('4'),
  s5('5'),
  known('K');

  const VocabStatus(this.wireName);

  final String wireName;

  /// The label on a status button.
  String get label => wireName;

  static VocabStatus? byWireName(Object? name) {
    for (final status in values) {
      if (status.wireName == name) return status;
    }
    return null;
  }
}

/// A word's parent form, such as the infinitive of a conjugated verb.
@immutable
class VocabParent {
  const VocabParent({
    required this.id,
    required this.term,
    required this.translation,
    this.status,
  });

  factory VocabParent.fromJson(Map<String, Object?> json) => VocabParent(
        id: json['id']! as String,
        term: json['term']! as String,
        translation: json['translation'] as String? ?? '',
        status: VocabStatus.byWireName(json['status']),
      );

  final String id;
  final String term;
  final String translation;
  final VocabStatus? status;
}

/// One sense of a word, shown for reference: senses are edited in the vocab
/// app, not here.
@immutable
class VocabSense {
  const VocabSense({required this.cue, required this.translation, this.status});

  factory VocabSense.fromJson(Map<String, Object?> json) => VocabSense(
        cue: json['cue'] as String? ?? '',
        translation: json['translation'] as String? ?? '',
        status: VocabStatus.byWireName(json['status']),
      );

  final String cue;
  final String translation;
  final VocabStatus? status;
}

/// A word as the server reports it.
@immutable
class VocabWord {
  const VocabWord({
    required this.id,
    required this.language,
    required this.term,
    required this.translation,
    required this.modifiedMs,
    this.status,
    this.parent,
    this.senses = const [],
  });

  factory VocabWord.fromJson(Map<String, Object?> json) => VocabWord(
        id: json['id']! as String,
        language: json['language'] as String? ?? '',
        term: json['term']! as String,
        translation: json['translation'] as String? ?? '',
        modifiedMs: (json['modified_ms'] as num?)?.toInt() ?? 0,
        status: VocabStatus.byWireName(json['status']),
        parent: json['parent'] is Map
            ? VocabParent.fromJson(
                (json['parent']! as Map).cast<String, Object?>())
            : null,
        senses: [
          for (final sense in (json['senses'] as List?) ?? const [])
            if (sense is Map)
              VocabSense.fromJson(sense.cast<String, Object?>()),
        ],
      );

  final String id;
  final String language;
  final String term;
  final String translation;

  /// Sent back with an edit, so a change made elsewhere in the meantime is
  /// reported as a conflict rather than overwritten.
  final int modifiedMs;

  final VocabStatus? status;
  final VocabParent? parent;
  final List<VocabSense> senses;
}

/// A word (or multiword term) in a line of text, by code point offsets.
@immutable
class VocabToken {
  const VocabToken({
    required this.start,
    required this.end,
    required this.text,
    this.word,
  });

  factory VocabToken.fromJson(Map<String, Object?> json) => VocabToken(
        start: (json['start']! as num).toInt(),
        end: (json['end']! as num).toInt(),
        text: json['text']! as String,
        word: json['word'] is Map
            ? VocabWord.fromJson((json['word']! as Map).cast<String, Object?>())
            : null,
      );

  /// First code point, inclusive.
  final int start;

  /// Last code point, exclusive.
  final int end;

  final String text;

  /// Null when the collection doesn't have it.
  final VocabWord? word;

  /// What to colour it by: its own status, or its parent's when it has none
  /// of its own (a conjugation saved only to point at its infinitive). Null
  /// means new to the collection.
  VocabStatus? get displayStatus => word?.status ?? word?.parent?.status;
}

/// Where an edit's example sentence came from.
@immutable
class VocabContext {
  const VocabContext({
    required this.sentence,
    required this.sourceRef,
    required this.sourceTitle,
    this.location = '',
    this.sourceKind = 'video',
  });

  final String sentence;

  /// Voracious's own id for the video, e.g. `voracious:<video id>`.
  final String sourceRef;
  final String sourceTitle;
  final String sourceKind;

  /// Where in the video, e.g. `12:34`.
  final String location;

  Map<String, Object?> toJson() => {
        'sentence': sentence,
        'location': location,
        'source': {
          'external_ref': sourceRef,
          'title': sourceTitle,
          'kind': sourceKind,
        },
      };
}

/// A change to one word. Fields left null are left alone; [clearStatus] and an
/// empty [parent] clear.
@immutable
class VocabEdit {
  const VocabEdit({
    required this.language,
    required this.term,
    this.status,
    this.clearStatus = false,
    this.translation,
    this.parent,
    this.context,
    this.expectModifiedMs,
    this.deck,
  });

  final String language;
  final String term;
  final VocabStatus? status;
  final bool clearStatus;
  final String? translation;

  /// The parent form's term; `''` removes the parent.
  final String? parent;
  final VocabContext? context;
  final int? expectModifiedMs;

  /// Deck for a word that doesn't exist yet.
  final String? deck;

  Map<String, Object?> toJson() => {
        'language': language,
        'term': term,
        if (status != null) 'status': status!.wireName,
        if (status == null && clearStatus) 'status': null,
        if (translation != null) 'translation': translation,
        if (parent != null) 'parent': parent,
        if (context != null) 'context': context!.toJson(),
        if (expectModifiedMs != null) 'expect_modified_ms': expectModifiedMs,
        if (deck != null && deck!.isNotEmpty) 'deck': deck,
      };
}

enum VocabOutcome { created, updated, unchanged, conflict, error }

@immutable
class VocabSaveResult {
  const VocabSaveResult({required this.outcome, this.word, this.error});

  final VocabOutcome outcome;

  /// The word as it now is (absent on errors). On a conflict, the version
  /// that was changed elsewhere.
  final VocabWord? word;
  final String? error;
}

/// A client for the vocab server's external API.
class VocabClient {
  VocabClient({
    required this.transport,
    required this.baseUrl,
    required this.token,
  });

  final VocabTransport transport;
  final Uri baseUrl;
  final String token;

  /// Splits each text into words and reports each one's entry. One list per
  /// text, in order.
  Future<List<List<VocabToken>>> annotate(
    String language,
    List<String> texts,
  ) async {
    final json = await _post('/v1/ext/annotate', {
      'language': language,
      'texts': texts,
    });
    final lists = json['texts'];
    if (lists is! List || lists.length != texts.length) {
      throw const VocabException('the server sent a malformed annotation');
    }
    return [
      for (final list in lists)
        [
          for (final token in (list as List))
            VocabToken.fromJson((token as Map).cast<String, Object?>()),
        ],
    ];
  }

  /// Creates or updates a word.
  Future<VocabSaveResult> save(VocabEdit edit) async {
    final json = await _post('/v1/ext/words', {
      'version': vocabExtVersion,
      'words': [edit.toJson()],
    });
    final results = json['results'];
    if (results is! List || results.length != 1 || results.first is! Map) {
      throw const VocabException('the server sent a malformed reply');
    }
    final result = (results.first as Map).cast<String, Object?>();
    return VocabSaveResult(
      outcome: VocabOutcome.values.firstWhere(
        (o) => o.name == result['outcome'],
        orElse: () => VocabOutcome.error,
      ),
      word: result['word'] is Map
          ? VocabWord.fromJson((result['word']! as Map).cast<String, Object?>())
          : null,
      error: result['error'] as String?,
    );
  }

  Future<Map<String, Object?>> _post(String path, Object body) async {
    final VocabHttpResponse response;
    try {
      response = await transport.post(
        baseUrl.resolve(path),
        jsonEncode(body),
        headers: {'Authorization': 'Bearer $token'},
      );
    } on VocabException {
      rethrow;
    } on Object catch (error) {
      throw VocabException('could not reach the vocab server: $error');
    }
    if (response.statusCode != 200) {
      final detail = response.body.trim();
      throw VocabException(
        switch (response.statusCode) {
          401 => 'the vocab server refused the token',
          _ => 'the vocab server returned HTTP ${response.statusCode}'
              '${detail.isEmpty ? '' : ': $detail'}',
        },
        statusCode: response.statusCode,
      );
    }
    final Object? json;
    try {
      json = jsonDecode(response.body);
    } on FormatException {
      throw const VocabException('the vocab server sent something not JSON');
    }
    if (json is! Map) {
      throw const VocabException('the vocab server sent an unexpected reply');
    }
    return json.cast<String, Object?>();
  }
}

/// Connection details for the vocab server, and which subtitles to look up.
@immutable
class VocabSettings {
  const VocabSettings({
    this.serverUrl = '',
    this.token = '',
    this.language = '',
    this.trackLanguage = '',
    this.deck = '',
  });

  /// e.g. `https://vocab.example.com`.
  final String serverUrl;

  /// An `EXT_TOKEN` from the server's configuration.
  final String token;

  /// The language as the vocab collection names it, e.g. `Spanish`.
  final String language;

  /// ISO 639-3 code of the subtitle tracks to look up, e.g. `spa`. Empty
  /// means the first track (the one being learned, by the subtitle order).
  final String trackLanguage;

  /// Deck for words added from Voracious; the server's Default when empty.
  final String deck;

  bool get isConfigured =>
      Uri.tryParse(serverUrl.trim())?.hasScheme == true &&
      token.trim().isNotEmpty &&
      language.trim().isNotEmpty;

  VocabSettings copyWith({
    String? serverUrl,
    String? token,
    String? language,
    String? trackLanguage,
    String? deck,
  }) =>
      VocabSettings(
        serverUrl: serverUrl ?? this.serverUrl,
        token: token ?? this.token,
        language: language ?? this.language,
        trackLanguage: trackLanguage ?? this.trackLanguage,
        deck: deck ?? this.deck,
      );

  Map<String, Object?> toJson() => {
        'serverUrl': serverUrl,
        'token': token,
        'language': language,
        'trackLanguage': trackLanguage,
        'deck': deck,
      };

  static VocabSettings fromJson(Map<String, Object?> json) => VocabSettings(
        serverUrl:
            json['serverUrl'] is String ? json['serverUrl']! as String : '',
        token: json['token'] is String ? json['token']! as String : '',
        language: json['language'] is String ? json['language']! as String : '',
        trackLanguage: json['trackLanguage'] is String
            ? json['trackLanguage']! as String
            : '',
        deck: json['deck'] is String ? json['deck']! as String : '',
      );
}

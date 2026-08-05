/// Talks to AnkiConnect, the add-on that exposes a local HTTP API for Anki.
///
/// The transport is abstract so that the request/response handling — which is
/// where the fiddly parts are, since AnkiConnect signals failure with HTTP 200
/// and an `error` field — can be tested without a running Anki.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Sends a request body to AnkiConnect and returns the response body.
abstract interface class AnkiTransport {
  Future<String> post(Uri endpoint, String body);
}

/// Thrown when AnkiConnect reports a problem or cannot be reached.
class AnkiConnectException implements Exception {
  const AnkiConnectException(this.message, {this.action});

  final String message;

  /// The AnkiConnect action that failed, when known.
  final String? action;

  @override
  String toString() =>
      'AnkiConnectException${action != null ? ' ($action)' : ''}: $message';
}

/// A note to add.
@immutable
class AnkiNote {
  const AnkiNote({
    required this.deckName,
    required this.modelName,
    required this.fields,
    this.tags = const [],
    this.allowDuplicate = false,
  });

  final String deckName;
  final String modelName;

  /// Anki field name to its contents. Media is referenced from here by the
  /// `[sound:...]` and `<img src="...">` markup Anki expects, after the file
  /// itself has been sent with [AnkiConnectClient.storeMediaFile].
  final Map<String, String> fields;

  final List<String> tags;

  final bool allowDuplicate;

  Map<String, Object?> toJson() => {
        'deckName': deckName,
        'modelName': modelName,
        'fields': fields,
        'tags': tags,
        'options': {
          'allowDuplicate': allowDuplicate,
          'duplicateScope': 'deck',
        },
      };
}

/// A client for the AnkiConnect add-on.
class AnkiConnectClient {
  AnkiConnectClient({
    required this.transport,
    Uri? endpoint,
    this.apiVersion = 6,
    this.apiKey,
  }) : endpoint = endpoint ?? defaultEndpoint;

  /// AnkiConnect listens on loopback only, which is what makes it safe to call
  /// without authentication.
  static final Uri defaultEndpoint = Uri.parse('http://127.0.0.1:8765');

  final AnkiTransport transport;
  final Uri endpoint;
  final int apiVersion;

  /// Set when the user has configured `apiKey` in AnkiConnect.
  final String? apiKey;

  /// True when Anki is running with AnkiConnect loaded.
  Future<bool> isAvailable() async {
    try {
      await version();
      return true;
    } on AnkiConnectException {
      return false;
    }
  }

  Future<int> version() async {
    final result = await invoke('version');
    return (result! as num).toInt();
  }

  Future<List<String>> deckNames() async =>
      ((await invoke('deckNames'))! as List<Object?>).cast<String>();

  Future<List<String>> modelNames() async =>
      ((await invoke('modelNames'))! as List<Object?>).cast<String>();

  Future<List<String>> modelFieldNames(String modelName) async =>
      ((await invoke('modelFieldNames', {'modelName': modelName}))!
              as List<Object?>)
          .cast<String>();

  /// Adds a note, returning its id.
  Future<int> addNote(AnkiNote note) async {
    final result = await invoke('addNote', {'note': note.toJson()});
    if (result == null) {
      throw const AnkiConnectException(
        'Anki refused the note. The most common cause is a duplicate first '
        'field.',
        action: 'addNote',
      );
    }
    return (result as num).toInt();
  }

  /// Stores a media file in Anki's collection folder, returning the name it
  /// was stored under.
  ///
  /// Anki may rename the file to avoid a collision, so the returned name — not
  /// the requested one — is what a field must reference.
  Future<String> storeMediaFile(String filename, Uint8List data) async {
    final result = await invoke('storeMediaFile', {
      'filename': filename,
      'data': base64Encode(data),
    });
    return result is String ? result : filename;
  }

  /// Sends one AnkiConnect action and returns its `result`.
  ///
  /// AnkiConnect answers every request with HTTP 200 and reports failure in
  /// the body, so the error handling is here rather than in the transport.
  Future<Object?> invoke(String action, [Map<String, Object?>? params]) async {
    final request = jsonEncode({
      'action': action,
      'version': apiVersion,
      if (params != null) 'params': params,
      if (apiKey != null) 'key': apiKey,
    });

    final String body;
    try {
      body = await transport.post(endpoint, request);
    } on Object catch (error) {
      throw AnkiConnectException(
        'could not reach AnkiConnect at $endpoint. Is Anki running with the '
        'AnkiConnect add-on installed? ($error)',
        action: action,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw AnkiConnectException(
        'AnkiConnect returned something that is not JSON',
        action: action,
      );
    }

    if (decoded is! Map) {
      throw AnkiConnectException(
        'unexpected response shape from AnkiConnect',
        action: action,
      );
    }

    final response = decoded.cast<String, Object?>();
    final error = response['error'];
    if (error != null) {
      throw AnkiConnectException(error.toString(), action: action);
    }
    if (!response.containsKey('result')) {
      throw AnkiConnectException(
        'AnkiConnect response had no result field',
        action: action,
      );
    }
    return response['result'];
  }
}

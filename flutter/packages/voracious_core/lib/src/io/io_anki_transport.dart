/// An [AnkiTransport] over `dart:io`'s HTTP client.
library;

import 'dart:convert';
import 'dart:io';

import '../anki/anki_connect.dart';

/// Posts to AnkiConnect over loopback HTTP.
class IoAnkiTransport implements AnkiTransport {
  IoAnkiTransport({Duration timeout = const Duration(seconds: 10)})
      : _client = HttpClient()
          ..connectionTimeout = timeout
          ..idleTimeout = timeout;

  final HttpClient _client;

  @override
  Future<String> post(Uri endpoint, String body) async {
    final request = await _client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    request.write(body);

    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();

    if (response.statusCode != HttpStatus.ok) {
      throw AnkiConnectException(
        'AnkiConnect returned HTTP ${response.statusCode}',
      );
    }
    return text;
  }

  /// Closes the underlying connection pool.
  void close() => _client.close(force: true);
}

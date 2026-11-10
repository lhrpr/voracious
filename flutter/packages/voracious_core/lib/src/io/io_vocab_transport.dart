/// A [VocabTransport] over `dart:io`'s HTTP client.
library;

import 'dart:convert';
import 'dart:io';

import '../vocab/vocab_client.dart';

class IoVocabTransport implements VocabTransport {
  IoVocabTransport({Duration timeout = const Duration(seconds: 10)})
      : _timeout = timeout,
        _client = HttpClient()..connectionTimeout = timeout;

  final HttpClient _client;
  final Duration _timeout;

  @override
  Future<VocabHttpResponse> post(
    Uri endpoint,
    String body, {
    required Map<String, String> headers,
  }) async {
    final request = await _client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    headers.forEach(request.headers.set);
    request.add(utf8.encode(body));
    final response = await request.close().timeout(_timeout);
    final text = await response.transform(utf8.decoder).join();
    return VocabHttpResponse(response.statusCode, text);
  }

  void close() => _client.close(force: true);
}

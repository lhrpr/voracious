/// A [MetadataTransport] over `dart:io`'s HTTP client.
library;

import 'dart:convert';
import 'dart:io';

import '../metadata/metadata_http.dart';

class IoMetadataTransport implements MetadataTransport {
  IoMetadataTransport({Duration timeout = const Duration(seconds: 15)})
      : _timeout = timeout,
        _client = HttpClient()
          ..connectionTimeout = timeout
          ..userAgent = 'Voracious';

  final HttpClient _client;
  final Duration _timeout;

  @override
  Future<MetadataHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    final request = await _client.getUrl(url).timeout(_timeout);
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(_timeout);
    final body = await response.transform(utf8.decoder).join().timeout(_timeout);
    final retryAfter = int.tryParse(
        response.headers.value(HttpHeaders.retryAfterHeader) ?? '');
    return MetadataHttpResponse(
      response.statusCode,
      body,
      retryAfter: retryAfter == null ? null : Duration(seconds: retryAfter),
    );
  }

  void close() => _client.close(force: true);
}

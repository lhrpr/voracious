/// The HTTP side of metadata lookups, abstract so providers can be tested
/// against canned responses.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

/// Performs a GET and returns the status code and body.
abstract interface class MetadataTransport {
  Future<MetadataHttpResponse> get(Uri url, {Map<String, String> headers});
}

@immutable
class MetadataHttpResponse {
  const MetadataHttpResponse(this.statusCode, this.body, {this.retryAfter});

  final int statusCode;
  final String body;

  /// From a 429's `Retry-After` header, when it had one.
  final Duration? retryAfter;
}

/// A lookup that could not be completed: no network, a refused key, or a
/// service returning something unexpected. A title that simply has no match
/// is not an exception — that is an empty result.
class MetadataException implements Exception {
  const MetadataException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  /// The service refused the API key. Retrying will not help until the key
  /// is changed.
  bool get isAuthFailure => statusCode == 401;

  @override
  String toString() => 'MetadataException: $message';
}

/// Fetches [url] as JSON, waiting and retrying when the service rate-limits.
///
/// TVmaze allows about 20 requests per 10 seconds and says so with a 429; a
/// first scan of a large library goes past that, so a 429 is a reason to wait,
/// not to fail.
Future<Object?> getJson(
  MetadataTransport transport,
  Uri url, {
  required String service,
  Map<String, String> headers = const {},
  int attempts = 4,
  Future<void> Function(Duration) delay = _delay,
}) async {
  for (var attempt = 1;; attempt++) {
    final MetadataHttpResponse response;
    try {
      response = await transport.get(url, headers: headers);
    } on MetadataException {
      rethrow;
    } on Object catch (error) {
      throw MetadataException('could not reach $service: $error');
    }

    if (response.statusCode == 429 && attempt < attempts) {
      await delay(response.retryAfter ?? Duration(seconds: 2 * attempt));
      continue;
    }
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw MetadataException(
        switch (response.statusCode) {
          401 => '$service refused the API key',
          429 => '$service is rate-limiting requests; try again shortly',
          _ => '$service returned HTTP ${response.statusCode}',
        },
        statusCode: response.statusCode,
      );
    }
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw MetadataException('$service sent something that is not JSON');
    }
  }
}

Future<void> _delay(Duration duration) => Future<void>.delayed(duration);

/// Reads a year from an ISO date (`2007-07-19`), or null.
int? yearOfDate(Object? date) =>
    date is String && date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null;

/// A non-empty string, or null.
String? nonEmpty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

/// Turns a TVmaze HTML summary (`<p>Don Draper is <b>…</b></p>`) into plain
/// text.
String? plainTextFromHtml(Object? html) {
  if (html is! String) return null;
  var text = html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p>\s*<p>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<[^>]*>'), '');
  text = text
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');
  text = text.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (m) => String.fromCharCode(int.parse(m.group(1)!)),
  );
  return nonEmpty(text);
}

/// Looks up subtitle lines on the vocab server and remembers the answers.
///
/// Lines are only looked up while paused, so playback never waits on the
/// network and the server sees a request per pause rather than per cue. The
/// answers are kept by line text for the rest of the session: pausing on the
/// same line again, or stepping back to it, colours it at once. Any edit
/// clears everything, because changing one word's status (or giving it a
/// parent) changes how every line containing it, or its children, is coloured.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:voracious_core/voracious_core.dart';

class VocabHighlighter extends ChangeNotifier {
  VocabHighlighter({required this.settings, required this.client});

  final VocabSettings settings;
  final VocabClient client;

  final Map<String, List<VocabToken>> _tokens = {};
  final Set<String> _pending = {};

  /// Bumped on every edit, so an answer to a request sent before the edit is
  /// dropped rather than cached stale.
  int _generation = 0;

  bool _disposed = false;

  String? _error;

  /// Why the last lookup failed, until one succeeds.
  String? get error => _error;

  bool get isLoading => _pending.isNotEmpty;

  /// The words of [text], once looked up.
  List<VocabToken>? tokensFor(String text) => _tokens[text];

  /// Looks up whichever of [texts] aren't known or on their way.
  void request(Iterable<String> texts) {
    final missing = {
      for (final text in texts)
        if (text.trim().isNotEmpty &&
            !_tokens.containsKey(text) &&
            !_pending.contains(text))
          text,
    }.toList();
    if (missing.isEmpty) return;
    _pending.addAll(missing);
    notifyListeners();
    unawaited(_fetch(missing, _generation));
  }

  Future<void> _fetch(List<String> texts, int generation) async {
    try {
      final results = await client.annotate(settings.language, texts);
      if (_disposed || generation != _generation) return;
      for (var i = 0; i < texts.length; i++) {
        _tokens[texts[i]] = results[i];
      }
      _error = null;
    } on VocabException catch (e) {
      if (_disposed || generation != _generation) return;
      _error = e.message;
    } finally {
      if (!_disposed && generation == _generation) {
        _pending.removeAll(texts);
        notifyListeners();
      }
    }
  }

  /// Saves an edit and forgets every line, so they're looked up again.
  Future<VocabSaveResult> save(VocabEdit edit) async {
    final result = await client.save(edit);
    if (_disposed) return result;
    if (result.outcome == VocabOutcome.created ||
        result.outcome == VocabOutcome.updated) {
      _generation++;
      _tokens.clear();
      _pending.clear();
      notifyListeners();
    }
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

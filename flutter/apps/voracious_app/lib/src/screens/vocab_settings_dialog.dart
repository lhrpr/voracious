/// Where the vocab server is, and which subtitles to colour.
library;

import 'package:flutter/material.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:voracious_core/voracious_core_io.dart';

/// Returns the edited settings, or null if cancelled.
Future<VocabSettings?> showVocabSettingsDialog(
  BuildContext context,
  VocabSettings current,
) =>
    showDialog<VocabSettings>(
      context: context,
      builder: (_) => _VocabSettingsDialog(current: current),
    );

class _VocabSettingsDialog extends StatefulWidget {
  const _VocabSettingsDialog({required this.current});

  final VocabSettings current;

  @override
  State<_VocabSettingsDialog> createState() => _VocabSettingsDialogState();
}

class _VocabSettingsDialogState extends State<_VocabSettingsDialog> {
  late final _url = TextEditingController(text: widget.current.serverUrl);
  late final _token = TextEditingController(text: widget.current.token);
  late final _language = TextEditingController(text: widget.current.language);
  late final _track = TextEditingController(text: widget.current.trackLanguage);
  late final _deck = TextEditingController(text: widget.current.deck);

  String? _testResult;
  bool _testing = false;

  @override
  void dispose() {
    for (final c in [_url, _token, _language, _track, _deck]) {
      c.dispose();
    }
    super.dispose();
  }

  VocabSettings get _settings => VocabSettings(
        serverUrl: _url.text.trim(),
        token: _token.text.trim(),
        language: _language.text.trim(),
        trackLanguage: _track.text.trim(),
        deck: _deck.text.trim(),
      );

  Future<void> _test() async {
    final settings = _settings;
    if (!settings.isConfigured) {
      setState(() => _testResult = 'Fill in the address, token and language.');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final transport = IoVocabTransport();
    try {
      final client = VocabClient(
        transport: transport,
        baseUrl: Uri.parse(settings.serverUrl),
        token: settings.token,
      );
      final tokens = await client.annotate(settings.language, ['hola']);
      final known = tokens.first.where((t) => t.word != null).length;
      _testResult = 'Connected. '
          '${known == 0 ? '“hola” isn’t in the collection.' : '“hola” is in the collection.'}';
    } on VocabException catch (e) {
      _testResult = e.message;
    } finally {
      transport.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Vocab server'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'While a video is paused, words in the learning-language '
                'subtitles are coloured by their status in your vocab '
                'collection. Click one to change it.',
              ),
              const SizedBox(height: 12),
              _field(_url, 'Server address', 'https://vocab.example.com'),
              _field(_token, 'External API token', 'an EXT_TOKEN value',
                  obscure: true),
              _field(
                  _language, 'Language, as the collection names it', 'Spanish'),
              _field(_track, 'Subtitle language code (optional)',
                  'spa — empty means the first track'),
              _field(_deck, 'Deck for new words (optional)', 'Default'),
              if (_testResult != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_testResult!),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _testing ? null : _test,
            child: Text(_testing ? 'Testing…' : 'Test'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_settings),
            child: const Text('Save'),
          ),
        ],
      );

  Widget _field(
    TextEditingController controller,
    String label,
    String hint, {
    bool obscure = false,
  }) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: TextField(
          controller: controller,
          obscureText: obscure,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
      );
}

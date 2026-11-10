/// Whether titles are matched to online metadata, and the optional TMDB key.
library;

import 'package:flutter/material.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:voracious_core/voracious_core_io.dart';

/// Returns the edited settings, or null if cancelled.
Future<MetadataSettings?> showMetadataSettingsDialog(
  BuildContext context,
  MetadataSettings current,
) =>
    showDialog<MetadataSettings>(
      context: context,
      builder: (_) => _MetadataSettingsDialog(current: current),
    );

class _MetadataSettingsDialog extends StatefulWidget {
  const _MetadataSettingsDialog({required this.current});

  final MetadataSettings current;

  @override
  State<_MetadataSettingsDialog> createState() =>
      _MetadataSettingsDialogState();
}

class _MetadataSettingsDialogState extends State<_MetadataSettingsDialog> {
  late bool _enabled = widget.current.enabled;
  late final _key = TextEditingController(text: widget.current.tmdbApiKey);
  late final _language = TextEditingController(text: widget.current.language);

  String? _testResult;
  bool _testing = false;

  @override
  void dispose() {
    _key.dispose();
    _language.dispose();
    super.dispose();
  }

  MetadataSettings get _settings => MetadataSettings(
        enabled: _enabled,
        tmdbApiKey: _key.text.trim(),
        language: _language.text.trim().isEmpty ? 'en-US' : _language.text.trim(),
      );

  Future<void> _test() async {
    final settings = _settings;
    if (!settings.hasTmdb) {
      setState(() => _testResult = 'Enter a TMDB key to test it.');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final transport = IoMetadataTransport();
    try {
      final provider = TmdbProvider(
        transport: transport,
        apiKey: settings.tmdbApiKey,
        language: settings.language,
      );
      final results = await provider.search('Mad Men', MetadataKind.series);
      _testResult = results.isEmpty
          ? 'Connected, but the test search found nothing.'
          : 'Connected. Test search found “${results.first.name}”.';
    } on MetadataException catch (e) {
      _testResult = e.message;
    } finally {
      transport.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Metadata'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Match titles online'),
                subtitle: const Text(
                  'Look up posters, episode titles and summaries after each '
                  'scan. Only title names are sent.',
                ),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
              const SizedBox(height: 8),
              const Text(
                'Series are matched with TVmaze, which needs no key. A free '
                'TMDB API key (themoviedb.org → Settings → API) adds films, '
                'and titles in the language you choose.',
                style: TextStyle(fontSize: 12),
              ),
              _field(_key, 'TMDB API key or read access token (optional)',
                  'leave empty to use TVmaze only',
                  obscure: true),
              _field(_language, 'TMDB language', 'en-US, ja-JP, es-ES…'),
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
            child: Text(_testing ? 'Testing…' : 'Test key'),
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
          enabled: _enabled,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
      );
}

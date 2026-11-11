/// Every preference the core stores, on one screen.
///
/// Changes save as they are made. The player reads preferences when a video
/// opens, so a change applies from the next video.
library;

import 'package:flutter/material.dart';
import 'package:voracious_core/voracious_core.dart';

import 'metadata_settings_dialog.dart';
import 'vocab_settings_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initial,
    required this.onChanged,
    this.showMetadata = true,
  });

  final Preferences initial;

  /// Called with the whole new set after every edit.
  final Future<void> Function(Preferences preferences) onChanged;

  /// False when the app was started without a metadata service.
  final bool showMetadata;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Preferences _prefs = widget.initial;

  void _update(Preferences next) {
    setState(() => _prefs = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  'Changes save straight away and apply from the next video '
                  'you open.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const _Header('Study'),
              ListTile(
                title: const Text('Starting mode'),
                subtitle: Text(_prefs.subtitleMode.description),
                isThreeLine: true,
                trailing: DropdownButton<SubtitleMode>(
                  key: const Key('subtitleMode'),
                  value: _prefs.subtitleMode,
                  onChanged: (mode) {
                    if (mode != null) {
                      _update(_prefs.copyWith(subtitleMode: mode));
                    }
                  },
                  items: [
                    for (final mode in SubtitleMode.values)
                      DropdownMenuItem(
                        value: mode,
                        child: Text(mode.displayName),
                      ),
                  ],
                ),
              ),
              SwitchListTile(
                title: const Text('Resume where I left off'),
                value: _prefs.resumePlayback,
                onChanged: (v) => _update(_prefs.copyWith(resumePlayback: v)),
              ),
              SwitchListTile(
                title: const Text('Show keyboard help when a video opens'),
                value: _prefs.showHelp,
                onChanged: (v) => _update(_prefs.copyWith(showHelp: v)),
              ),
              _SliderTile(
                label: 'Playback speed',
                value: _prefs.playbackSpeed,
                min: 0.5,
                max: 2,
                divisions: 30,
                format: (v) => '${_trim(v)}×',
                onChanged: (v) => _update(_prefs.copyWith(playbackSpeed: v)),
              ),
              const _Header('Subtitles'),
              _SliderTile(
                label: 'Text size',
                value: _prefs.subtitleFontScale,
                min: 0.6,
                max: 2,
                divisions: 28,
                format: (v) => '${(v * 100).round()}%',
                onChanged: (v) =>
                    _update(_prefs.copyWith(subtitleFontScale: v)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  alignment: Alignment.center,
                  color: Colors.black,
                  child: Text(
                    'The quick brown fox',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22 * _prefs.subtitleFontScale,
                    ),
                  ),
                ),
              ),
              SwitchListTile(
                title: const Text('Leave out forced-subtitle tracks'),
                subtitle: const Text(
                    'They only cover signs and foreign dialogue, so they make '
                    'poor study tracks.'),
                value: _prefs.hideForcedTracks,
                onChanged: (v) => _update(_prefs.copyWith(hideForcedTracks: v)),
              ),
              _LanguageList(
                title: 'Language priority',
                description: 'Tracks in these languages come first, in this '
                    'order. The first one sets the timing for the study modes.',
                codes: _prefs.subtitleOrder,
                reorderable: true,
                onChanged: (codes) =>
                    _update(_prefs.copyWith(subtitleOrder: codes)),
              ),
              _LanguageList(
                title: 'Hidden languages',
                description: 'Tracks in these languages are never shown.',
                codes: _prefs.subtitleIgnores,
                onChanged: (codes) =>
                    _update(_prefs.copyWith(subtitleIgnores: codes)),
              ),
              const _Header('Japanese'),
              SwitchListTile(
                title: const Text('Show furigana'),
                value: _prefs.showRuby,
                onChanged: (v) => _update(_prefs.copyWith(showRuby: v)),
              ),
              ListTile(
                title: const Text('Furigana in'),
                enabled: _prefs.showRuby,
                trailing: SegmentedButton<RubyStyle>(
                  segments: const [
                    ButtonSegment(
                        value: RubyStyle.hiragana, label: Text('ひらがな')),
                    ButtonSegment(
                        value: RubyStyle.katakana, label: Text('カタカナ')),
                  ],
                  selected: {_prefs.rubyStyle},
                  onSelectionChanged: _prefs.showRuby
                      ? (s) => _update(_prefs.copyWith(rubyStyle: s.first))
                      : null,
                ),
              ),
              const _Header('Services'),
              ListTile(
                leading: const Icon(Icons.translate),
                title: const Text('Vocab server'),
                subtitle: Text(_prefs.vocab.isConfigured
                    ? '${_prefs.vocab.language} at ${_prefs.vocab.serverUrl}'
                    : 'Not set up'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final settings =
                      await showVocabSettingsDialog(context, _prefs.vocab);
                  if (settings != null) {
                    _update(_prefs.copyWith(vocab: settings));
                  }
                },
              ),
              if (widget.showMetadata)
                ListTile(
                  leading: const Icon(Icons.image_search),
                  title: const Text('Metadata'),
                  subtitle: Text(_prefs.metadata.enabled
                      ? 'Artwork and episode titles are looked up online'
                      : 'Off'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final settings = await showMetadataSettingsDialog(
                        context, _prefs.metadata);
                    if (settings != null) {
                      _update(_prefs.copyWith(metadata: settings));
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `1.0` → `1`, `1.25` → `1.25`.
String _trim(double v) {
  final s = v.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(min, max).toDouble();
    return ListTile(
      title: Text(label),
      subtitle: Slider(
        value: clamped,
        min: min,
        max: max,
        divisions: divisions,
        label: format(clamped),
        // Rounded so 30 steps of 0.05 don't store 1.0000000000000002.
        onChanged: (v) => onChanged((v * 100).round() / 100),
      ),
      trailing: SizedBox(
        width: 48,
        child: Text(format(clamped), textAlign: TextAlign.end),
      ),
    );
  }
}

/// A list of ISO 639-3 codes, shown by name, with add, remove and optionally
/// drag-to-reorder.
class _LanguageList extends StatelessWidget {
  const _LanguageList({
    required this.title,
    required this.description,
    required this.codes,
    required this.onChanged,
    this.reorderable = false,
  });

  final String title;
  final String description;
  final List<String> codes;
  final ValueChanged<List<String>> onChanged;
  final bool reorderable;

  static String nameOf(String code) => languageName(code) ?? code;

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final (i, code) in codes.indexed)
        ListTile(
          key: ValueKey(code),
          dense: true,
          leading: reorderable
              ? ReorderableDragStartListener(
                  index: i,
                  child: const Icon(Icons.drag_handle),
                )
              : null,
          title: Text('${nameOf(code)}  ·  $code'),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Remove ${nameOf(code)}',
            onPressed: () => onChanged([...codes]..removeAt(i)),
          ),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(title),
          subtitle: Text(description),
        ),
        if (reorderable)
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) {
              final next = [...codes];
              next.insert(to, next.removeAt(from));
              onChanged(next);
            },
            children: rows,
          )
        else
          ...rows,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: _LanguagePicker(
            label: 'Add a language to “$title”',
            exclude: codes.toSet(),
            onPicked: (code) => onChanged([...codes, code]),
          ),
        ),
      ],
    );
  }
}

class _LanguagePicker extends StatefulWidget {
  const _LanguagePicker({
    required this.label,
    required this.exclude,
    required this.onPicked,
  });

  final String label;
  final Set<String> exclude;
  final ValueChanged<String> onPicked;

  @override
  State<_LanguagePicker> createState() => _LanguagePickerState();
}

class _LanguagePickerState extends State<_LanguagePicker> {
  TextEditingController? _field;

  @override
  Widget build(BuildContext context) => Autocomplete<LanguageEntry>(
        displayStringForOption: (e) => '${e.name} (${e.iso6393})',
        optionsBuilder: (value) {
          final query = value.text.trim().toLowerCase();
          if (query.isEmpty) return const [];
          return languageTable
              .where((e) => !widget.exclude.contains(e.iso6393))
              .where((e) =>
                  e.iso6393 == query ||
                  e.iso6391 == query ||
                  e.name.toLowerCase().contains(query))
              .take(8);
        },
        onSelected: (e) {
          widget.onPicked(e.iso6393);
          // Autocomplete writes the chosen option into the field after this
          // returns, so clear it on the next frame.
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _field?.clear());
        },
        fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
          _field = controller;
          return TextField(
            controller: controller,
            focusNode: focusNode,
            onSubmitted: (_) => onSubmitted(),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.add, size: 18),
              hintText: widget.label,
              border: const OutlineInputBorder(),
            ),
          );
        },
      );
}

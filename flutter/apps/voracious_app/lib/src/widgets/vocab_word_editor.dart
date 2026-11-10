/// The card that opens over a clicked subtitle word: its status, translation
/// and parent form, all saved to the vocab server.
///
/// A status button saves straight away, as clicking a status does in Lute:
/// most of the time that is the whole edit. The text fields wait for Save (or
/// Enter). Keys I, 1–5 and K set the status too, unless a field has focus.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voracious_core/voracious_core.dart';

import 'vocab_line_view.dart';

/// Saves an edit; supplied by the player, which adds the line and video.
typedef VocabSaver = Future<VocabSaveResult> Function(VocabEdit edit);

/// Opens the editor next to [wordRect] (global coordinates).
Future<void> showVocabWordEditor({
  required BuildContext context,
  required VocabToken token,
  required Rect wordRect,
  required VocabSettings settings,
  required VocabSaver save,
}) =>
    showDialog<void>(
      context: context,
      barrierColor: Colors.black26,
      builder: (dialogContext) {
        final screen = MediaQuery.sizeOf(dialogContext);
        const width = 340.0;
        final left = (wordRect.center.dx - width / 2)
            .clamp(12.0, screen.width - width - 12);
        // Above the word: subtitles sit at the bottom of the picture.
        final bottom = (screen.height - wordRect.top + 10)
            .clamp(12.0, screen.height - 120);
        return Stack(
          children: [
            Positioned(
              left: left,
              bottom: bottom,
              width: width,
              child: _VocabWordEditor(
                token: token,
                settings: settings,
                save: save,
              ),
            ),
          ],
        );
      },
    );

class _VocabWordEditor extends StatefulWidget {
  const _VocabWordEditor({
    required this.token,
    required this.settings,
    required this.save,
  });

  final VocabToken token;
  final VocabSettings settings;
  final VocabSaver save;

  @override
  State<_VocabWordEditor> createState() => _VocabWordEditorState();
}

class _VocabWordEditorState extends State<_VocabWordEditor> {
  late VocabWord? _word = widget.token.word;
  late final _translation =
      TextEditingController(text: _word?.translation ?? '');
  late final _parent = TextEditingController(text: _word?.parent?.term ?? '');
  final _focus = FocusNode();

  bool _saving = false;
  String? _message;

  /// New words are saved in lower case: a word that starts a sentence is
  /// still the same word.
  String get _term => _word?.term ?? widget.token.text.toLowerCase();

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _translation.dispose();
    _parent.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _textChanged =>
      _translation.text.trim() != (_word?.translation ?? '') ||
      _parent.text.trim() != (_word?.parent?.term ?? '');

  Future<void> _submit({VocabStatus? status}) async {
    if (_saving) return;
    final word = _word;
    final translation = _translation.text.trim();
    final parent = _parent.text.trim();
    if (status == null && !_textChanged) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final result = await widget.save(VocabEdit(
        language: widget.settings.language,
        term: _term,
        status: status,
        translation:
            translation != (word?.translation ?? '') ? translation : null,
        parent: parent != (word?.parent?.term ?? '') ? parent : null,
        expectModifiedMs: word?.modifiedMs,
        deck: widget.settings.deck,
      ));
      if (!mounted) return;
      switch (result.outcome) {
        case VocabOutcome.created ||
              VocabOutcome.updated ||
              VocabOutcome.unchanged:
          Navigator.of(context).pop();
        case VocabOutcome.conflict:
          // Changed in the vocab app or Lute since this line was looked up:
          // show what it is now and let the user decide again.
          setState(() {
            _word = result.word;
            _translation.text = result.word?.translation ?? '';
            _parent.text = result.word?.parent?.term ?? '';
            _message = 'This word was changed elsewhere. Here it is now; '
                'save again to apply your change.';
          });
        case VocabOutcome.error:
          setState(() => _message = result.error ?? 'Could not save.');
      }
    } on VocabException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // Keys typed into a field are for the field.
    final focused = FocusManager.instance.primaryFocus?.context?.widget;
    if (focused is EditableText) return KeyEventResult.ignored;
    final status = switch (event.logicalKey) {
      LogicalKeyboardKey.keyI => VocabStatus.ignored,
      LogicalKeyboardKey.digit1 => VocabStatus.s1,
      LogicalKeyboardKey.digit2 => VocabStatus.s2,
      LogicalKeyboardKey.digit3 => VocabStatus.s3,
      LogicalKeyboardKey.digit4 => VocabStatus.s4,
      LogicalKeyboardKey.digit5 => VocabStatus.s5,
      LogicalKeyboardKey.keyK => VocabStatus.known,
      _ => null,
    };
    if (status == null) return KeyEventResult.ignored;
    _submit(status: status);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final word = _word;
    final parent = word?.parent;
    final senses = word?.senses ?? const <VocabSense>[];

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(_term, style: theme.textTheme.titleLarge),
                  ),
                  if (word == null)
                    Text('New word',
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: theme.colorScheme.primary)),
                ],
              ),
              if (parent != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '→ ${parent.term}'
                    '${parent.translation.isEmpty ? '' : ' · ${parent.translation}'}'
                    '${parent.status == null ? '' : ' · ${parent.status!.label}'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (senses.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    [
                      for (final s in senses)
                        '${s.cue}: ${s.translation.isEmpty ? '—' : s.translation}',
                    ].join('\n'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 12),
              _StatusRow(
                current: word?.status,
                enabled: !_saving,
                onPick: (status) => _submit(status: status),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _translation,
                decoration: InputDecoration(
                  labelText: senses.length > 1
                      ? 'Translation (for Lute; senses are edited in vocab)'
                      : 'Translation',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _parent,
                decoration: const InputDecoration(
                  labelText: 'Parent form (e.g. the infinitive)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_message!,
                      style: TextStyle(color: theme.colorScheme.error)),
                ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_saving)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: _saving ? null : () => _submit(),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.current,
    required this.enabled,
    required this.onPick,
  });

  final VocabStatus? current;
  final bool enabled;
  final void Function(VocabStatus status) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        for (final status in VocabStatus.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: _StatusButton(
                status: status,
                selected: status == current,
                enabled: enabled,
                onPressed: () => onPick(status),
                outline: theme.colorScheme.onSurface,
              ),
            ),
          ),
      ],
    );
  }
}

class _StatusButton extends StatelessWidget {
  const _StatusButton({
    required this.status,
    required this.selected,
    required this.enabled,
    required this.onPressed,
    required this.outline,
  });

  final VocabStatus status;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;
  final Color outline;

  @override
  Widget build(BuildContext context) {
    final fill = vocabStatusColor(status, inCollection: true);
    return Tooltip(
      message: switch (status) {
        VocabStatus.ignored => 'Ignore (I)',
        VocabStatus.known => 'Known (K)',
        _ => 'Status ${status.label}',
      },
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: enabled ? onPressed : null,
        child: Container(
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? outline : outline.withValues(alpha: 0.25),
              width: selected ? 2 : 1,
            ),
          ),
          child: Text(
            status.label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: fill == null ? outline : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }
}

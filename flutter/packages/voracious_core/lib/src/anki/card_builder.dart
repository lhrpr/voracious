/// Builds Anki notes out of a subtitle line.
///
/// Which Voracious value goes into which Anki field is entirely up to the
/// user's note type, so the mapping is data and the building is a pure
/// function over it. Media is handled separately, because it has to be
/// uploaded before the note that references it can be added.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../cues/cue_index.dart';
import '../text/annotated_text.dart';
import '../util/uid.dart';
import 'anki_connect.dart';

/// The values Voracious can put in an Anki field.
enum AnkiFieldSource {
  /// Leave the field alone.
  none('nofill', 'Leave empty'),

  /// The subtitle line as written.
  text('text', 'Sentence'),

  /// The line with readings in bracket notation: ` 食[た]べる`. This is what
  /// Anki's Japanese Support add-on renders as furigana.
  textWithReadings('text_readings', 'Sentence with readings'),

  /// Whatever the user selected before exporting, usually the word they were
  /// looking up.
  selectedText('selected_text', 'Selected word'),

  /// The corresponding line from the next subtitle track — the translation, in
  /// the usual two-track setup.
  translation('translation', 'Translation'),

  /// Dictionary definitions for the selected word.
  definition('definition', 'Definition'),

  /// Audio of the line.
  audio('audio', 'Audio clip'),

  /// A frame from the video.
  image('image', 'Screenshot'),

  /// The title the line came from.
  sourceTitle('source_title', 'Source title'),

  /// Position in the video, as `HH:MM:SS`.
  timestamp('timestamp', 'Timestamp');

  const AnkiFieldSource(this.wireName, this.displayName);

  /// Stable name in stored preferences; matches the Electron app's values.
  final String wireName;
  final String displayName;

  /// True for sources that need a file uploaded before the note is added.
  bool get isMedia =>
      this == AnkiFieldSource.audio || this == AnkiFieldSource.image;

  static AnkiFieldSource byWireName(String name) {
    for (final source in AnkiFieldSource.values) {
      if (source.wireName == name) return source;
    }
    return AnkiFieldSource.none;
  }
}

/// Everything an export knows about the line being exported.
@immutable
class CardContext {
  const CardContext({
    required this.cue,
    this.translationCue,
    this.selectedText,
    this.definitions = const [],
    this.sourceTitle,
    this.position,
  });

  final StudyCue cue;

  /// The same moment on the translation track, when there is one.
  final StudyCue? translationCue;

  final String? selectedText;

  /// Definitions of [selectedText], already formatted for display.
  final List<String> definitions;

  final String? sourceTitle;

  /// Playback position when the export was triggered, which is where the
  /// screenshot comes from.
  final Duration? position;
}

/// A field that needs a media upload before the note can be added.
@immutable
class PendingMediaField {
  const PendingMediaField({
    required this.fieldName,
    required this.source,
    required this.suggestedFileName,
  });

  final String fieldName;
  final AnkiFieldSource source;

  /// A collision-resistant name. Anki may still rename it, and the name it
  /// returns is the one the field must reference.
  final String suggestedFileName;
}

/// The result of building a note: the text fields, plus the media still to be
/// uploaded.
@immutable
class BuiltCard {
  const BuiltCard({
    required this.fields,
    required this.pendingMedia,
    required this.deckName,
    required this.modelName,
    this.tags = const [],
  });

  final Map<String, String> fields;
  final List<PendingMediaField> pendingMedia;
  final String deckName;
  final String modelName;
  final List<String> tags;

  bool get needsMedia => pendingMedia.isNotEmpty;

  /// The note as it stands, with media fields still empty.
  AnkiNote toNote() => AnkiNote(
        deckName: deckName,
        modelName: modelName,
        fields: fields,
        tags: tags,
      );

  /// A copy with [fieldName] set to markup referencing [storedFileName].
  BuiltCard withMedia(
    String fieldName,
    AnkiFieldSource source,
    String storedFileName,
  ) =>
      BuiltCard(
        fields: {
          ...fields,
          fieldName: switch (source) {
            AnkiFieldSource.audio => '[sound:$storedFileName]',
            AnkiFieldSource.image => '<img src="$storedFileName">',
            _ => fields[fieldName] ?? '',
          },
        },
        pendingMedia:
            pendingMedia.where((m) => m.fieldName != fieldName).toList(),
        deckName: deckName,
        modelName: modelName,
        tags: tags,
      );
}

/// User configuration for Anki export.
@immutable
class AnkiExportSettings {
  const AnkiExportSettings({
    this.deckName,
    this.modelName,
    this.fieldMap = const {},
    this.tags = const ['voracious'],
    this.audioPadding = const Duration(milliseconds: 250),
  });

  final String? deckName;
  final String? modelName;

  /// Anki field name to the value that fills it.
  final Map<String, AnkiFieldSource> fieldMap;

  final List<String> tags;

  /// Extra time either side of the line when extracting audio. Clipping
  /// exactly on the subtitle timing cuts the first and last mora.
  final Duration audioPadding;

  bool get isConfigured =>
      deckName != null && modelName != null && fieldMap.isNotEmpty;

  /// True when any field wants audio, which is what decides whether an
  /// extraction has to run at all.
  bool get needsAudio => fieldMap.containsValue(AnkiFieldSource.audio);

  bool get needsImage => fieldMap.containsValue(AnkiFieldSource.image);

  Map<String, Object?> toJson() => {
        'deckName': deckName,
        'modelName': modelName,
        'fieldMap': {
          for (final entry in fieldMap.entries) entry.key: entry.value.wireName,
        },
        'tags': tags,
        'audioPaddingMs': audioPadding.inMilliseconds,
      };

  /// Reads settings, ignoring anything of the wrong type. See the note on the
  /// readers in `preferences.dart`: a damaged value should cost that setting
  /// and nothing more.
  static AnkiExportSettings fromJson(Map<String, Object?> json) {
    final rawMap = json['fieldMap'] is Map
        ? (json['fieldMap']! as Map).cast<Object?, Object?>()
        : const <Object?, Object?>{};
    final tags = json['tags'];
    return AnkiExportSettings(
      deckName: json['deckName'] is String ? json['deckName']! as String : null,
      modelName:
          json['modelName'] is String ? json['modelName']! as String : null,
      fieldMap: {
        for (final entry in rawMap.entries)
          if (entry.key is String && entry.value is String)
            entry.key! as String:
                AnkiFieldSource.byWireName(entry.value! as String),
      },
      tags: tags is List
          ? tags.whereType<String>().toList()
          : const ['voracious'],
      audioPadding: Duration(
        milliseconds: json['audioPaddingMs'] is num
            ? (json['audioPaddingMs']! as num).toInt()
            : 250,
      ),
    );
  }
}

/// Builds a note from [context] according to [settings].
///
/// Throws [StateError] when the deck or note type has not been chosen yet.
BuiltCard buildCard(CardContext context, AnkiExportSettings settings) {
  final deckName = settings.deckName;
  final modelName = settings.modelName;
  if (deckName == null || modelName == null) {
    throw StateError('Anki deck and note type must be configured first');
  }

  final fields = <String, String>{};
  final pending = <PendingMediaField>[];

  settings.fieldMap.forEach((fieldName, source) {
    switch (source) {
      case AnkiFieldSource.none:
        fields[fieldName] = '';

      case AnkiFieldSource.text:
        fields[fieldName] = context.cue.text.text;

      case AnkiFieldSource.textWithReadings:
        fields[fieldName] = renderWithFuriganaBrackets(context.cue.text);

      case AnkiFieldSource.selectedText:
        fields[fieldName] = context.selectedText ?? '';

      case AnkiFieldSource.translation:
        fields[fieldName] = context.translationCue?.text.text ?? '';

      case AnkiFieldSource.definition:
        fields[fieldName] = context.definitions.join('<br>');

      case AnkiFieldSource.sourceTitle:
        fields[fieldName] = context.sourceTitle ?? '';

      case AnkiFieldSource.timestamp:
        fields[fieldName] =
            formatTimestamp(context.position ?? context.cue.begin);

      case AnkiFieldSource.audio:
        fields[fieldName] = '';
        pending.add(PendingMediaField(
          fieldName: fieldName,
          source: source,
          suggestedFileName: 'voracious_${generateUid()}.mp3',
        ));

      case AnkiFieldSource.image:
        fields[fieldName] = '';
        pending.add(PendingMediaField(
          fieldName: fieldName,
          source: source,
          suggestedFileName: 'voracious_${generateUid()}.jpg',
        ));
    }
  });

  return BuiltCard(
    fields: fields,
    pendingMedia: pending,
    deckName: deckName,
    modelName: modelName,
    tags: settings.tags,
  );
}

/// The audio range to extract for [cue], padded per [settings].
(Duration, Duration) audioRangeFor(StudyCue cue, AnkiExportSettings settings) {
  final begin = cue.begin - settings.audioPadding;
  return (
    begin.isNegative ? Duration.zero : begin,
    cue.end + settings.audioPadding,
  );
}

/// Renders annotated text in Anki's furigana bracket notation.
///
/// `食べる` with ruby `た` over `食` becomes ` 食[た]べる`. The leading space is
/// required: the Japanese Support add-on uses whitespace to find where the
/// bracketed reading's word begins.
String renderWithFuriganaBrackets(AnnotatedText text) => text
    .renderToString(
      wrap: (annotation, inner) => switch (annotation) {
        RubyAnnotation(:final text) => [' ', ...inner, '[', text, ']'],
        _ => inner,
      },
    )
    .trim();

/// Formats a position as `HH:MM:SS`.
String formatTimestamp(Duration position) {
  final hours = position.inHours;
  final minutes = (position.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (position.inSeconds % 60).toString().padLeft(2, '0');
  return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
}

/// Uploads pending media and adds the note.
///
/// [mediaProvider] is asked for the bytes of each pending field; returning
/// null skips that field, which is what happens when audio extraction is
/// unavailable on the platform.
Future<int> exportCard(
  BuiltCard card,
  AnkiConnectClient client, {
  required Future<Uint8List?> Function(PendingMediaField field) mediaProvider,
}) async {
  var current = card;

  for (final field in card.pendingMedia) {
    final bytes = await mediaProvider(field);
    if (bytes == null) continue;
    final storedName =
        await client.storeMediaFile(field.suggestedFileName, bytes);
    current = current.withMedia(field.fieldName, field.source, storedName);
  }

  return client.addNote(current.toNote());
}

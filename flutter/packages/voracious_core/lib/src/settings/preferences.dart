/// User preferences.
library;

import 'package:meta/meta.dart';

import '../anki/card_builder.dart';
import '../japanese/furigana.dart';
import '../study/subtitle_mode.dart';

/// Everything the user can configure.
///
/// The JSON shape deliberately matches the Electron app's stored profile
/// wherever the setting still exists, so an existing profile can be imported
/// rather than reset.
@immutable
class Preferences {
  const Preferences({
    this.showRuby = true,
    this.showHelp = true,
    this.subtitleMode = SubtitleMode.manual,
    this.subtitleOrder = const [],
    this.subtitleIgnores = const [],
    this.disabledDictionaries = const {},
    this.dictionaryOrder = const [],
    this.anki = const AnkiExportSettings(),
    this.playbackSpeed = 1,
    this.rubyStyle = RubyStyle.hiragana,
    this.hideForcedTracks = true,
    this.subtitleFontScale = 1,
    this.resumePlayback = true,
  });

  /// Show furigana over kanji.
  final bool showRuby;

  /// Show the keyboard help overlay in the player.
  final bool showHelp;

  final SubtitleMode subtitleMode;

  /// ISO 639-3 codes, most important first. Decides which track the study
  /// modes treat as the one being learned.
  final List<String> subtitleOrder;

  /// Languages never to display.
  final List<String> subtitleIgnores;

  final Set<String> disabledDictionaries;

  /// Dictionary display order, by name.
  final List<String> dictionaryOrder;

  final AnkiExportSettings anki;

  final double playbackSpeed;

  final RubyStyle rubyStyle;

  /// Keep forced-subtitle tracks out of the study track list. They cover only
  /// foreign dialogue and signs, so they are misleading as a study track.
  final bool hideForcedTracks;

  final double subtitleFontScale;

  /// Resume each video where it was left off.
  final bool resumePlayback;

  Preferences copyWith({
    bool? showRuby,
    bool? showHelp,
    SubtitleMode? subtitleMode,
    List<String>? subtitleOrder,
    List<String>? subtitleIgnores,
    Set<String>? disabledDictionaries,
    List<String>? dictionaryOrder,
    AnkiExportSettings? anki,
    double? playbackSpeed,
    RubyStyle? rubyStyle,
    bool? hideForcedTracks,
    double? subtitleFontScale,
    bool? resumePlayback,
  }) =>
      Preferences(
        showRuby: showRuby ?? this.showRuby,
        showHelp: showHelp ?? this.showHelp,
        subtitleMode: subtitleMode ?? this.subtitleMode,
        subtitleOrder: subtitleOrder ?? this.subtitleOrder,
        subtitleIgnores: subtitleIgnores ?? this.subtitleIgnores,
        disabledDictionaries: disabledDictionaries ?? this.disabledDictionaries,
        dictionaryOrder: dictionaryOrder ?? this.dictionaryOrder,
        anki: anki ?? this.anki,
        playbackSpeed: playbackSpeed ?? this.playbackSpeed,
        rubyStyle: rubyStyle ?? this.rubyStyle,
        hideForcedTracks: hideForcedTracks ?? this.hideForcedTracks,
        subtitleFontScale: subtitleFontScale ?? this.subtitleFontScale,
        resumePlayback: resumePlayback ?? this.resumePlayback,
      );

  Map<String, Object?> toJson() => {
        'showRuby': showRuby,
        'showHelp': showHelp,
        'subtitleMode': subtitleMode.wireName,
        'subtitleOrder': subtitleOrder,
        'subtitleIgnores': subtitleIgnores,
        'disabledDictionaries': disabledDictionaries.toList(),
        'dictionaryOrder': dictionaryOrder,
        'anki': anki.toJson(),
        'playbackSpeed': playbackSpeed,
        'rubyStyle': rubyStyle.name,
        'hideForcedTracks': hideForcedTracks,
        'subtitleFontScale': subtitleFontScale,
        'resumePlayback': resumePlayback,
      };

  /// Reads preferences, falling back to the default for anything missing or
  /// malformed.
  ///
  /// A preferences file that has picked up damage should cost the user that
  /// setting, not their whole profile.
  static Preferences fromJson(Map<String, Object?> json) {
    const defaults = Preferences();
    return Preferences(
      showRuby: readBool(json['showRuby'], defaults.showRuby),
      showHelp: readBool(json['showHelp'], defaults.showHelp),
      subtitleMode: SubtitleMode.byWireName(
        readString(json['subtitleMode']) ?? '',
        fallback: defaults.subtitleMode,
      ),
      subtitleOrder: readStringList(json['subtitleOrder']),
      subtitleIgnores: readStringList(json['subtitleIgnores']),
      disabledDictionaries:
          readStringList(json['disabledDictionaries']).toSet(),
      dictionaryOrder: readStringList(json['dictionaryOrder']),
      anki: json['anki'] is Map
          ? AnkiExportSettings.fromJson(
              (json['anki']! as Map).cast<String, Object?>())
          : defaults.anki,
      playbackSpeed: readDouble(json['playbackSpeed'], defaults.playbackSpeed),
      rubyStyle: RubyStyle.values.firstWhere(
        (style) => style.name == json['rubyStyle'],
        orElse: () => defaults.rubyStyle,
      ),
      hideForcedTracks:
          readBool(json['hideForcedTracks'], defaults.hideForcedTracks),
      subtitleFontScale:
          readDouble(json['subtitleFontScale'], defaults.subtitleFontScale),
      resumePlayback: readBool(json['resumePlayback'], defaults.resumePlayback),
    );
  }
}

/// Type-checked readers for stored JSON.
///
/// Casting would be shorter, but a stored value of the wrong type — from an
/// older version, a hand-edited file, or a half-written save — would then throw
/// and cost the user every other setting alongside the broken one.
bool readBool(Object? value, bool fallback) => value is bool ? value : fallback;

double readDouble(Object? value, double fallback) =>
    value is num ? value.toDouble() : fallback;

String? readString(Object? value) => value is String ? value : null;

List<String> readStringList(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];

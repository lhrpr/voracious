/// Character sets subtitle files turn up in.
library;

/// A character encoding a subtitle file may be stored in.
///
/// The list is deliberately short: it covers the encodings that actually appear
/// in subtitle releases for the languages Voracious targets, plus the two
/// Unicode forms. Anything else decodes as Windows-1252 and looks wrong, which
/// is a visible failure the user can act on rather than a silent corruption.
enum Charset {
  utf8('UTF-8', isUnicode: true),
  utf16le('UTF-16LE', isUnicode: true),
  utf16be('UTF-16BE', isUnicode: true),

  /// Japanese, by far the most common legacy encoding for the subtitles this
  /// app exists to study.
  shiftJis('Shift_JIS', aliases: ['shift-jis', 'sjis', 'cp932', 'windows-31j']),
  eucJp('EUC-JP', aliases: ['eucjp']),

  /// Simplified Chinese.
  gb18030('GB18030', aliases: ['gbk', 'gb2312', 'cp936']),

  /// Traditional Chinese.
  big5('Big5', aliases: ['big-5', 'cp950']),

  /// Korean.
  eucKr('EUC-KR', aliases: ['euckr', 'cp949', 'ks_c_5601-1987']),

  /// Cyrillic.
  windows1251('windows-1251', aliases: ['cp1251']),

  /// Western European; also the pragmatic fallback for undetectable bytes.
  windows1252('windows-1252', aliases: ['cp1252', 'ansi']),
  latin1('ISO-8859-1', aliases: ['iso8859-1', 'latin1']);

  const Charset(
    this.name, {
    this.aliases = const [],
    this.isUnicode = false,
  });

  /// Canonical IANA-ish name.
  final String name;

  /// Alternative spellings accepted by [byName].
  final List<String> aliases;

  final bool isUnicode;

  /// True when this encoding needs a byte table Voracious does not ship; see
  /// `TextDecoderRegistry`.
  bool get requiresPlatformCodec => switch (this) {
        Charset.shiftJis ||
        Charset.eucJp ||
        Charset.gb18030 ||
        Charset.big5 ||
        Charset.eucKr =>
          true,
        _ => false,
      };

  /// Looks up a charset by canonical name or alias, case-insensitively.
  static Charset? byName(String name) {
    final needle = name.trim().toLowerCase().replaceAll('_', '-');
    for (final charset in Charset.values) {
      if (charset.name.toLowerCase().replaceAll('_', '-') == needle) {
        return charset;
      }
      for (final alias in charset.aliases) {
        if (alias.toLowerCase().replaceAll('_', '-') == needle) return charset;
      }
    }
    return null;
  }
}

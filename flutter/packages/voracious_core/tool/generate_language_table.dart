/// Regenerates `lib/src/language/language_table.dart`.
///
/// Reads the trimmed ISO 639-3 registry that the Electron app already carries
/// (`src/util/languageTable.js` at the repository root) so that both apps agree
/// on language codes during the migration.
///
///     dart run tool/generate_language_table.dart [path/to/languageTable.js]
library;

import 'dart:convert';
import 'dart:io';

const String _defaultSource = '../../../src/util/languageTable.js';
const String _output = 'lib/src/language/language_table.dart';

void main(List<String> args) {
  final sourcePath = args.isNotEmpty ? args.first : _defaultSource;
  final source = File(sourcePath);
  if (!source.existsSync()) {
    stderr.writeln('source not found: ${source.path}');
    exitCode = 1;
    return;
  }

  final text = source.readAsStringSync();
  final start = text.indexOf('[');
  final end = text.lastIndexOf(']');
  if (start < 0 || end < start) {
    stderr.writeln('could not find the JSON array in ${source.path}');
    exitCode = 1;
    return;
  }

  final entries = (jsonDecode(text.substring(start, end + 1)) as List<Object?>)
      .cast<Map<String, Object?>>();

  final rows = entries.map((entry) {
    final name = (entry['name']! as String)
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'");
    return "  _entry('${entry['iso6393']}', '${entry['iso6391']}', '$name'),";
  }).join('\n');

  final existing = File(_output).readAsStringSync();
  final headerEnd = existing.indexOf('  _entry(');
  final footerStart = existing.indexOf(']);');
  if (headerEnd < 0 || footerStart < 0) {
    stderr.writeln('$_output does not have the expected generated shape');
    exitCode = 1;
    return;
  }

  File(_output).writeAsStringSync(
    '${existing.substring(0, headerEnd)}$rows\n${existing.substring(footerStart)}',
  );
  stdout.writeln('wrote ${entries.length} languages to $_output');
}

/// The third-party notices the app has to display and the source it has to
/// offer.
///
/// This is not decoration. Using an LGPL library in a proprietary application
/// carries three concrete obligations: state that the library is used and
/// under what licence, make the exact corresponding source available, and keep
/// the library replaceable — which dynamic linking handles. The first two are
/// content, so they live in code where they can be asserted on rather than in
/// a text file nobody updates.
library;

import 'package:meta/meta.dart';

/// How a dependency is linked, which is what decides the obligations.
enum LinkageKind {
  /// Loaded at runtime with `dlopen`/`LoadLibrary`. Required for LGPL
  /// components in a proprietary application.
  dynamicLibrary,

  /// Compiled into the application binary. Only permissible for permissively
  /// licensed code.
  staticLibrary,

  /// Dart or other source compiled into the app.
  source,

  /// Invoked as a separate process. No linking, so copyleft does not
  /// propagate.
  separateProcess,
}

/// One third-party component.
@immutable
class ThirdPartyNotice {
  const ThirdPartyNotice({
    required this.name,
    required this.license,
    required this.linkage,
    required this.homepage,
    this.version,
    this.sourceUrl,
    this.notes,
  });

  final String name;

  /// SPDX identifier where one exists.
  final String license;

  final LinkageKind linkage;

  final String homepage;

  /// Filled in at runtime for components that can report their own version.
  final String? version;

  /// Where the exact corresponding source is published. Required for any
  /// copyleft component; the obligation is not satisfied by linking to the
  /// upstream project, because what has to be offered is the source of the
  /// build actually shipped, including configure flags and patches.
  final String? sourceUrl;

  final String? notes;

  /// True when this component's licence requires publishing corresponding
  /// source.
  bool get requiresSourceOffer =>
      license.startsWith('LGPL') || license.startsWith('GPL');

  ThirdPartyNotice withVersion(String version) => ThirdPartyNotice(
        name: name,
        license: license,
        linkage: linkage,
        homepage: homepage,
        version: version,
        sourceUrl: sourceUrl,
        notes: notes,
      );

  @override
  String toString() => '$name${version != null ? ' $version' : ''} ($license)';
}

/// Where the corresponding source for the copyleft components is published.
///
/// Must be a stable URL that stays reachable for as long as the binaries are
/// distributed, and must carry the exact tree that was built, its configure
/// flags, and any patches applied.
const String correspondingSourceUrl =
    'https://github.com/lhrpr/voracious-thirdparty';

/// The components Voracious ships or links against.
///
/// Keep this list correct. Adding a native dependency without adding it here
/// is how a distribution obligation gets missed.
const List<ThirdPartyNotice> thirdPartyNotices = [
  ThirdPartyNotice(
    name: 'mpv (libmpv)',
    license: 'LGPL-2.1-or-later',
    linkage: LinkageKind.dynamicLibrary,
    homepage: 'https://mpv.io',
    sourceUrl: correspondingSourceUrl,
    notes: 'Built with --enable-lgpl. That build omits the X11 and legacy '
        'direct3d video outputs, OSS and JACK audio, vdpau, and DVD/CDDA/DVB '
        'input, none of which this application uses. Loaded dynamically at '
        'runtime and replaceable by the user.',
  ),
  ThirdPartyNotice(
    name: 'FFmpeg',
    license: 'LGPL-2.1-or-later',
    linkage: LinkageKind.dynamicLibrary,
    homepage: 'https://ffmpeg.org',
    sourceUrl: correspondingSourceUrl,
    notes: 'Built with --disable-gpl and --disable-nonfree, so no x264, x265 '
        'or libpostproc. Used for demuxing, parsing, audio decoding and '
        'subtitle parsing; video decoding goes to the platform hardware '
        'decoder.',
  ),
  ThirdPartyNotice(
    name: 'libass',
    license: 'ISC',
    linkage: LinkageKind.dynamicLibrary,
    homepage: 'https://github.com/libass/libass',
    notes: 'Permissively licensed; no copyleft obligation. Renders ASS/SSA '
        'subtitles that Voracious does not render itself.',
  ),
  ThirdPartyNotice(
    name: 'JMdict / EDICT',
    license: 'CC-BY-SA-4.0',
    linkage: LinkageKind.source,
    homepage: 'https://www.edrdg.org/jmdict/j_jmdict.html',
    notes: 'Japanese-English dictionary data, © Electronic Dictionary Research '
        'and Development Group. Attribution required wherever definitions are '
        'displayed.',
  ),
  ThirdPartyNotice(
    name: 'Flutter and the Dart SDK',
    license: 'BSD-3-Clause',
    linkage: LinkageKind.source,
    homepage: 'https://flutter.dev',
  ),
];

/// Notices whose licences require a published source offer.
List<ThirdPartyNotice> get noticesRequiringSource =>
    thirdPartyNotices.where((n) => n.requiresSourceOffer).toList();

/// Renders the notices as plain text for an about screen.
String renderNoticesAsText({Map<String, String> versions = const {}}) {
  final buffer = StringBuffer()
    ..writeln('Third-party components')
    ..writeln();

  for (final notice in thirdPartyNotices) {
    final version = versions[notice.name] ?? notice.version;
    buffer
      ..writeln('${notice.name}${version != null ? ' $version' : ''}')
      ..writeln('  Licence: ${notice.license}')
      ..writeln('  Linkage: ${_describeLinkage(notice.linkage)}')
      ..writeln('  Home:    ${notice.homepage}');
    if (notice.sourceUrl != null) {
      buffer.writeln('  Source:  ${notice.sourceUrl}');
    }
    if (notice.notes != null) {
      buffer.writeln('  ${notice.notes}');
    }
    buffer.writeln();
  }

  buffer
    ..writeln('The LGPL-licensed libraries above are linked dynamically and '
        'may be replaced by the user with a compatible build.')
    ..writeln('Corresponding source, including configure flags and any '
        'patches: $correspondingSourceUrl');

  return buffer.toString();
}

String _describeLinkage(LinkageKind kind) => switch (kind) {
      LinkageKind.dynamicLibrary => 'dynamically linked',
      LinkageKind.staticLibrary => 'statically linked',
      LinkageKind.source => 'source included',
      LinkageKind.separateProcess => 'separate process',
    };

/// An immutable string carrying ranged annotations over its code points.
///
/// This is the representation every subtitle line is turned into before it
/// reaches the UI. Three kinds of annotation exist, and they must nest — an
/// annotation is either disjoint from another or fully contained in it — so the
/// whole thing can be rendered as a tree without splitting any span.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'code_points.dart';

/// The kinds of annotation an [AnnotatedText] can carry, in nesting priority
/// order: when two annotations cover exactly the same range, the one declared
/// first here becomes the outer one.
enum AnnotationKind {
  /// Furigana / pronunciation guide rendered above the range.
  ruby('ruby'),

  /// A user highlight, belonging to a named set.
  highlight('highlight'),

  /// A word identified by a tokenizer, optionally with its dictionary form.
  word('word');

  const AnnotationKind(this.wireName);

  /// Stable name used in persisted JSON. Do not change these.
  final String wireName;

  static AnnotationKind byWireName(String name) {
    for (final kind in AnnotationKind.values) {
      if (kind.wireName == name) return kind;
    }
    throw ArgumentError.value(name, 'name', 'unknown annotation kind');
  }

  /// Lower sorts outermost.
  int get priority => index;
}

/// A single annotation over the half-open code point range
/// `[cpBegin, cpEnd)` of an [AnnotatedText].
@immutable
sealed class Annotation {
  const Annotation({required this.cpBegin, required this.cpEnd});

  /// First annotated code point offset, inclusive.
  final int cpBegin;

  /// Last annotated code point offset, exclusive.
  final int cpEnd;

  AnnotationKind get kind;

  /// Returns a copy of this annotation shifted by [offset] code points.
  Annotation shifted(int offset);

  Map<String, Object?> toJson();

  static Annotation fromJson(Map<String, Object?> json) {
    final cpBegin = (json['cpBegin']! as num).toInt();
    final cpEnd = (json['cpEnd']! as num).toInt();
    switch (AnnotationKind.byWireName(json['kind']! as String)) {
      case AnnotationKind.ruby:
        return RubyAnnotation(
          cpBegin: cpBegin,
          cpEnd: cpEnd,
          text: json['text']! as String,
        );
      case AnnotationKind.highlight:
        return HighlightAnnotation(
          cpBegin: cpBegin,
          cpEnd: cpEnd,
          setId: json['setId']! as String,
          createdAtMillis: (json['createdAtMillis'] as num?)?.toInt() ?? 0,
        );
      case AnnotationKind.word:
        return WordAnnotation(
          cpBegin: cpBegin,
          cpEnd: cpEnd,
          lemma: json['lemma'] as String?,
        );
    }
  }

  bool overlaps(int begin, int end) => end > cpBegin && begin < cpEnd;

  bool covers(int cpIndex) => cpIndex >= cpBegin && cpIndex < cpEnd;

  /// True when [other] fits entirely inside this annotation's range.
  bool contains(Annotation other) =>
      other.cpBegin >= cpBegin && other.cpEnd <= cpEnd;
}

/// Ruby text (furigana) shown above the annotated range.
final class RubyAnnotation extends Annotation {
  const RubyAnnotation({
    required super.cpBegin,
    required super.cpEnd,
    required this.text,
  });

  final String text;

  @override
  AnnotationKind get kind => AnnotationKind.ruby;

  @override
  RubyAnnotation shifted(int offset) => RubyAnnotation(
        cpBegin: cpBegin + offset,
        cpEnd: cpEnd + offset,
        text: text,
      );

  @override
  Map<String, Object?> toJson() => {
        'kind': kind.wireName,
        'cpBegin': cpBegin,
        'cpEnd': cpEnd,
        'text': text,
      };

  @override
  bool operator ==(Object other) =>
      other is RubyAnnotation &&
      other.cpBegin == cpBegin &&
      other.cpEnd == cpEnd &&
      other.text == text;

  @override
  int get hashCode => Object.hash(kind, cpBegin, cpEnd, text);

  @override
  String toString() => 'RubyAnnotation($cpBegin, $cpEnd, "$text")';
}

/// A user highlight. Highlights belong to a [setId] so that several independent
/// highlight layers (say, "known words" and "to study") can coexist.
final class HighlightAnnotation extends Annotation {
  const HighlightAnnotation({
    required super.cpBegin,
    required super.cpEnd,
    required this.setId,
    required this.createdAtMillis,
  });

  final String setId;
  final int createdAtMillis;

  @override
  AnnotationKind get kind => AnnotationKind.highlight;

  @override
  HighlightAnnotation shifted(int offset) => HighlightAnnotation(
        cpBegin: cpBegin + offset,
        cpEnd: cpEnd + offset,
        setId: setId,
        createdAtMillis: createdAtMillis,
      );

  @override
  Map<String, Object?> toJson() => {
        'kind': kind.wireName,
        'cpBegin': cpBegin,
        'cpEnd': cpEnd,
        'setId': setId,
        'createdAtMillis': createdAtMillis,
      };

  @override
  bool operator ==(Object other) =>
      other is HighlightAnnotation &&
      other.cpBegin == cpBegin &&
      other.cpEnd == cpEnd &&
      other.setId == setId &&
      other.createdAtMillis == createdAtMillis;

  @override
  int get hashCode => Object.hash(kind, cpBegin, cpEnd, setId, createdAtMillis);

  @override
  String toString() => 'HighlightAnnotation($cpBegin, $cpEnd, "$setId")';
}

/// A token boundary produced by a language analyzer. [lemma] is the dictionary
/// form when it differs from the surface text, which is what dictionary lookup
/// keys off.
final class WordAnnotation extends Annotation {
  const WordAnnotation({
    required super.cpBegin,
    required super.cpEnd,
    this.lemma,
  });

  final String? lemma;

  @override
  AnnotationKind get kind => AnnotationKind.word;

  @override
  WordAnnotation shifted(int offset) => WordAnnotation(
        cpBegin: cpBegin + offset,
        cpEnd: cpEnd + offset,
        lemma: lemma,
      );

  @override
  Map<String, Object?> toJson() => {
        'kind': kind.wireName,
        'cpBegin': cpBegin,
        'cpEnd': cpEnd,
        if (lemma != null) 'lemma': lemma,
      };

  @override
  bool operator ==(Object other) =>
      other is WordAnnotation &&
      other.cpBegin == cpBegin &&
      other.cpEnd == cpEnd &&
      other.lemma == lemma;

  @override
  int get hashCode => Object.hash(kind, cpBegin, cpEnd, lemma);

  @override
  String toString() => 'WordAnnotation($cpBegin, $cpEnd, lemma: $lemma)';
}

/// Thrown when an annotation would partially overlap an existing one, which
/// would make the text impossible to render as a tree.
class AnnotationNestingError extends StateError {
  AnnotationNestingError(this.annotation)
      : super('annotation $annotation does not nest with existing annotations');

  final Annotation annotation;
}

/// Orders annotations the way a tree walk needs them: outermost first.
///
/// Earlier start wins; on a tie the longer range is the outer one; on a further
/// tie [AnnotationKind.priority] breaks it deterministically.
int compareForNesting(Annotation a, Annotation b) {
  if (a.cpBegin != b.cpBegin) return a.cpBegin < b.cpBegin ? -1 : 1;
  if (a.cpEnd != b.cpEnd) return a.cpEnd > b.cpEnd ? -1 : 1;
  return a.kind.priority.compareTo(b.kind.priority);
}

/// Immutable text plus a set of nesting annotations over its code points.
@immutable
class AnnotatedText {
  AnnotatedText._(this.text, List<Annotation> annotations)
      : annotations = UnmodifiableListView(annotations);

  /// Text with no annotations at all.
  factory AnnotatedText.plain(String text) => AnnotatedText._(text, const []);

  /// Builds annotated text, discarding any annotation that fails to nest with
  /// the ones accepted before it.
  ///
  /// Analyzers are best-effort and third-party tokenizers do occasionally emit
  /// crossing spans; dropping the offender is much better than losing the line.
  /// [onRejected] is called for each discarded annotation.
  factory AnnotatedText.lenient(
    String text,
    Iterable<Annotation> annotations, {
    void Function(Annotation annotation)? onRejected,
  }) {
    var result = AnnotatedText.plain(text);
    for (final annotation in annotations) {
      final next = result.tryAdd(annotation);
      if (next == null) {
        onRejected?.call(annotation);
      } else {
        result = next;
      }
    }
    return result;
  }

  /// Builds annotated text, throwing [AnnotationNestingError] on the first
  /// annotation that fails to nest.
  factory AnnotatedText.strict(String text, Iterable<Annotation> annotations) {
    var result = AnnotatedText.plain(text);
    for (final annotation in annotations) {
      result = result.add(annotation);
    }
    return result;
  }

  final String text;

  /// Annotations in insertion order. Use [sortedAnnotations] for tree order.
  final List<Annotation> annotations;

  /// Number of code points in [text].
  late final int length = codePointLength(text);

  /// [annotations] ordered outermost-first, ready for a tree walk.
  late final List<Annotation> sortedAnnotations = List<Annotation>.of(
    annotations,
  )..sort(compareForNesting);

  bool get isEmpty => text.isEmpty;

  /// Adds [annotation], throwing if it would not nest.
  AnnotatedText add(Annotation annotation) {
    final result = tryAdd(annotation);
    if (result == null) throw AnnotationNestingError(annotation);
    return result;
  }

  /// Adds [annotation], returning `null` if it would not nest.
  AnnotatedText? tryAdd(Annotation annotation) {
    _checkRange(annotation);
    final candidate = AnnotatedText._(text, [...annotations, annotation]);
    return candidate._annotationsNest() ? candidate : null;
  }

  /// Replaces any ruby over `[cpBegin, cpEnd)` with [rubyText]; passing a null
  /// or empty [rubyText] just clears it.
  AnnotatedText setRuby(int cpBegin, int cpEnd, String? rubyText) {
    final cleared = clearKindInRange(AnnotationKind.ruby, cpBegin, cpEnd);
    if (rubyText == null || rubyText.isEmpty) return cleared;
    return cleared.add(
      RubyAnnotation(cpBegin: cpBegin, cpEnd: cpEnd, text: rubyText),
    );
  }

  /// Adds a highlight in [setId], first removing any existing highlight from
  /// the same set that overlaps the range.
  AnnotatedText addHighlight(
    int cpBegin,
    int cpEnd,
    String setId, {
    DateTime? createdAt,
  }) {
    final cleared = removeHighlights(cpBegin, cpEnd, setId);
    return cleared.add(HighlightAnnotation(
      cpBegin: cpBegin,
      cpEnd: cpEnd,
      setId: setId,
      createdAtMillis: (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
    ));
  }

  /// Removes highlights belonging to [setId] that overlap `[cpBegin, cpEnd)`.
  AnnotatedText removeHighlights(int cpBegin, int cpEnd, String setId) =>
      AnnotatedText._(
        text,
        annotations
            .where((a) => !(a is HighlightAnnotation &&
                a.setId == setId &&
                a.overlaps(cpBegin, cpEnd)))
            .toList(),
      );

  /// Removes every annotation of [kind] overlapping `[cpBegin, cpEnd)`.
  AnnotatedText clearKindInRange(AnnotationKind kind, int cpBegin, int cpEnd) =>
      AnnotatedText._(
        text,
        annotations
            .where((a) => a.kind != kind || !a.overlaps(cpBegin, cpEnd))
            .toList(),
      );

  AnnotatedText remove(Annotation annotation) => AnnotatedText._(
        text,
        annotations.where((a) => a != annotation).toList(),
      );

  /// Annotations of [kind] covering the code point at [cpIndex], outermost
  /// first.
  List<Annotation> kindAt(AnnotationKind kind, int cpIndex) =>
      (annotations.where((a) => a.kind == kind && a.covers(cpIndex)).toList()
        ..sort(compareForNesting));

  /// All annotations of [kind], outermost first.
  List<Annotation> ofKind(AnnotationKind kind) =>
      (annotations.where((a) => a.kind == kind).toList()
        ..sort(compareForNesting));

  /// All annotations overlapping `[cpBegin, cpEnd)`, outermost first.
  List<Annotation> inRange(int cpBegin, int cpEnd) =>
      (annotations.where((a) => a.overlaps(cpBegin, cpEnd)).toList()
        ..sort(compareForNesting));

  /// Annotations of [kind] overlapping `[cpBegin, cpEnd)`, outermost first.
  List<Annotation> kindInRange(AnnotationKind kind, int cpBegin, int cpEnd) =>
      (annotations
          .where((a) => a.kind == kind && a.overlaps(cpBegin, cpEnd))
          .toList()
        ..sort(compareForNesting));

  /// The text covered by [annotation].
  String textOf(Annotation annotation) =>
      codePointSlice(text, annotation.cpBegin, annotation.cpEnd);

  /// Concatenates several annotated texts, shifting annotation offsets to
  /// match their new position.
  static AnnotatedText concat(Iterable<AnnotatedText> parts) {
    final buffer = StringBuffer();
    final combined = <Annotation>[];
    var offset = 0;
    for (final part in parts) {
      buffer.write(part.text);
      for (final annotation in part.annotations) {
        combined.add(annotation.shifted(offset));
      }
      offset += part.length;
    }
    return AnnotatedText._(buffer.toString(), combined);
  }

  /// Walks the annotation tree, building a list of rendered pieces.
  ///
  /// [transformChar] turns a single code point into a piece; [wrap] receives an
  /// annotation and the pieces it covers, and returns the pieces that replace
  /// them. A Flutter widget tree, an Anki field string and a plain-text export
  /// are all produced by varying these two callbacks.
  List<T> render<T>({
    required T Function(String character, int cpIndex) transformChar,
    required List<T> Function(Annotation annotation, List<T> inner) wrap,
  }) {
    final chars = toCodePoints(text);
    final annotationStack = <Annotation>[];
    final pieceStack = <List<T>>[<T>[]];
    var index = 0;

    void advanceTo(int cpEnd) {
      final top = pieceStack.last;
      for (; index < cpEnd; index++) {
        top.add(transformChar(chars[index], index));
      }
    }

    void unwindTo(int cpIndex) {
      while (
          annotationStack.isNotEmpty && annotationStack.last.cpEnd <= cpIndex) {
        final annotation = annotationStack.removeLast();
        advanceTo(annotation.cpEnd);
        final inner = pieceStack.removeLast();
        pieceStack.last.addAll(wrap(annotation, inner));
      }
    }

    for (final annotation in sortedAnnotations) {
      unwindTo(annotation.cpBegin);
      advanceTo(annotation.cpBegin);
      annotationStack.add(annotation);
      pieceStack.add(<T>[]);
    }

    unwindTo(chars.length);
    advanceTo(chars.length);

    assert(pieceStack.length == 1, 'render left an unbalanced stack');
    return pieceStack.first;
  }

  /// Renders to a plain string using [wrap] to decide what each annotation
  /// contributes. Convenience over [render] for text exports.
  String renderToString({
    required List<String> Function(Annotation annotation, List<String> inner)
        wrap,
  }) =>
      render<String>(
        transformChar: (character, _) => character,
        wrap: wrap,
      ).join();

  Map<String, Object?> toJson() => {
        'text': text,
        'annotations': annotations.map((a) => a.toJson()).toList(),
      };

  static AnnotatedText fromJson(Map<String, Object?> json) {
    final raw = (json['annotations'] as List<Object?>? ?? const <Object?>[]);
    return AnnotatedText._(
      json['text']! as String,
      raw.map((e) => Annotation.fromJson(e! as Map<String, Object?>)).toList(),
    );
  }

  void _checkRange(Annotation annotation) {
    if (annotation.cpBegin < 0 ||
        annotation.cpEnd > length ||
        annotation.cpBegin >= annotation.cpEnd) {
      throw RangeError(
        'annotation range [${annotation.cpBegin}, ${annotation.cpEnd}) is not '
        'a non-empty range within text of length $length',
      );
    }
  }

  /// True when no two annotations partially overlap.
  bool _annotationsNest() {
    final sorted = List<Annotation>.of(annotations)..sort(compareForNesting);
    final stack = <Annotation>[];

    for (final annotation in sorted) {
      while (stack.isNotEmpty && stack.last.cpEnd <= annotation.cpBegin) {
        stack.removeLast();
      }
      if (stack.isNotEmpty && !stack.last.contains(annotation)) return false;
      stack.add(annotation);
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is AnnotatedText &&
      other.text == text &&
      const ListEquality<Annotation>().equals(other.annotations, annotations);

  @override
  int get hashCode =>
      Object.hash(text, const ListEquality<Annotation>().hash(annotations));

  @override
  String toString() =>
      'AnnotatedText("$text", ${annotations.length} annotations)';
}

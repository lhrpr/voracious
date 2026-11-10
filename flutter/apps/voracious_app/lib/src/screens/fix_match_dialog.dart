/// Pick a title's match by hand, when the automatic one is wrong or missing.
library;

import 'package:flutter/material.dart';
import 'package:voracious_core/voracious_core.dart';

import '../state/library_metadata.dart';
import '../widgets/artwork_image.dart';

Future<void> showFixMatchDialog(
  BuildContext context,
  LibraryMetadata metadata,
  MediaTitle title,
) =>
    showDialog<void>(
      context: context,
      builder: (_) => _FixMatchDialog(metadata: metadata, title: title),
    );

class _FixMatchDialog extends StatefulWidget {
  const _FixMatchDialog({required this.metadata, required this.title});

  final LibraryMetadata metadata;
  final MediaTitle title;

  @override
  State<_FixMatchDialog> createState() => _FixMatchDialogState();
}

class _FixMatchDialogState extends State<_FixMatchDialog> {
  late final MetadataQuery? _query = widget.metadata.queryFor(widget.title);
  late final TitleMetadata? _current = widget.metadata.metadataFor(widget.title);

  late final _text = TextEditingController(
    text: _current?.name ?? _query?.name ?? widget.title.name,
  );
  late MetadataKind _kind =
      _current?.kind ?? _query?.kind ?? MetadataKind.series;
  MetadataSource? _source;

  List<MetadataCandidate>? _results;
  bool _busy = false;
  String? _error;

  List<MetadataSource> get _sources => widget.metadata.sourcesFor(_kind);

  @override
  void initState() {
    super.initState();
    _source = _pickSource();
    _search();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// The current match's source if it can search this kind, else the most
  /// preferred one.
  MetadataSource? _pickSource() {
    final sources = _sources;
    if (_current != null && sources.contains(_current.source)) {
      return _current.source;
    }
    return sources.firstOrNull;
  }

  Future<void> _search() async {
    final source = _source;
    if (source == null || _text.text.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results =
          await widget.metadata.search(_text.text.trim(), _kind, source);
      if (mounted) setState(() => _results = results);
    } on MetadataException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) Navigator.of(context).pop();
    } on MetadataException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    return AlertDialog(
      title: Text('Fix match — ${widget.title.name}'),
      content: SizedBox(
        width: 560,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SegmentedButton<MetadataKind>(
                  segments: const [
                    ButtonSegment(
                      value: MetadataKind.series,
                      label: Text('Series'),
                    ),
                    ButtonSegment(
                      value: MetadataKind.movie,
                      label: Text('Film'),
                    ),
                  ],
                  selected: {_kind},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    setState(() {
                      _kind = selection.single;
                      _source = _pickSource();
                    });
                    _search();
                  },
                ),
                const SizedBox(width: 12),
                if (sources.length > 1)
                  DropdownButton<MetadataSource>(
                    value: _source,
                    items: [
                      for (final source in sources)
                        DropdownMenuItem(
                          value: source,
                          child: Text(source.label),
                        ),
                    ],
                    onChanged: (source) {
                      setState(() => _source = source);
                      _search();
                    },
                  )
                else if (sources.length == 1)
                  Text(sources.single.label),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Search',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _busy ? null : _search,
                ),
              ),
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 8),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(child: _resultList(sources)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () => _run(() => widget.metadata.chooseNone(widget.title)),
          child: const Text('No match'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => _run(() =>
                  widget.metadata.refresh(widget.title, resetChoice: true)),
          child: const Text('Match automatically'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _resultList(List<MetadataSource> sources) {
    if (sources.isEmpty) {
      return const Center(
        child: Text(
          'Films are matched with TMDB. Add a free TMDB API key in the '
          'metadata settings to search for them.',
          textAlign: TextAlign.center,
        ),
      );
    }
    final results = _results;
    if (results == null) return const SizedBox.shrink();
    if (results.isEmpty && !_busy) {
      return const Center(child: Text('Nothing found'));
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, i) {
        final candidate = results[i];
        final isCurrent = _current != null &&
            _current.source == candidate.source &&
            _current.id == candidate.id;
        final details = [
          if (candidate.year != null) '${candidate.year}',
          if (candidate.countries.isNotEmpty) candidate.countries.join(', '),
        ].join(' · ');
        return ListTile(
          selected: isCurrent,
          leading: ArtworkImage(
            url: candidate.posterUrl,
            cache: widget.metadata.artwork,
            width: 34,
            height: 51,
          ),
          title: Text(
            details.isEmpty ? candidate.name : '${candidate.name}  ($details)',
          ),
          subtitle: candidate.overview == null
              ? null
              : Text(
                  candidate.overview!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: isCurrent ? const Icon(Icons.check) : null,
          onTap: _busy
              ? null
              : () => _run(
                  () => widget.metadata.choose(widget.title, candidate)),
        );
      },
    );
  }
}

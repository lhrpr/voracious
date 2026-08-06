/// About and licensing.
///
/// Not decoration. Shipping a proprietary application over an LGPL libmpv
/// carries obligations that a UI has to actually discharge: name the library,
/// state its licence, say that it is dynamically linked and therefore
/// replaceable, and offer the corresponding source. `thirdPartyNotices` holds
/// the data and the tests assert that every copyleft entry is dynamically
/// linked and carries a source URL, so this screen only has to display it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voracious_core/voracious_core.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key, this.engineDescription});

  /// The libmpv actually loaded, when a player has been started. Naming the
  /// exact binary is the point — a user who replaces it should see that.
  final String? engineDescription;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('About Voracious'),
          actions: [
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy notices',
              onPressed: () => Clipboard.setData(
                ClipboardData(text: renderNoticesAsText()),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Voracious',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            const Text('A video player for studying languages.'),
            if (engineDescription != null) ...[
              const SizedBox(height: 12),
              SelectableText(
                'Playback engine: $engineDescription',
                style: const TextStyle(fontSize: 12),
              ),
            ],
            const SizedBox(height: 24),
            Text(
              'Third-party software',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final notice in thirdPartyNotices) _NoticeTile(notice: notice),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Source code offer',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'The copyleft components below are dynamically linked '
                      'and can be replaced with your own builds. Their '
                      'corresponding source, and the exact configuration each '
                      'was built with, is available at:',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    const SelectableText(
                      correspondingSourceUrl,
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}

class _NoticeTile extends StatelessWidget {
  const _NoticeTile({required this.notice});

  final ThirdPartyNotice notice;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('${notice.name} — ${notice.license}'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              notice.homepage,
              style: const TextStyle(fontSize: 11),
            ),
            if (notice.notes != null)
              Text(
                notice.notes!,
                style: const TextStyle(fontSize: 11),
              ),
            if (notice.sourceUrl != null)
              SelectableText(
                'Source: ${notice.sourceUrl}',
                style: const TextStyle(fontSize: 11),
              ),
          ],
        ),
      );
}

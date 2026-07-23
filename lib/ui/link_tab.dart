/// Queues everything behind a pasted Beatport URL.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../engine/links.dart';
import '../state/downloads.dart';
import '../state/session.dart';

class LinkTab extends StatefulWidget {
  const LinkTab({super.key});

  @override
  State<LinkTab> createState() => _LinkTabState();
}

class _LinkTabState extends State<LinkTab> {
  final _controller = TextEditingController();
  String? _error;
  String? _lastResult;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(Session session, DownloadQueue queue) async {
    final BeatportLink link;
    try {
      link = parseBeatportLink(_controller.text);
    } on LinkException catch (exception) {
      setState(() => _error = exception.message);
      return;
    }

    setState(() {
      _error = null;
      _lastResult = null;
    });

    final title = await session.catalog.linkTitle(link);
    final added = await queue.enqueueStream(
      session.catalog.linkTracks(link),
      label: title,
    );
    if (!mounted) return;
    _controller.clear();
    setState(() => _lastResult = 'Queued $added tracks from $title.');
  }

  @override
  Widget build(BuildContext context) {
    final session = context.read<Session>();
    final queue = context.watch<DownloadQueue>();
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  textInputAction: TextInputAction.go,
                  onSubmitted: queue.isDiscovering
                      ? null
                      : (_) => _submit(session, queue),
                  decoration: const InputDecoration(
                    labelText: 'Beatport link',
                    hintText:
                        'https://www.beatport.com/release/some-ep/1234567',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  onPressed: queue.isDiscovering
                      ? null
                      : () => _submit(session, queue),
                  icon: const Icon(Icons.playlist_add, size: 18),
                  label: const Text('Queue'),
                ),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (_lastResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_lastResult!, style: theme.textTheme.bodyMedium),
            ),
          if (queue.isDiscovering)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${queue.discoverLabel ?? 'Finding tracks'} - '
                      '${queue.discovered} queued',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: queue.cancelDiscovery,
                    child: const Text('Stop'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          Text('Supported links', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            'Track, release, chart, playlist, label or artist. Store and API '
            'URLs both work, with or without a locale prefix. A label or artist '
            'link queues their whole catalog, so it can be a lot of tracks.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

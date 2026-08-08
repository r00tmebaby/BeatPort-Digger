library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../engine/digger.dart';
import '../engine/models.dart';
import '../state/digger.dart';
import '../state/downloads.dart';
import '../state/session.dart';

const List<int> crateLimitOptions = [
  unlimitedCrateLimit,
  10,
  25,
  50,
  100,
  200,
  500,
  1000,
];

String limitLabelFor(int limit) =>
    limit == unlimitedCrateLimit ? 'Everything' : 'Top $limit';

const List<int> crateWindowOptions = [0, 7, 14, 30, 60, 90, 180, 365];

String windowLabelFor(int days) => days == 0 ? 'All time' : 'Last $days days';

/// Builds a bundle of digs and queues them together.
///
/// The form at the top describes one crate; adding it drops it into the list
/// below and leaves the form as it was, so a run of related crates is quick to
/// build. Queueing walks the bundle in order, and crates added while it runs
/// join the same walk.
class DiggerPage extends StatefulWidget {
  const DiggerPage({super.key});

  @override
  State<DiggerPage> createState() => _DiggerPageState();
}

class _DiggerPageState extends State<DiggerPage> {
  Genre? _genre;
  Named? _subGenre;

  /// Sub-genres of the chosen genre.
  ///
  /// The reference cache does not always carry them: a genre whose lookup
  /// failed during the last refresh has none stored. The search tab fetches
  /// them on demand for exactly that reason, and this page has to as well,
  /// otherwise a genre with sub-genres looks like a genre without any.
  List<Named> _subs = const [];
  bool _loadingSubs = false;
  String _orderBy = '-downloads';
  int _limit = defaultCrateLimit;
  int _windowDays = defaultWindowDays;
  bool _hype = false;
  bool _classic = false;
  bool _exclusive = false;

  final _bpmLow = TextEditingController();
  final _bpmHigh = TextEditingController();

  @override
  void dispose() {
    _bpmLow.dispose();
    _bpmHigh.dispose();
    super.dispose();
  }

  Future<void> _pickGenre(Session session, Genre? genre) async {
    final id = genre?.id;
    setState(() {
      _genre = genre;
      _subGenre = null;
      _subs = id == null ? const [] : (session.subGenresFor(id) ?? const []);
    });

    if (id == null || _subs.isNotEmpty) return;
    setState(() => _loadingSubs = true);
    try {
      final fetched = await session.catalog.subGenres(id);
      if (mounted && _genre?.id == id) setState(() => _subs = fetched);
    } on Object {
      // Best-effort: leave the list empty and let the button say so.
    } finally {
      if (mounted) setState(() => _loadingSubs = false);
    }
  }

  int? _bpm(TextEditingController controller) {
    final value = int.tryParse(controller.text.trim());
    if (value == null || value <= 0) return null;
    return value;
  }

  void _add(DiggerRunner runner) {
    runner.addCrate(
      DiggerCrate(
        id: runner.nextCrateId(),
        genreId: _genre?.id,
        genreName: _genre?.name,
        subGenreId: _subGenre?.id,
        subGenreName: _subGenre?.name,
        orderBy: _orderBy,
        limit: _limit,
        windowDays: _windowDays,
        bpmLow: _bpm(_bpmLow),
        bpmHigh: _bpm(_bpmHigh),
        isHype: _hype,
        isClassic: _classic,
        isExclusive: _exclusive,
      ),
    );
  }

  /// Adds one crate per sub-genre of the chosen genre, which is the quick way
  /// to cover a whole genre in detail.
  ///
  /// Added as one batch: adding them one by one wrote the bundle file once per
  /// crate, with every write racing the others.
  void _addEverySubGenre(DiggerRunner runner) {
    runner.addCrates([
      for (final sub in _subs)
        if (sub.id != null)
          DiggerCrate(
            id: runner.nextCrateId(),
            genreId: _genre?.id,
            genreName: _genre?.name,
            subGenreId: sub.id,
            subGenreName: sub.name,
            orderBy: _orderBy,
            limit: _limit,
            windowDays: _windowDays,
            bpmLow: _bpm(_bpmLow),
            bpmHigh: _bpm(_bpmHigh),
            isHype: _hype,
            isClassic: _classic,
            isExclusive: _exclusive,
          ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final runner = context.watch<DiggerRunner>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            children: [
              _Card(title: 'Add a crate', child: _builder(session, runner)),
              _Card(
                title: 'Bundle (${runner.crates.length})',
                trailing: runner.crates.isEmpty
                    ? null
                    : TextButton.icon(
                        onPressed: runner.clearCrates,
                        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                        label: const Text('Clear'),
                      ),
                child: _bundle(runner),
              ),
            ],
          ),
        ),
        _RunBar(runner: runner, session: session),
      ],
    );
  }

  Widget _builder(Session session, DiggerRunner runner) {
    final theme = Theme.of(context);
    final subs = _subs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<Genre?>(
                initialValue: _genre,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Genre',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<Genre?>(child: Text('Any genre')),
                  for (final genre in session.genres)
                    DropdownMenuItem<Genre?>(
                      value: genre,
                      child: Text(
                        genre.name ?? '',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => _pickGenre(session, value),
              ),
            ),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<Named?>(
                initialValue: _subGenre,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Sub-genre',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<Named?>(child: Text('All sub-genres')),
                  for (final sub in subs)
                    DropdownMenuItem<Named?>(
                      value: sub,
                      child: Text(
                        sub.name ?? '',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: subs.isEmpty || _loadingSubs
                    ? null
                    : (value) => setState(() => _subGenre = value),
              ),
            ),
            SizedBox(
              width: 200,
              child: DropdownButtonFormField<String>(
                initialValue: _orderBy,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Rank by',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final entry in diggerOrderings.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => _orderBy = value ?? '-downloads'),
              ),
            ),
            SizedBox(
              width: 160,
              child: DropdownButtonFormField<int>(
                initialValue: _limit,
                decoration: const InputDecoration(
                  labelText: 'Take',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final n in crateLimitOptions)
                    DropdownMenuItem(value: n, child: Text(limitLabelFor(n))),
                ],
                onChanged: (value) =>
                    setState(() => _limit = value ?? defaultCrateLimit),
              ),
            ),
            SizedBox(
              width: 180,
              child: DropdownButtonFormField<int>(
                initialValue: _windowDays,
                decoration: const InputDecoration(
                  labelText: 'Released within',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final days in crateWindowOptions)
                    DropdownMenuItem(
                      value: days,
                      child: Text(windowLabelFor(days)),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => _windowDays = value ?? defaultWindowDays),
              ),
            ),
            SizedBox(width: 90, child: _bpmField(_bpmLow, 'BPM from')),
            SizedBox(width: 90, child: _bpmField(_bpmHigh, 'BPM to')),
          ],
        ),

        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            FilterChip(
              label: const Text('Hype'),
              selected: _hype,
              onSelected: (value) => setState(() => _hype = value),
            ),
            FilterChip(
              label: const Text('Classic'),
              selected: _classic,
              onSelected: (value) => setState(() => _classic = value),
            ),
            FilterChip(
              label: const Text('Exclusive only'),
              selected: _exclusive,
              onSelected: (value) => setState(() => _exclusive = value),
            ),
          ],
        ),

        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => _add(runner),
              icon: const Icon(Icons.add, size: 18),
              label: Text(
                _subGenre != null
                    ? 'Add this sub-genre'
                    : _genre != null
                    ? 'Add this genre'
                    : 'Add to bundle',
              ),
            ),
            // Always shown once a genre is chosen, disabled with a reason
            // rather than vanishing, so it cannot be mistaken for the button
            // above when a genre's sub-genres have not arrived.
            if (_genre != null)
              OutlinedButton.icon(
                onPressed: subs.isEmpty || _loadingSubs
                    ? null
                    : () => _addEverySubGenre(runner),
                icon: _loadingSubs
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.library_add_outlined, size: 18),
                label: Text(
                  _loadingSubs
                      ? 'Loading sub-genres...'
                      : subs.isEmpty
                      ? 'No sub-genres listed'
                      : 'Add all ${subs.length} sub-genres separately',
                ),
              ),
          ],
        ),

        if (_limit == unlimitedCrateLimit) ...[
          const SizedBox(height: 10),
          Text(
            _windowDays == 0
                ? 'Everything, all time: this walks the catalogue day by day '
                      'back to 2005 and can take a very long time. A date '
                      'window makes it far quicker. Ranking is ignored, since '
                      'the crate takes every match either way.'
                : 'Takes every match in the window, with no 10,000 row cap. '
                      'Ranking is ignored, since nothing gets cut.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: _windowDays == 0
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (session.genres.isEmpty) ...[
          const SizedBox(height: 10),
          Text(
            'Waiting for the genre list. You can still add a crate for the '
            'whole catalog.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _bpmField(TextEditingController controller, String label) => TextField(
    controller: controller,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
  );

  Widget _bundle(DiggerRunner runner) {
    final theme = Theme.of(context);
    if (runner.crates.isEmpty) {
      return Text(
        'Nothing in the bundle yet. Describe a crate above and add it. '
        'Repeat for as many as you want, then queue them all at once.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final current = runner.step?.crate.id;

    return Column(
      children: [
        for (final crate in runner.crates)
          ListTile(
            key: ValueKey(crate.id),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              crate.id == current ? Icons.downloading : Icons.album_outlined,
              color: crate.id == current ? theme.colorScheme.primary : null,
            ),
            title: Text(crate.title),
            subtitle: Text(crate.subtitle, style: theme.textTheme.bodySmall),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (crate.id == current)
                  IconButton(
                    tooltip: 'Stop this crate, keep the rest',
                    icon: const Icon(Icons.skip_next),
                    onPressed: runner.skipCurrentCrate,
                  ),
                IconButton(
                  tooltip: 'Remove from bundle',
                  icon: const Icon(Icons.close),
                  onPressed: () => runner.removeCrate(crate.id),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Live state of the walk filling the queue, wherever it was started from.
typedef _Walk = ({bool discovering, int found, int skipped});

class _RunBar extends StatelessWidget {
  const _RunBar({required this.runner, required this.session});

  final DiggerRunner runner;
  final Session session;

  /// What the walk has actually collected: this crate on its own, then the
  /// run as a whole. Without the running totals a long dig only ever showed
  /// which crate it was on, not whether anything was coming back.
  String _tally(_Walk walk, String crateTitle) {
    final fromCrate = (walk.found - runner.stepQueuedBefore).clamp(
      0,
      walk.found,
    );
    return [
      '$fromCrate queued from $crateTitle',
      '${walk.found} this run',
      if (walk.skipped > 0) '${walk.skipped} already downloaded',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step = runner.step;
    final summary = runner.summary;

    // Selected here rather than at page level, so each discovery batch
    // repaints this bar alone and not the crate list above it - a bundle
    // built with "add all sub-genres" can be a long list of tiles.
    final walk = context.select<DownloadQueue, _Walk>(
      (queue) => (
        discovering: queue.isDiscovering,
        found: queue.discovered,
        skipped: queue.discoverSkipped,
      ),
    );

    return Material(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (step != null) ...[
              LinearProgressIndicator(
                value: step.total == 0 ? null : (step.index + 1) / step.total,
              ),
              const SizedBox(height: 6),
              Text(step.label, style: theme.textTheme.bodySmall),
              Text(
                _tally(walk, step.crate.title),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
            ],

            Row(
              children: [
                Expanded(
                  child: Text(
                    runner.sizeLabel,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: runner.runOnStart,
                      onChanged: runner.setRunOnStart,
                    ),
                    const SizedBox(width: 4),
                    Tooltip(
                      message:
                          'Queue this bundle automatically when the app '
                          'starts. Takes effect next launch.',
                      child: Text('On start', style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                if (runner.running) ...[
                  OutlinedButton.icon(
                    onPressed: runner.canSkipCurrent
                        ? runner.skipCurrentCrate
                        : null,
                    icon: const Icon(Icons.skip_next, size: 18),
                    label: const Text('Enough, next crate'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: runner.stop,
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('Stop all'),
                  ),
                ] else
                  FilledButton.icon(
                    onPressed: runner.crates.isEmpty || walk.discovering
                        ? null
                        : () => runner.run(
                            session,
                            context.read<DownloadQueue>(),
                          ),
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Queue bundle'),
                  ),
              ],
            ),

            if (!runner.running && summary != null) ...[
              const SizedBox(height: 6),
              Text('Last dig: $summary', style: theme.textTheme.bodySmall),
            ],
            if (runner.error != null) ...[
              const SizedBox(height: 6),
              Text(
                runner.error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (runner.failures.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                runner.failures.join('\n'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                ?trailing,
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

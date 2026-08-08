library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../engine/throughput.dart';
import '../state/downloads.dart';
import '../state/player.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

enum _JobOrder { recent, status, title, artist }

int _statusRank(JobStatus status) => switch (status) {
  JobStatus.running => 0,
  JobStatus.queued => 1,
  JobStatus.failed => 2,
  JobStatus.cancelled => 3,
  JobStatus.completed => 4,
};

class _DownloadsPageState extends State<DownloadsPage> {
  _JobOrder _order = _JobOrder.recent;

  // Deriving the visible order used to mean copying, sorting and filtering the
  // whole job list on every rebuild, and rebuilds arrive several times a
  // second while downloads run. At a hundred thousand jobs that alone was
  // enough to stop the list scrolling, so each derived view is cached and
  // recomputed only when the thing it actually depends on changes.
  List<DownloadJob>? _cachedOrder;
  _JobOrder? _cachedOrderKind;
  int _cachedRevision = -1;
  int _cachedStructure = -1;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<DownloadQueue>().checkFfmpeg();
    });
  }

  void _play(
    BuildContext context,
    DownloadJob job,
    Iterable<DownloadJob> jobs,
  ) {
    final player = context.read<PreviewPlayer>();

    // Built here rather than during build: at scale this is a full scan, and
    // it is only ever needed the moment someone presses play.
    final completed = [
      for (final candidate in jobs)
        if (candidate.status == JobStatus.completed && candidate.path != null)
          candidate,
    ];

    player.setUpNext(
      [for (final j in completed) j.track],
      files: {
        for (final j in completed)
          if (j.track.id != null && j.path != null) j.track.id!: j.path!,
      },
    );
    if (job.path != null) player.playLocal(job.track, job.path!);
  }

  /// The jobs in display order.
  ///
  /// "Recent" is the reverse of insertion order, which the list can read
  /// directly by index, so it never builds a second list at all. Title and
  /// artist order depend only on which jobs exist, so they survive a whole
  /// download run without re-sorting. Status order is a linear bucket pass
  /// rather than a comparison sort, because it does have to be redone
  /// whenever a job changes state.
  List<DownloadJob> _ordered(DownloadQueue queue) {
    final jobs = queue.jobs;
    if (_order == _JobOrder.recent) return jobs;

    final dependsOnStatus = _order == _JobOrder.status;
    final revision = queue.revision;
    final structure = queue.structureRevision;

    final cached = _cachedOrder;
    if (cached != null &&
        _cachedOrderKind == _order &&
        _cachedStructure == structure &&
        (!dependsOnStatus || _cachedRevision == revision)) {
      return cached;
    }

    final List<DownloadJob> ordered;
    switch (_order) {
      case _JobOrder.recent:
        ordered = jobs;
      case _JobOrder.status:
        final buckets = List.generate(
          JobStatus.values.length,
          (_) => <DownloadJob>[],
          growable: false,
        );
        for (final job in jobs) {
          buckets[_statusRank(job.status)].add(job);
        }
        ordered = [for (final bucket in buckets) ...bucket];
      case _JobOrder.title:
        ordered = List.of(jobs)
          ..sort((a, b) => a.titleKey.compareTo(b.titleKey));
      case _JobOrder.artist:
        ordered = List.of(jobs)
          ..sort((a, b) => a.artistKey.compareTo(b.artistKey));
    }

    _cachedOrder = ordered;
    _cachedOrderKind = _order;
    _cachedRevision = revision;
    _cachedStructure = structure;
    return ordered;
  }

  @override
  Widget build(BuildContext context) {
    final queue = context.watch<DownloadQueue>();
    final jobs = _ordered(queue);
    final newestFirst = _order == _JobOrder.recent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (jobs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Text(
                  [
                    '${queue.activeCount} active, ${jobs.length} total',
                    // The figure that separates "64 at once is faster" from
                    // "64 at once slices the same pipe thinner".
                    if (queue.activeCount > 0)
                      formatSpeed(queue.bytesPerSecond),
                    if (queue.bytesThisSession > 0)
                      '${formatBytes(queue.bytesThisSession)} this session',
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 12),
                DropdownButton<_JobOrder>(
                  value: _order,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  onChanged: (value) =>
                      setState(() => _order = value ?? _JobOrder.recent),
                  items: const [
                    DropdownMenuItem(
                      value: _JobOrder.recent,
                      child: Text('Recent'),
                    ),
                    DropdownMenuItem(
                      value: _JobOrder.status,
                      child: Text('Status'),
                    ),
                    DropdownMenuItem(
                      value: _JobOrder.title,
                      child: Text('Title'),
                    ),
                    DropdownMenuItem(
                      value: _JobOrder.artist,
                      child: Text('Artist'),
                    ),
                  ],
                ),
                const Spacer(),

                if (queue.activeCount > 0)
                  FilledButton.tonalIcon(
                    onPressed: queue.cancelAll,
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: Text('Stop all (${queue.activeCount})'),
                  ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: queue.clearFinished,
                  icon: const Icon(Icons.clear_all, size: 18),
                  label: const Text('Clear finished'),
                ),
                TextButton.icon(
                  onPressed: queue.clearAll,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Clear all'),
                ),
              ],
            ),
          ),
        if (queue.active.isNotEmpty) _ActiveStrip(queue: queue),
        Expanded(
          child: jobs.isEmpty
              ? Center(
                  child: Text(
                    'Nothing queued yet.\nUse the download button on a track.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : ListView.separated(
                  itemCount: jobs.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    // queue.jobs is a live view, so a clear landing between
                    // this frame's itemCount and the rebuild that follows it
                    // can leave an index pointing past the end.
                    if (index >= jobs.length) return const SizedBox.shrink();

                    // "Recent" reads the queue's own list backwards instead of
                    // materialising a reversed copy of it.
                    final job = newestFirst
                        ? jobs[jobs.length - 1 - index]
                        : jobs[index];
                    return _JobTile(
                      job: job,
                      queue: queue,
                      onPlay: () => _play(
                        context,
                        job,
                        newestFirst ? jobs.reversed : jobs,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// The tracks actually moving right now, pinned above the queue.
///
/// The full list can be a hundred thousand rows in any of four orders, so
/// finding what is in flight by scrolling is hopeless.
///
/// Only a handful of rows are ever built. The first version used a
/// shrink-wrapped list, which builds and lays out every child to measure
/// itself, so at sixty-four parallel downloads it rendered sixty-four rows of
/// animating progress bars several times a second - and kept animating them
/// while the user was on another tab, because the app holds every page in an
/// IndexedStack.
class _ActiveStrip extends StatelessWidget {
  const _ActiveStrip({required this.queue});

  static const int _maxRows = 5;

  final DownloadQueue queue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = queue.active;
    final shown = active.length < _maxRows ? active.length : _maxRows;
    final hidden = active.length - shown;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Text(
              'Downloading now (${active.length}) · '
              '${formatSpeed(queue.bytesPerSecond)}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (var i = 0; i < shown; i++)
            _ActiveTile(job: active[i], queue: queue),
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Text(
                'and $hidden more downloading',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ActiveTile extends StatelessWidget {
  const _ActiveTile({required this.job, required this.queue});

  final DownloadJob job;
  final DownloadQueue queue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = job.progress;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${job.track.artistNames} - ${job.track.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  minHeight: 3,
                  value: progress == null || progress.total == 0
                      ? null
                      : progress.fraction,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: Text(
              progress == null
                  ? 'Starting...'
                  : progress.segmented
                  ? '${progress.completed}/${progress.total} seg'
                  : _megabytes(progress.bytes),
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall,
            ),
          ),
          IconButton(
            tooltip: 'Cancel',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => queue.cancel(job),
          ),
        ],
      ),
    );
  }
}

String _megabytes(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

class _JobTile extends StatelessWidget {
  const _JobTile({
    required this.job,
    required this.queue,
    required this.onPlay,
  });

  final DownloadJob job;
  final DownloadQueue queue;

  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = job.progress;

    return ListTile(
      title: Text(
        job.track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            job.track.artistNames,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          if (job.status == JobStatus.running)
            LinearProgressIndicator(
              value: progress == null || progress.total == 0
                  ? null
                  : progress.fraction,
            ),
          Text(
            _statusLine(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: (job.status == JobStatus.completed && job.isSample)
                  ? scheme.tertiary
                  : null,
              fontWeight: (job.status == JobStatus.completed && job.isSample)
                  ? FontWeight.bold
                  : null,
            ),
          ),
          if (job.error != null)
            Text(
              job.error!,
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
            ),
        ],
      ),
      isThreeLine: true,
      trailing: _trailing(context),
    );
  }

  String _statusLine() {
    final progress = job.progress;
    return switch (job.status) {
      JobStatus.queued => 'Queued',
      JobStatus.running =>
        progress == null
            ? 'Starting...'
            : progress.segmented
            ? 'Segment ${progress.completed} of ${progress.total} - '
                  '${_megabytes(progress.bytes)}'
            : progress.total > 0
            ? '${_megabytes(progress.bytes)} of '
                  '${_megabytes(progress.total)}'
            : _megabytes(progress.bytes),

      JobStatus.completed =>
        job.isSample
            ? (Platform.isAndroid
                  ? 'Saved SAMPLE (${job.sampleReason ?? 'full track unavailable'}) '
                        'to Music/BeatPort Digger \u2014 not the full song'
                  : Platform.isIOS
                  ? 'Saved SAMPLE (${job.sampleReason ?? 'full track unavailable'}) '
                        'to the app folder (Files app) \u2014 not the full song'
                  : 'Saved SAMPLE (${job.sampleReason ?? 'full track unavailable'}) '
                        'to ${job.path} \u2014 not the full song')
            : Platform.isAndroid
            ? 'Saved to Music/BeatPort Digger'
            : Platform.isIOS
            ? 'Saved to the app folder (Files app)'
            : (job.remuxed
                  ? 'Saved to ${job.path}'
                  : 'Saved as .ts to ${job.path}'),
      JobStatus.failed => 'Failed',
      JobStatus.cancelled => 'Cancelled',
    };
  }

  Widget _trailing(BuildContext context) {
    switch (job.status) {
      case JobStatus.queued:
      case JobStatus.running:
        return IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () => queue.cancel(job),
        );
      case JobStatus.completed:
        return Consumer<PreviewPlayer>(
          builder: (context, player, _) {
            final isThis = player.current?.id == job.track.id;
            final playing = isThis && player.playing;
            final loading = isThis && player.loading;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else
                  IconButton(
                    tooltip: playing ? 'Pause' : 'Play',
                    icon: Icon(
                      playing ? Icons.pause_circle : Icons.play_circle_outline,
                    ),
                    onPressed: job.path == null ? null : onPlay,
                  ),

                if (!Platform.isAndroid && !Platform.isIOS)
                  IconButton(
                    tooltip: 'Show in folder',
                    icon: const Icon(Icons.folder_open),
                    onPressed: job.path == null
                        ? null
                        : () => _reveal(job.path!),
                  ),
              ],
            );
          },
        );
      case JobStatus.failed:
      case JobStatus.cancelled:
        return IconButton(
          tooltip: 'Retry',
          icon: const Icon(Icons.refresh),
          onPressed: () => queue.enqueue(job.track),
        );
    }
  }

  Future<void> _reveal(String path) async {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [File(path).parent.path]);
    }
  }
}

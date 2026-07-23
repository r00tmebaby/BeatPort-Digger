/// Queued and finished downloads.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/downloads.dart';
import '../state/player.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

/// How the downloads list is ordered.
enum _JobOrder { recent, status, title, artist }

/// Priority of a status when sorting by state: active work first, done last.
int _statusRank(JobStatus status) => switch (status) {
  JobStatus.running => 0,
  JobStatus.queued => 1,
  JobStatus.failed => 2,
  JobStatus.cancelled => 3,
  JobStatus.completed => 4,
};

class _DownloadsPageState extends State<DownloadsPage> {
  _JobOrder _order = _JobOrder.recent;

  @override
  void initState() {
    super.initState();
    // Probe after the first frame: the check runs a process and must not block
    // the build that is mounting this page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<DownloadQueue>().checkFfmpeg();
    });
  }

  /// Plays a completed download and sets autoplay to step through the rest of
  /// the completed list from here.
  void _play(
    BuildContext context,
    DownloadJob job,
    List<DownloadJob> completed,
  ) {
    final player = context.read<PreviewPlayer>();
    player.setUpNext(
      [for (final j in completed) j.track],
      files: {
        for (final j in completed)
          if (j.track.id != null && j.path != null) j.track.id!: j.path!,
      },
    );
    if (job.path != null) player.playLocal(job.track, job.path!);
  }

  /// Jobs in display order. Recent is newest first; the rest are stable sorts
  /// over a copy so the queue's own order is untouched.
  List<DownloadJob> _ordered(List<DownloadJob> jobs) {
    switch (_order) {
      case _JobOrder.recent:
        return jobs.reversed.toList();
      case _JobOrder.status:
        return List.of(jobs)..sort(
          (a, b) => _statusRank(a.status).compareTo(_statusRank(b.status)),
        );
      case _JobOrder.title:
        return List.of(jobs)..sort(
          (a, b) => a.track.title.toLowerCase().compareTo(
            b.track.title.toLowerCase(),
          ),
        );
      case _JobOrder.artist:
        return List.of(jobs)..sort(
          (a, b) => a.track.artistNames.toLowerCase().compareTo(
            b.track.artistNames.toLowerCase(),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final queue = context.watch<DownloadQueue>();
    final jobs = _ordered(queue.jobs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (jobs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Text(
                  '${queue.activeCount} active, ${jobs.length} total',
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
                // Stopping everything is the action wanted in a hurry, so it is
                // a filled button rather than buried in the per-row menu.
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
        Expanded(
          child: jobs.isEmpty
              ? Center(
                  child: Text(
                    'Nothing queued yet.\nUse the download button on a track.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : Builder(
                  builder: (context) {
                    // Completed downloads, in display order, are what autoplay
                    // steps through once one is played.
                    final completed = jobs
                        .where(
                          (j) =>
                              j.status == JobStatus.completed && j.path != null,
                        )
                        .toList();
                    return ListView.separated(
                      itemCount: jobs.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final job = jobs[index];
                        return _JobTile(
                          job: job,
                          queue: queue,
                          onPlay: () => _play(context, job, completed),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
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

  /// Plays this completed download and queues the rest for autoplay.
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
          Text(_statusLine(), style: theme.textTheme.labelSmall),
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
      // Phones show the friendly shared location; desktop shows the full path
      // it can actually open.
      JobStatus.completed =>
        Platform.isAndroid
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
                // Revealing a file needs a desktop file manager; phones have no
                // equivalent, so the folder button is desktop-only.
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

  /// Opens the containing folder with the platform's file manager.
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

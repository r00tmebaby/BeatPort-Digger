library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/download_history.dart';
import '../../engine/models.dart';
import '../../state/downloads.dart';
import '../../state/player.dart';
import 'camelot.dart';

enum TrackSort { none, artists, title, label, genre, bpm, key, length }

enum PlaybackState { idle, loading, playing, paused }

Color? statusColor(
  JobStatus? status,
  ColorScheme scheme,
  Brightness brightness,
) {
  if (status == null) return null;
  final alpha = brightness == Brightness.dark ? 0.22 : 0.16;
  final base = switch (status) {
    JobStatus.queued => const Color(0xFF8A8A8A),
    JobStatus.running => scheme.primary,
    JobStatus.completed => const Color(0xFF3FBF6A),
    JobStatus.failed => scheme.error,
    JobStatus.cancelled => const Color(0xFFE0A93F),
  };
  return base.withValues(alpha: alpha);
}

String statusLabel(JobStatus status) => switch (status) {
  JobStatus.queued => 'Queued',
  JobStatus.running => 'Downloading',
  JobStatus.completed => 'Saved',
  JobStatus.failed => 'Failed',
  JobStatus.cancelled => 'Cancelled',
};

class TrackBadges extends StatelessWidget {
  const TrackBadges({super.key, required this.track});

  final Track track;

  static const Map<String, Color> _colours = {
    'Hype': Color(0xFF00C2A8),
    'Exclusive': Color(0xFFE0A93F),
    'Classic': Color(0xFF9B7BE0),
    'DJ Edit': Color(0xFF4F9BE0),
    'Pre-order': Color(0xFF8A8A8A),
    'E': Color(0xFFC0563F),
  };

  @override
  Widget build(BuildContext context) {
    final badges = track.badges;
    if (badges.isEmpty) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Wrap(
      spacing: 4,
      runSpacing: 2,
      children: [
        for (final badge in badges)
          Tooltip(
            message: badge == 'E' ? 'Explicit' : badge,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: (_colours[badge] ?? Colors.grey).withValues(
                  alpha: dark ? 0.30 : 0.20,
                ),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(
                  color: (_colours[badge] ?? Colors.grey).withValues(
                    alpha: 0.55,
                  ),
                ),
              ),
              child: Text(
                badge,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

PlaybackState playbackStateFor(PreviewPlayer player, Track track) {
  if (!player.isCurrent(track)) return PlaybackState.idle;
  if (player.loading) return PlaybackState.loading;
  return player.playing ? PlaybackState.playing : PlaybackState.paused;
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.track,
    required this.onPlay,
    required this.playingState,
  });

  final Track track;
  final void Function(Track)? onPlay;
  final PlaybackState Function(Track)? playingState;

  @override
  Widget build(BuildContext context) {
    if (onPlay == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final state = playingState?.call(track) ?? PlaybackState.idle;

    if (state == PlaybackState.loading) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: SizedBox(
            width: 15,
            height: 15,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final active = state != PlaybackState.idle;
    return IconButton(
      onPressed: () => onPlay!(track),
      tooltip: state == PlaybackState.playing ? 'Pause' : 'Preview',
      icon: Icon(
        state == PlaybackState.playing
            ? Icons.pause_circle_filled
            : Icons.play_circle_outline,
        size: 21,
        color: active ? scheme.primary : null,
      ),
    );
  }
}

int _lengthSeconds(String? value) {
  if (value == null || value.isEmpty) return -1;
  final parts = value.split(':').map((p) => int.tryParse(p.trim()) ?? 0);
  return parts.fold(0, (total, part) => total * 60 + part);
}

int _keyRank(Track track) {
  final number = track.key?.camelotNumber;
  final letter = track.key?.camelotLetter;
  if (number == null || letter == null) return 1 << 20;
  return number * 2 + (letter.toUpperCase() == 'A' ? 0 : 1);
}

String _clipboardText(Track track) {
  final artists = track.artistNames.trim();
  final title = track.title.trim();
  if (artists.isEmpty) return title;
  if (title.isEmpty) return artists;
  return '$artists - $title';
}

List<Track> sortTracks(List<Track> tracks, TrackSort sort, bool ascending) {
  if (sort == TrackSort.none) return tracks;

  int compare(Track a, Track b) => switch (sort) {
    TrackSort.artists => a.artistNames.toLowerCase().compareTo(
      b.artistNames.toLowerCase(),
    ),
    TrackSort.title => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    TrackSort.label => a.labelName.toLowerCase().compareTo(
      b.labelName.toLowerCase(),
    ),
    TrackSort.genre =>
      (a.subGenreName.isEmpty ? a.genreName : a.subGenreName)
          .toLowerCase()
          .compareTo(
            (b.subGenreName.isEmpty ? b.genreName : b.subGenreName)
                .toLowerCase(),
          ),
    TrackSort.bpm => (a.bpm ?? -1).compareTo(b.bpm ?? -1),
    TrackSort.key => _keyRank(a).compareTo(_keyRank(b)),
    TrackSort.length => _lengthSeconds(
      a.length,
    ).compareTo(_lengthSeconds(b.length)),
    TrackSort.none => 0,
  };

  final ordered = List<Track>.of(tracks)..sort(compare);
  return ascending ? ordered : ordered.reversed.toList();
}

class TrackTable extends StatefulWidget {
  const TrackTable({
    super.key,
    required this.tracks,
    this.onTap,
    this.onDownload,
    this.statusFor,
    this.selected,
    this.onSelectionChanged,
    this.onPlay,
    this.playingState,
    this.colourByStatus = true,
    this.rankFor,
    this.rankLabel,
    this.historyMarkFor,
    this.updates,
  });

  final List<Track> tracks;
  final void Function(Track)? onTap;

  final void Function(Track)? onDownload;

  final JobStatus? Function(Track)? statusFor;

  final Set<int>? selected;
  final void Function(Set<int>)? onSelectionChanged;

  final void Function(Track)? onPlay;

  final PlaybackState Function(Track)? playingState;

  final bool colourByStatus;

  final int? Function(Track)? rankFor;

  final String? rankLabel;

  final HistoryMark Function(Track)? historyMarkFor;

  /// Notifies when the answers of [statusFor], [historyMarkFor] or
  /// [playingState] may have changed, e.g. the download queue and the preview
  /// player merged into one listenable.
  ///
  /// Rows listen to this individually and repaint only when their own values
  /// actually changed. Without it the table has to be rebuilt from outside for
  /// every change anywhere - and the sources notify constantly: the queue on
  /// every job transition, the player on every position tick. Rebuilding
  /// hundreds of rows, and re-sorting, at that rate is what made the app drag
  /// while downloading; with this wired the table itself never rebuilds for
  /// state churn at all.
  final Listenable? updates;

  @override
  State<TrackTable> createState() => _TrackTableState();
}

/// What one row shows of the app's mutable state. Compared by value after
/// every [TrackTable.updates] tick to decide whether that row repaints, so it
/// must stay cheap to compute and to compare.
typedef _RowState = (JobStatus?, HistoryMark, PlaybackState);

/// One row that follows [TrackTable.updates] on its own.
///
/// Listening per row looks extravagant, but only built rows exist - a lazy
/// list keeps a couple of screens' worth alive - so this is a few dozen
/// listeners, each doing two map lookups per notification and repainting only
/// on a real change. Progress bytes and play position pass through here as
/// "nothing changed" and cost no paint.
class _LiveRow extends StatefulWidget {
  const _LiveRow({
    required this.updates,
    required this.rowState,
    required this.builder,
  });

  final Listenable? updates;
  final _RowState Function() rowState;
  final WidgetBuilder builder;

  @override
  State<_LiveRow> createState() => _LiveRowState();
}

class _LiveRowState extends State<_LiveRow> {
  // Assigned in initState rather than as a late initializer: late runs on
  // first access, which would be inside _check after the state has already
  // moved, making every comparison see two fresh values and never repaint.
  late _RowState _last;

  @override
  void initState() {
    super.initState();
    _last = widget.rowState();
    widget.updates?.addListener(_check);
  }

  @override
  void didUpdateWidget(_LiveRow old) {
    super.didUpdateWidget(old);
    if (!identical(old.updates, widget.updates)) {
      old.updates?.removeListener(_check);
      widget.updates?.addListener(_check);
    }
    // The parent rebuilt, so the row is being rebuilt with it; resync the
    // snapshot rather than diffing against a stale one.
    _last = widget.rowState();
  }

  @override
  void dispose() {
    widget.updates?.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final next = widget.rowState();
    if (next == _last) return;
    setState(() => _last = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

class _TrackTableState extends State<TrackTable> {
  TrackSort _sort = TrackSort.none;
  bool _ascending = true;

  bool get _selectable =>
      widget.selected != null && widget.onSelectionChanged != null;

  void _toggleSort(TrackSort column) {
    setState(() {
      if (_sort == column) {
        _ascending = !_ascending;
      } else {
        _sort = column;
        _ascending = true;
      }
    });
  }

  void _toggle(Track track) {
    final id = track.id;
    if (id == null || !_selectable) return;
    final next = Set<int>.of(widget.selected!);
    if (!next.remove(id)) next.add(id);
    widget.onSelectionChanged!(next);
  }

  void _toggleAll(List<Track> visible) {
    if (!_selectable) return;
    final ids = visible.map((t) => t.id).whereType<int>().toSet();
    final allSelected = ids.isNotEmpty && widget.selected!.containsAll(ids);
    final next = Set<int>.of(widget.selected!);
    if (allSelected) {
      next.removeAll(ids);
    } else {
      next.addAll(ids);
    }
    widget.onSelectionChanged!(next);
  }

  _RowState _rowState(Track track) => (
    widget.statusFor?.call(track),
    widget.historyMarkFor?.call(track) ?? HistoryMark.none,
    widget.playingState?.call(track) ?? PlaybackState.idle,
  );

  @override
  Widget build(BuildContext context) {
    final ordered = sortTracks(widget.tracks, _sort, _ascending);
    final wide = MediaQuery.sizeOf(context).width >= 760;

    return wide
        ? _WideTable(tracks: ordered, state: this)
        : _NarrowList(tracks: ordered, state: this);
  }
}

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({
    required this.track,
    required this.onDownload,
    required this.statusFor,
    this.historyMark = HistoryMark.none,
  });

  final Track track;
  final void Function(Track)? onDownload;
  final JobStatus? Function(Track)? statusFor;
  final HistoryMark historyMark;

  @override
  Widget build(BuildContext context) {
    if (onDownload == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final status = statusFor?.call(track);

    if (status == null && historyMark != HistoryMark.none) {
      final missing = historyMark == HistoryMark.missing;
      return IconButton(
        onPressed: () => onDownload!(track),
        tooltip: missing
            ? 'Downloaded before, file missing - download again'
            : 'Already downloaded - download again',
        icon: Icon(
          missing ? Icons.report_gmailerrorred : Icons.download_done,
          size: 20,
          color: missing ? scheme.error : scheme.primary,
        ),
      );
    }

    switch (status) {
      case JobStatus.queued:
        return const IconButton(
          onPressed: null,
          tooltip: 'Queued',
          icon: Icon(Icons.schedule, size: 20),
        );
      case JobStatus.running:
        // A static icon, not a spinner: a page of results mid-bulk-download
        // can show dozens of running rows, and each spinner animates every
        // frame for as long as it is visible.
        return IconButton(
          onPressed: null,
          tooltip: 'Downloading',
          icon: Icon(Icons.downloading, size: 20, color: scheme.primary),
        );
      case JobStatus.completed:
        return IconButton(
          onPressed: null,
          tooltip: 'Downloaded',
          icon: Icon(Icons.check_circle, size: 20, color: scheme.primary),
        );
      case JobStatus.failed:
      case JobStatus.cancelled:
        return IconButton(
          onPressed: () => onDownload!(track),
          tooltip: status == JobStatus.failed
              ? 'Failed - retry'
              : 'Cancelled - retry',
          icon: Icon(Icons.refresh, size: 20, color: scheme.error),
        );
      case null:
        return IconButton(
          onPressed: () => onDownload!(track),
          tooltip: 'Download',
          icon: const Icon(Icons.download_outlined, size: 20),
        );
    }
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Copy song',
      icon: const Icon(Icons.content_copy, size: 18),
      onPressed: () {
        Clipboard.setData(ClipboardData(text: _clipboardText(track)));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Copied song to clipboard.'),
            duration: Duration(seconds: 2),
          ),
        );
      },
    );
  }
}

class _SortableHeader extends StatelessWidget {
  const _SortableHeader({
    required this.label,
    required this.column,
    required this.state,
    this.center = false,
  });

  final String label;
  final TrackSort column;
  final _TrackTableState state;

  final bool center;

  @override
  Widget build(BuildContext context) {
    final active = state._sort == column;
    return InkWell(
      onTap: () => state._toggleSort(column),
      child: Row(
        mainAxisAlignment: center
            ? MainAxisAlignment.center
            : MainAxisAlignment.start,
        children: [
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          if (active)
            Icon(
              state._ascending ? Icons.arrow_upward : Icons.arrow_downward,
              size: 13,
            ),
        ],
      ),
    );
  }
}

class _WideTable extends StatelessWidget {
  const _WideTable({required this.tracks, required this.state});

  final List<Track> tracks;
  final _TrackTableState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final widget = state.widget;
    final selectable = state._selectable;
    final ids = tracks.map((t) => t.id).whereType<int>().toSet();
    final allSelected =
        selectable && ids.isNotEmpty && widget.selected!.containsAll(ids);
    final someSelected =
        selectable && ids.any((id) => widget.selected!.contains(id));

    final header = Material(
      elevation: 2,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: DefaultTextStyle(
          style: theme.textTheme.labelMedium!,
          child: Row(
            children: [
              if (selectable)
                SizedBox(
                  width: 40,
                  child: Checkbox(
                    value: allSelected ? true : (someSelected ? null : false),
                    tristate: true,
                    onChanged: (_) => state._toggleAll(tracks),
                  ),
                ),
              const SizedBox(width: 40),
              const SizedBox(width: 36, child: Text('#')),
              if (widget.rankFor != null)
                SizedBox(
                  width: 54,
                  child: Tooltip(
                    message:
                        'Rank by ${widget.rankLabel?.toLowerCase()} within '
                        'these results. Beatport does not publish the counts.',
                    child: Text(widget.rankLabel ?? 'Rank'),
                  ),
                ),
              Expanded(
                flex: 3,
                child: _SortableHeader(
                  label: 'Artists',
                  column: TrackSort.artists,
                  state: state,
                ),
              ),
              Expanded(
                flex: 4,
                child: _SortableHeader(
                  label: 'Title',
                  column: TrackSort.title,
                  state: state,
                ),
              ),
              Expanded(
                flex: 3,
                child: _SortableHeader(
                  label: 'Label',
                  column: TrackSort.label,
                  state: state,
                ),
              ),
              Expanded(
                flex: 2,
                child: _SortableHeader(
                  label: 'Genre',
                  column: TrackSort.genre,
                  state: state,
                ),
              ),
              SizedBox(
                width: 52,
                child: _SortableHeader(
                  label: 'BPM',
                  column: TrackSort.bpm,
                  state: state,
                  center: true,
                ),
              ),
              SizedBox(
                width: 60,
                child: _SortableHeader(
                  label: 'Key',
                  column: TrackSort.key,
                  state: state,
                  center: true,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 56,
                child: _SortableHeader(
                  label: 'Len',
                  column: TrackSort.length,
                  state: state,
                  center: true,
                ),
              ),
              const SizedBox(width: 84),
            ],
          ),
        ),
      ),
    );

    final list = ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];

        // Everything the row shows of mutable state is read inside the
        // builder, so a repaint triggered by _LiveRow picks up fresh values.
        return _LiveRow(
          updates: widget.updates,
          rowState: () => state._rowState(track),
          builder: (context) => _row(context, theme, track, index),
        );
      },
    );

    return Column(
      children: [
        header,
        Expanded(child: list),
      ],
    );
  }

  Widget _row(BuildContext context, ThemeData theme, Track track, int index) {
    final widget = state.widget;
    final selectable = state._selectable;
    final id = track.id;
    final checked = selectable && id != null && widget.selected!.contains(id);
    final status = widget.statusFor?.call(track);

    final tint = checked
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.25)
        : widget.colourByStatus
        ? statusColor(status, theme.colorScheme, theme.brightness)
        : null;

    return InkWell(
      onTap: widget.onTap == null ? null : () => widget.onTap!(track),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: tint,
          border: Border(
            bottom: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.4),
            ),
          ),
        ),
        child: DefaultTextStyle(
          style: theme.textTheme.bodySmall!,
          child: Row(
            children: [
              if (selectable)
                SizedBox(
                  width: 40,
                  child: Checkbox(
                    value: checked,
                    onChanged: (_) => state._toggle(track),
                  ),
                ),
              SizedBox(
                width: 40,
                child: _PlayButton(
                  track: track,
                  onPlay: widget.onPlay,
                  playingState: widget.playingState,
                ),
              ),
              SizedBox(width: 36, child: Text('${index + 1}')),
              if (widget.rankFor != null)
                SizedBox(
                  width: 54,
                  child: Builder(
                    builder: (context) {
                      final rank = widget.rankFor!(track);
                      if (rank == null) return const Text('');
                      return Text(
                        '#$rank',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary,
                        ),
                      );
                    },
                  ),
                ),
              Expanded(flex: 3, child: Text(track.artistNames, maxLines: 2)),
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.title,
                      maxLines: 2,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    if (track.badges.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      TrackBadges(track: track),
                    ],
                  ],
                ),
              ),
              Expanded(flex: 3, child: Text(track.labelName, maxLines: 2)),
              Expanded(
                flex: 2,
                child: Text(
                  track.subGenreName.isEmpty
                      ? track.genreName
                      : track.subGenreName,
                  maxLines: 2,
                ),
              ),
              SizedBox(
                width: 52,
                child: Text('${track.bpm ?? ''}', textAlign: TextAlign.center),
              ),
              SizedBox(
                width: 60,
                child: Center(child: _KeyChip(track: track)),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 56,
                child: Text(track.length ?? '', textAlign: TextAlign.center),
              ),
              SizedBox(width: 36, child: _CopyButton(track: track)),
              SizedBox(
                width: 48,
                child: _DownloadButton(
                  track: track,
                  onDownload: widget.onDownload,
                  statusFor: widget.statusFor,
                  historyMark:
                      widget.historyMarkFor?.call(track) ?? HistoryMark.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NarrowList extends StatelessWidget {
  const _NarrowList({required this.tracks, required this.state});

  final List<Track> tracks;
  final _TrackTableState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final widget = state.widget;

    return ListView.separated(
      itemCount: tracks.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final track = tracks[index];
        return _LiveRow(
          updates: widget.updates,
          rowState: () => state._rowState(track),
          builder: (context) => _tile(context, theme, track),
        );
      },
    );
  }

  Widget _tile(BuildContext context, ThemeData theme, Track track) {
    final widget = state.widget;
    final selectable = state._selectable;
    final id = track.id;
    final checked = selectable && id != null && widget.selected!.contains(id);
    final status = widget.statusFor?.call(track);
    final tint = checked
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.25)
        : widget.colourByStatus
        ? statusColor(status, theme.colorScheme, theme.brightness)
        : null;

    return ListTile(
      tileColor: tint,
      onTap: widget.onTap == null ? null : () => widget.onTap!(track),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selectable)
            Checkbox(value: checked, onChanged: (_) => state._toggle(track)),
          _PlayButton(
            track: track,
            onPlay: widget.onPlay,
            playingState: widget.playingState,
          ),
        ],
      ),
      title: Text(track.title, maxLines: 2),
      subtitle: Text(
        '${track.artistNames}\n${track.labelName}',
        maxLines: 2,
        style: theme.textTheme.bodySmall,
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _KeyChip(track: track),
              const SizedBox(height: 4),
              Text(
                '${track.bpm ?? '-'} BPM',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
          _CopyButton(track: track),
          _DownloadButton(
            track: track,
            onDownload: widget.onDownload,
            statusFor: widget.statusFor,
            historyMark: widget.historyMarkFor?.call(track) ?? HistoryMark.none,
          ),
        ],
      ),
    );
  }
}

class _KeyChip extends StatelessWidget {
  const _KeyChip({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) => CamelotChip(
    number: track.key?.camelotNumber,
    letter: track.key?.camelotLetter,
  );
}

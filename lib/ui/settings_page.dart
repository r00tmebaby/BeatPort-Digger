/// Download preferences.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../engine/download.dart';
import '../engine/ffmpeg.dart';
// Aliased: the catalog's Key is a musical key and would collide with the
// widget Key from material.dart.
import '../engine/models.dart' as models;
import '../engine/naming.dart';
import '../state/downloads.dart';
import '../state/player.dart';
import 'widgets/track_table.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _resolvedPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final queue = context.read<DownloadQueue>();
      await queue.checkFfmpeg();
      final path = await queue.destinationPath();
      if (mounted) setState(() => _resolvedPath = path);
    });
  }

  Future<void> _pickFolder(DownloadQueue queue) async {
    final chosen = await getDirectoryPath();
    if (chosen == null) return;
    await queue.setDestination(chosen);
    final path = await queue.destinationPath();
    if (mounted) setState(() => _resolvedPath = path);
  }

  Future<void> _resetFolder(DownloadQueue queue) async {
    await queue.setDestination(null);
    final path = await queue.destinationPath();
    if (mounted) setState(() => _resolvedPath = path);
  }

  @override
  Widget build(BuildContext context) {
    final queue = context.watch<DownloadQueue>();
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(
          title: 'Audio',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 300,
                child: DropdownButtonFormField<AudioQuality>(
                  initialValue: queue.quality,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Quality',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final quality in AudioQuality.values)
                      DropdownMenuItem(
                        value: quality,
                        child: Text(quality.label),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) queue.preferredQuality = value;
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Applies to newly queued tracks. A track your account cannot '
                'take at this quality falls back to the stream automatically.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        _Section(
          title: 'Performance',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 300,
                child: DropdownButtonFormField<int>(
                  initialValue: queue.maxConcurrent,
                  decoration: const InputDecoration(
                    labelText: 'Parallel downloads',
                    border: OutlineInputBorder(),
                  ),
                  items: const [1, 2, 4, 6, 8, 12, 16]
                      .map(
                        (n) => DropdownMenuItem(
                          value: n,
                          child: Text('$n track${n == 1 ? '' : 's'} at once'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) queue.maxConcurrent = value;
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Each track also fetches up to $segmentWindow stream segments '
                'at once, so the connection count is roughly '
                '${queue.maxConcurrent * segmentWindow} at this setting. '
                'Lower it if downloads start failing.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        _Section(
          title: 'Location',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _resolvedPath ?? 'Resolving...',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => _pickFolder(queue),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Change'),
                  ),
                  if (queue.destinationOverride != null) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => _resetFolder(queue),
                      child: const Text('Reset'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                queue.destinationOverride == null
                    ? 'Default location. Files are named '
                          '"Artists - Title (Mix)".'
                    : 'Custom location.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        _Section(
          title: 'Preview',
          child: _PreviewSetting(),
        ),
        _Section(
          title: 'Appearance',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: queue.colourByStatus,
                onChanged: (value) => queue.statusColours = value,
                title: const Text('Colour rows by download status'),
                subtitle: const Text(
                  'Tints each track in the list so its state is visible '
                  'without reading the icon.',
                ),
              ),
              if (queue.colourByStatus) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    for (final status in JobStatus.values)
                      _StatusSwatch(status: status),
                  ],
                ),
              ],
            ],
          ),
        ),
        _Section(
          title: 'Download history',
          child: _HistorySetting(queue: queue),
        ),
        _Section(
          title: 'Organisation',
          child: _OrganisationSetting(queue: queue),
        ),
        _Section(
          title: 'ffmpeg',
          child: const _FfmpegSetting(),
        ),
      ],
    );
  }
}

/// A representative track, so the path preview shows real substitutions.
const models.Track _sampleTrack = models.Track(
  id: 12345678,
  name: 'Strobe',
  mixName: 'Extended Mix',
  bpm: 127,
  isrc: 'GBABC1234567',
  newReleaseDate: '2026-03-14',
  key: models.Key(name: 'A Minor', camelotNumber: 8, camelotLetter: 'A'),
  genre: models.Named(name: 'Melodic House & Techno'),
  subGenre: models.Named(name: 'Melodic Techno'),
  artists: [models.Named(name: 'deadmau5')],
  labelName: 'mau5trap',
);

/// Folder and file name layout, with a preview of the result.
class _OrganisationSetting extends StatefulWidget {
  const _OrganisationSetting({required this.queue});

  final DownloadQueue queue;

  @override
  State<_OrganisationSetting> createState() => _OrganisationSettingState();
}

class _OrganisationSettingState extends State<_OrganisationSetting> {
  late final TextEditingController _folder;
  late final TextEditingController _file;

  @override
  void initState() {
    super.initState();
    _folder = TextEditingController(text: widget.queue.folderTemplate);
    _file = TextEditingController(text: widget.queue.fileTemplate);
  }

  @override
  void dispose() {
    _folder.dispose();
    _file.dispose();
    super.dispose();
  }

  String get _preview {
    final segments = folderSegments(_folder.text, _sampleTrack);
    final name = sanitizeSegment(
      renderTemplate(_file.text, templateValues(_sampleTrack)),
    );
    return [...segments, '$name.flac'].join(' / ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final queue = widget.queue;
    // A preset the current template matches, so the dropdown reflects reality
    // after a custom edit rather than showing a stale selection.
    final matching = folderPresets.entries
        .where((entry) => entry.value == _folder.text)
        .map((entry) => entry.key)
        .firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 340,
          child: DropdownButtonFormField<String>(
            key: ValueKey(matching),
            initialValue: matching,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Folder layout',
              border: OutlineInputBorder(),
            ),
            hint: const Text('Custom'),
            items: [
              for (final entry in folderPresets.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.key)),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _folder.text = folderPresets[value]!);
              queue.folders = _folder.text;
            },
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _folder,
          decoration: const InputDecoration(
            labelText: 'Folder template',
            helperText: 'Use / to nest. Leave empty for one flat folder.',
            border: OutlineInputBorder(),
          ),
          onChanged: (value) => setState(() => queue.folders = value),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _file,
          decoration: const InputDecoration(
            labelText: 'File name template',
            border: OutlineInputBorder(),
          ),
          onChanged: (value) => setState(() => queue.files = value),
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Example', style: theme.textTheme.labelSmall),
              const SizedBox(height: 4),
              SelectableText(
                _preview,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFeatures: const [],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text('Available fields', style: theme.textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final entry in templateFields.entries)
              Tooltip(
                message: entry.value,
                child: ActionChip(
                  label: Text('{${entry.key}}'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    // Append to the folder template, the field most often
                    // being adjusted.
                    setState(() {
                      final base = _folder.text;
                      _folder.text = base.isEmpty
                          ? '{${entry.key}}'
                          : '$base/{${entry.key}}';
                    });
                    queue.folders = _folder.text;
                  },
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'A track missing a value gets an "$unknownValue" folder rather than '
          'being dropped into the parent.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Preview length and the cache it fills.
class _PreviewSetting extends StatefulWidget {
  @override
  State<_PreviewSetting> createState() => _PreviewSettingState();
}

class _PreviewSettingState extends State<_PreviewSetting> {
  int? _size;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final size = await context.read<PreviewPlayer>().cacheSize();
    if (mounted) setState(() => _size = size);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PreviewPlayer>();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 300,
          child: DropdownButtonFormField<int>(
            key: ValueKey(player.previewSegments),
            initialValue: player.previewSegments ?? 0,
            decoration: const InputDecoration(
              labelText: 'Preview length',
              border: OutlineInputBorder(),
            ),
            // Segments are roughly five seconds each.
            items: const [
              DropdownMenuItem(value: 0, child: Text('Whole track')),
              DropdownMenuItem(value: 6, child: Text('About 30 seconds')),
              DropdownMenuItem(value: 12, child: Text('About 1 minute')),
              DropdownMenuItem(value: 24, child: Text('About 2 minutes')),
            ],
            onChanged: (value) {
              setState(() {
                player.previewSegments = (value == null || value == 0)
                    ? null
                    : value;
              });
            },
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Previews are decrypted to disk and cached, so playing a track again '
          'is instant. A shorter preview starts sooner on a slow connection.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                _size == null
                    ? 'Measuring cache...'
                    : 'Cached previews: ${_mb(_size!)}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            OutlinedButton.icon(
              onPressed: _size == null || _size == 0
                  ? null
                  : () async {
                      await context.read<PreviewPlayer>().clearCache();
                      await _refresh();
                    },
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Clear cache'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Download history summary and cleanup.
class _HistorySetting extends StatelessWidget {
  const _HistorySetting({required this.queue});

  final DownloadQueue queue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = queue.historyCount;
    final missing = queue.missingCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          total == 0
              ? 'Nothing downloaded yet.'
              : '$total track${total == 1 ? '' : 's'} downloaded'
                    '${missing > 0 ? ', $missing missing from disk' : ''}.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 6),
        Text(
          'Already-downloaded tracks show a tick in search results, so a batch '
          'resumed across sessions does not start over. Re-downloading is still '
          'allowed.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (total > 0) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              if (missing > 0)
                OutlinedButton.icon(
                  onPressed: queue.removeMissingHistory,
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: Text('Remove $missing missing'),
                ),
              TextButton.icon(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Clear download history?'),
                      content: const Text(
                        'This only forgets the record. It does not delete any '
                        'downloaded files.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) await queue.clearHistory();
                },
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Clear history'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// One entry in the status colour legend.
class _StatusSwatch extends StatelessWidget {
  const _StatusSwatch({required this.status});

  final JobStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour =
        statusColor(status, theme.colorScheme, theme.brightness) ??
        theme.colorScheme.surfaceContainerHighest;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colour,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.5)),
      ),
      child: Text(statusLabel(status), style: theme.textTheme.bodySmall),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

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
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

/// ffmpeg status, with the option to fetch a verified build.
class _FfmpegSetting extends StatelessWidget {
  const _FfmpegSetting();

  @override
  Widget build(BuildContext context) {
    final queue = context.watch<DownloadQueue>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = queue.installProgress;

    if (!queue.ffmpegChecked) {
      return Text('Checking...', style: theme.textTheme.bodySmall);
    }

    if (queue.ffmpegReady) {
      return Row(
        children: [
          Icon(Icons.check_circle, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Installed. Stream downloads are rewrapped as .m4a.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                queue.canInstallFfmpeg
                    ? 'Not installed. Stream downloads are saved as .aac, which '
                          'plays fine but is not rewrapped as .m4a.'
                    : 'Not found on your PATH, and no verified build is '
                          'available for this platform. Stream downloads are '
                          'saved as .aac.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (queue.canInstallFfmpeg && !queue.installing) ...[
              const SizedBox(width: 12),
              FilledButton.tonal(
                onPressed: () => context.read<DownloadQueue>().installFfmpeg(),
                child: const Text('Install'),
              ),
            ],
          ],
        ),
        if (queue.installing) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value:
                progress?.stage == InstallStage.downloading &&
                    (progress?.total ?? 0) > 0
                ? progress!.fraction
                : null,
          ),
          const SizedBox(height: 6),
          Text(
            switch (progress?.stage) {
              InstallStage.downloading =>
                'Downloading ${_mb(progress!.received)} of '
                    '${_mb(progress.total)}',
              InstallStage.verifying => 'Verifying checksum...',
              InstallStage.extracting => 'Extracting...',
              InstallStage.done => 'Installed.',
              null => 'Starting...',
            },
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (queue.installError != null) ...[
          const SizedBox(height: 8),
          Text(
            queue.installError!,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ],
        if (!Platform.isWindows && !queue.canInstallFfmpeg) ...[
          const SizedBox(height: 8),
          Text(
            'Install it with your package manager, then restart the app.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// Camelot wheel and harmonic crate building.
///
/// Picking a key shows the codes that mix with it, and pulls tracks in those
/// keys so a set can be assembled from compatible material.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../engine/catalog.dart';
import '../engine/models.dart';
import '../state/downloads.dart';
import '../state/player.dart';
import '../state/session.dart';
import 'widgets/camelot.dart';
import 'widgets/track_table.dart';

/// A readable key name per Camelot code, for display only.
///
/// Filtering does not use these. The catalog stores enharmonic spellings as
/// separate keys, so a code can mean two different key ids and matching on one
/// name would miss every track filed under the other. The ids come from
/// [Catalog.keyIdsByCamelot] instead.
const Map<String, String> camelotToKeyName = {
  '1A': 'Ab Minor',
  '1B': 'B Major',
  '2A': 'Eb Minor',
  '2B': 'F# Major',
  '3A': 'Bb Minor',
  '3B': 'Db Major',
  '4A': 'F Minor',
  '4B': 'Ab Major',
  '5A': 'C Minor',
  '5B': 'Eb Major',
  '6A': 'G Minor',
  '6B': 'Bb Major',
  '7A': 'D Minor',
  '7B': 'F Major',
  '8A': 'A Minor',
  '8B': 'C Major',
  '9A': 'E Minor',
  '9B': 'G Major',
  '10A': 'B Minor',
  '10B': 'D Major',
  '11A': 'F# Minor',
  '11B': 'A Major',
  '12A': 'Db Minor',
  '12B': 'E Major',
};

/// Camelot codes that mix harmonically with [code]: same key, +/-1, relative.
List<String> harmonicNeighbours(String code) {
  final match = RegExp(r'^(\d{1,2})([AB])$').firstMatch(code.toUpperCase());
  if (match == null) return const [];
  final number = int.parse(match.group(1)!);
  if (number < 1 || number > 12) return const [];
  final letter = match.group(2)!;
  final up = number % 12 + 1;
  final down = (number - 2) % 12 + 1;
  final opposite = letter == 'A' ? 'B' : 'A';
  return ['$number$letter', '$up$letter', '$down$letter', '$number$opposite'];
}

class HarmonicPage extends StatefulWidget {
  const HarmonicPage({super.key});

  @override
  State<HarmonicPage> createState() => _HarmonicPageState();
}

class _HarmonicPageState extends State<HarmonicPage> {
  String _selected = '8A';
  Genre? _genre;
  final _bpmLow = TextEditingController();
  final _bpmHigh = TextEditingController();

  List<Track> _results = const [];
  final List<Track> _crate = [];
  bool _loading = false;
  bool _searched = false;
  String? _error;

  @override
  void dispose() {
    _bpmLow.dispose();
    _bpmHigh.dispose();
    super.dispose();
  }

  Future<void> _findCompatible(Session session) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Every id behind each compatible code, both enharmonic spellings
      // included.
      final grouped = await session.catalog.keyIdsByCamelot();
      final ids = <int>[
        for (final code in harmonicNeighbours(_selected)) ...?grouped[code],
      ];
      if (ids.isEmpty) {
        if (mounted) {
          setState(() {
            _error = 'Could not resolve key ids for $_selected.';
            _results = const [];
            _searched = true;
          });
        }
        return;
      }

      final low = _bpmLow.text.trim();
      final high = _bpmHigh.text.trim();

      final query = TrackQuery(
        genreId: _genre?.id == null ? null : [_genre!.id!],
        keyId: ids,
        bpm: (low.isEmpty && high.isEmpty) ? null : '$low:$high',
        orderBy: '-publish_date',
        perPage: 100,
      );
      final found = await session.catalog
          .iterTracks(query, limit: 100)
          .toList();
      if (!mounted) return;
      setState(() {
        _results = found;
        _searched = true;
      });
    } on Exception catch (exception) {
      if (mounted) setState(() => _error = '$exception');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final theme = Theme.of(context);
    final neighbours = harmonicNeighbours(_selected);
    final narrow = MediaQuery.sizeOf(context).width < 600;

    // Laid out like Browse: every control sits at the top and the results take
    // the rest of the window. On a phone the wheel and filters move into a
    // bottom sheet behind a compact key bar, so the list keeps the screen.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (narrow)
          _phoneBar(session, theme)
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
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
                        key: ValueKey(_genre?.id),
                        initialValue: _genre,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Genre',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem<Genre?>(
                            child: Text('Any genre'),
                          ),
                          ...session.genres.map(
                            (g) => DropdownMenuItem<Genre?>(
                              value: g,
                              child: Text(
                                g.name ?? '',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (value) => setState(() => _genre = value),
                      ),
                    ),
                    SizedBox(
                      width: 96,
                      child: TextField(
                        controller: _bpmLow,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) =>
                            _loading ? null : _findCompatible(session),
                        decoration: const InputDecoration(
                          labelText: 'BPM min',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 96,
                      child: TextField(
                        controller: _bpmHigh,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) =>
                            _loading ? null : _findCompatible(session),
                        decoration: const InputDecoration(
                          labelText: 'BPM max',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _loading
                          ? null
                          : () => _findCompatible(session),
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: const Text('Find compatible'),
                    ),
                    Text(
                      'Mixing out of $_selected '
                      '(${camelotToKeyName[_selected] ?? ''})',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // The wheel is the key picker; compatible keys are highlighted.
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var n = 1; n <= 12; n++)
                      for (final letter in ['A', 'B'])
                        _KeyButton(
                          code: '$n$letter',
                          selected: '$n$letter' == _selected,
                          compatible: neighbours.contains('$n$letter'),
                          onTap: () => setState(() => _selected = '$n$letter'),
                        ),
                  ],
                ),
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _results.isNotEmpty
              ? Consumer2<DownloadQueue, PreviewPlayer>(
                  builder: (context, queue, player, _) {
                    return TrackTable(
                      tracks: _results,
                      onTap: (track) {
                        if (_crate.contains(track)) return;
                        setState(() => _crate.add(track));
                      },
                      onDownload: queue.enqueue,
                      statusFor: (track) => queue.jobFor(track)?.status,
                      onPlay: (track) {
                        // Autoplay steps through the compatible tracks on
                        // screen once this one finishes.
                        player.setUpNext(_results);
                        player.toggle(track);
                      },
                      playingState: (track) => playbackStateFor(player, track),
                      colourByStatus: queue.colourByStatus,
                    );
                  },
                )
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _searched
                          ? 'No tracks came back in those keys. Try widening '
                                'the BPM range or clearing the genre.'
                          : 'Pick a key on the wheel, then find compatible '
                                'tracks. Tap a row to add it to the crate.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
        ),
        if (_crate.isNotEmpty) _crateBar(theme),
      ],
    );
  }

  /// Phone layout: a single bar showing the chosen key and opening the wheel
  /// and filters in a bottom sheet, plus a Find action.
  Widget _phoneBar(Session session, ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _openKeyPicker(session),
            icon: const Icon(Icons.piano, size: 18),
            label: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Key $_selected · ${camelotToKeyName[_selected] ?? ''}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _loading ? null : () => _findCompatible(session),
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: const Text('Find'),
        ),
      ],
    ),
  );

  /// The Camelot wheel and filters in a bottom sheet, the phone's key picker.
  Future<void> _openKeyPicker(Session session) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final media = MediaQuery.of(sheetContext);
        return StatefulBuilder(
          builder: (sheetContext, setSheet) {
            final theme = Theme.of(sheetContext);
            final neighbours = harmonicNeighbours(_selected);

            Widget bpmField(TextEditingController controller, String label) =>
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: label,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                );

            return Padding(
              padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    0,
                    16,
                    24 + media.viewPadding.bottom,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Key & filters',
                            style: theme.textTheme.titleMedium,
                          ),
                          const Spacer(),
                          Text(
                            '$_selected · ${camelotToKeyName[_selected] ?? ''}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // The wheel is the key picker; compatible keys highlight.
                      Center(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          alignment: WrapAlignment.center,
                          children: [
                            for (var n = 1; n <= 12; n++)
                              for (final letter in ['A', 'B'])
                                _KeyButton(
                                  code: '$n$letter',
                                  selected: '$n$letter' == _selected,
                                  compatible: neighbours.contains('$n$letter'),
                                  onTap: () {
                                    setState(() => _selected = '$n$letter');
                                    setSheet(() {});
                                  },
                                ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<Genre?>(
                        key: ValueKey(_genre?.id),
                        initialValue: _genre,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Genre',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem<Genre?>(
                            child: Text('Any genre'),
                          ),
                          ...session.genres.map(
                            (g) => DropdownMenuItem<Genre?>(
                              value: g,
                              child: Text(
                                g.name ?? '',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          setState(() => _genre = value);
                          setSheet(() {});
                        },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(child: bpmField(_bpmLow, 'BPM min')),
                          const SizedBox(width: 12),
                          Expanded(child: bpmField(_bpmHigh, 'BPM max')),
                        ],
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            _findCompatible(session);
                          },
                          icon: const Icon(Icons.auto_awesome, size: 18),
                          label: const Text('Find compatible'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// A compact summary of the crate, so it does not consume list space.
  Widget _crateBar(ThemeData theme) => Material(
    color: theme.colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Text(
            'Crate (${_crate.length})',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: _showCrate, child: const Text('View')),
          const Spacer(),
          Consumer<DownloadQueue>(
            builder: (context, queue, _) => FilledButton.tonalIcon(
              onPressed: () {
                final added = queue.enqueueAll(_crate);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Queued $added tracks.')),
                );
              },
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Download crate'),
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: () => setState(_crate.clear),
            icon: const Icon(Icons.clear_all, size: 18),
            label: const Text('Clear'),
          ),
        ],
      ),
    ),
  );

  void _showCrate() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => ListView(
          shrinkWrap: true,
          children: [
            for (final track in List.of(_crate))
              ListTile(
                dense: true,
                leading: CamelotChip(
                  number: track.key?.camelotNumber,
                  letter: track.key?.camelotLetter,
                ),
                title: Text(track.title),
                subtitle: Text(track.artistNames),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () {
                    setState(() => _crate.remove(track));
                    setSheetState(() {});
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({
    required this.code,
    required this.selected,
    required this.compatible,
    required this.onTap,
  });

  final String code;
  final bool selected;
  final bool compatible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final match = RegExp(r'^(\d{1,2})([AB])$').firstMatch(code);
    final number = match == null ? null : int.parse(match.group(1)!);
    final letter = match?.group(2);

    final wheel =
        camelotColor(number, letter, theme.brightness) ??
        theme.colorScheme.surfaceContainerHighest;

    // Keys that are neither selected nor compatible are muted rather than
    // recoloured, so the wheel still reads as a wheel while the four usable
    // keys stand out.
    final background = (selected || compatible)
        ? wheel
        : Color.alphaBlend(
            theme.colorScheme.surface.withValues(alpha: 0.78),
            wheel,
          );
    final foreground = camelotForeground(background);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 46,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(6),
          border: selected
              ? Border.all(color: theme.colorScheme.onSurface, width: 2.5)
              : null,
        ),
        child: Text(
          code,
          style: TextStyle(
            color: foreground,
            fontWeight: selected ? FontWeight.bold : FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

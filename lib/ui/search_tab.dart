/// Catalog search by filter.
///
/// Laid out with progressive disclosure: the fields most often typed into are
/// always visible, and the rest collapse behind a count so the header stays
/// short and the results keep the window.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../engine/catalog.dart';
import '../engine/debouncer.dart';
import '../engine/errors.dart';
import '../engine/models.dart';
import '../engine/request_gate.dart';
import '../state/downloads.dart';
import '../state/player.dart';
import '../state/session.dart';
import 'widgets/track_table.dart';

/// Human-readable summary of the filters a query actually carried.
///
/// Built from the query object rather than the form controls, so a control
/// that has drifted out of sync cannot misreport what was searched.
List<String> describeQuery(TrackQuery query, Genre? genre, Named? subGenre) {
  final parts = <String>[];
  if (query.genreId != null && query.genreId!.isNotEmpty) {
    parts.add('Genre: ${genre?.name ?? query.genreId!.join(', ')}');
  }
  if (query.subGenreId != null && query.subGenreId!.isNotEmpty) {
    parts.add('Sub-genre: ${subGenre?.name ?? query.subGenreId!.join(', ')}');
  }
  if (query.bpm != null) parts.add('BPM: ${query.bpm}');
  if (query.name != null) parts.add('Title: ${query.name}');
  if (query.artistName != null) parts.add('Artist: ${query.artistName}');
  if (query.labelName != null) parts.add('Label: ${query.labelName}');
  if (query.isHype == true) parts.add('Hype');
  if (query.isClassic == true) parts.add('Classic');
  if (query.isExplicit == true) parts.add('Explicit');
  return parts;
}

String _isoDay(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

class SearchTab extends StatefulWidget {
  const SearchTab({super.key});

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final _name = TextEditingController();
  final _artist = TextEditingController();
  final _label = TextEditingController();
  final _bpmLow = TextEditingController();
  final _bpmHigh = TextEditingController();

  bool _showAdvanced = false;

  /// Track flags to require. These are real server filters (unlike exclusive,
  /// dj-edit and pre-order, which the API ignores), so they narrow across every
  /// page rather than only the loaded one.
  final Set<String> _flags = {};

  static const _flagLabels = ['Hype', 'Classic', 'Explicit'];

  /// Client-side "exclusive only", narrowing the loaded pages.
  ///
  /// Beatport has no server filter for exclusive, but exclusives are common
  /// enough (~1 in 7) that filtering what is already loaded still shows plenty,
  /// unlike the rarer flags that would come back empty.
  bool _exclusiveOnly = false;

  /// The results actually shown, after the client-side exclusive filter.
  List<Track> get _shown =>
      _exclusiveOnly ? _results.where((t) => t.isExclusive).toList() : _results;

  Genre? _genre;
  Named? _subGenre;
  List<Named> _subGenres = const [];
  String _orderBy = '-publish_date';
  int _perPage = 100;

  List<Track> _results = const [];
  bool _loading = false;
  String? _error;
  bool _searched = false;
  Set<int> _selected = {};
  List<String> _activeFilters = const [];

  // Paging. The API reports the true total but refuses an offset past its
  // result window, so the reachable page count is capped separately.
  int _page = 1;
  int _totalCount = 0;
  bool _hasNext = false;

  /// Tracks seen across every page of the current search, so a selection made
  /// on an earlier page can still be resolved to a Track when downloaded.
  final Map<int, Track> _seenById = {};

  int get _totalPages {
    final reachable = _totalCount < resultWindow ? _totalCount : resultWindow;
    if (reachable == 0) return 0;
    return (reachable + _perPage - 1) ~/ _perPage;
  }

  /// Popularity rank per track id, captured from the order the API returned.
  ///
  /// Beatport sorts by plays and downloads but never serves the counts, so
  /// position in the sorted result is the only measure available. Captured at
  /// search time because sorting the table locally would otherwise destroy it.
  Map<int, int> _rank = const {};
  String? _rankLabel;

  DateTime _from = DateTime(DateTime.now().year, 1, 1);
  DateTime _to = DateTime.now();

  final _debounce = Debouncer();

  /// Ensures only the latest search applies its result, so overlapping
  /// auto-searches cannot land out of order and show a superseded query.
  final _gate = RequestGate();

  @override
  void dispose() {
    _debounce.dispose();
    _name.dispose();
    _artist.dispose();
    _label.dispose();
    _bpmLow.dispose();
    _bpmHigh.dispose();
    super.dispose();
  }

  /// A deliberate choice (dropdown, chip): search now.
  void _searchNow(Session session) {
    _debounce.cancel();
    _run(session);
  }

  /// Typing: search once the keystrokes stop.
  void _searchSoon(Session session) => _debounce.run(() {
    if (mounted) _run(session);
  });

  String? _trimmed(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : value;
  }

  String? _bpmRange() {
    final low = _bpmLow.text.trim();
    final high = _bpmHigh.text.trim();
    if (low.isEmpty && high.isEmpty) return null;
    return '$low:$high';
  }

  /// Advanced filters currently set, for the collapsed section's badge.
  int get _advancedCount => [
    _genre != null,
    _subGenre != null,
    _bpmRange() != null,
    ..._flags.map((_) => true),
  ].where((set) => set).length;

  TrackQuery _query() => TrackQuery(
    genreId: _genre?.id == null ? null : [_genre!.id!],
    subGenreId: _subGenre?.id == null ? null : [_subGenre!.id!],
    bpm: _bpmRange(),
    name: _trimmed(_name),
    artistName: _trimmed(_artist),
    labelName: _trimmed(_label),
    isHype: _flags.contains('Hype') ? true : null,
    isClassic: _flags.contains('Classic') ? true : null,
    isExplicit: _flags.contains('Explicit') ? true : null,
    orderBy: _orderBy,
    perPage: _perPage,
  );

  Future<void> _pickGenre(Session session, Genre? genre) async {
    setState(() {
      _genre = genre;
      _subGenre = null;
      // Show cached sub-genres at once; fall back to a fetch if not cached.
      _subGenres = genre?.id == null
          ? const []
          : session.subGenresFor(genre!.id!) ?? const [];
    });
    _searchNow(session);
    if (genre?.id == null || _subGenres.isNotEmpty) return;
    try {
      final subs = await session.catalog.subGenres(genre!.id!);
      if (mounted) setState(() => _subGenres = subs);
    } on Exception {
      // A genre with no sub-genres is normal; leave the picker empty.
    }
  }

  /// Runs a fresh search from page one, resetting selection and paging.
  Future<void> _run(Session session) => _load(session, page: 1, fresh: true);

  /// Loads one page of the current filters.
  ///
  /// [fresh] clears the selection and per-page accumulation; paging keeps them
  /// so a selection can span pages.
  Future<void> _load(
    Session session, {
    required int page,
    bool fresh = false,
  }) async {
    final ticket = _gate.begin();
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final query = _query();
      final result = await session.catalog.tracks(query, page: page);
      // A newer search was issued while this was in flight; its result is the
      // one that matches the filters now on screen, so drop this one.
      if (!mounted || !_gate.isCurrent(ticket)) return;
      setState(() {
        _results = result.results;
        _page = page;
        _totalCount = result.count;
        // Trust the API's own next link over page arithmetic near the window.
        _hasNext = result.next != null && page < _totalPages;
        _searched = true;

        if (fresh) {
          _selected = {};
          _seenById.clear();
          _rank = {};
          _rankLabel = switch (_orderBy) {
            '-plays' => 'Plays',
            '-downloads' => 'Downloads',
            _ => null,
          };
          _activeFilters = describeQuery(query, _genre, _subGenre);
        }

        // Rank continues across pages: #101 on page two, not #1 again.
        final offset = (page - 1) * _perPage;
        for (var i = 0; i < result.results.length; i++) {
          final track = result.results[i];
          final id = track.id;
          if (id == null) continue;
          _seenById[id] = track;
          _rank[id] = offset + i + 1;
        }
      });
    } on BeatportException catch (exception) {
      if (mounted && _gate.isCurrent(ticket)) {
        setState(() => _error = exception.toString());
      }
    } on ArgumentError catch (exception) {
      if (mounted && _gate.isCurrent(ticket)) {
        setState(() => _error = exception.message.toString());
      }
    } on Exception catch (exception) {
      if (mounted && _gate.isCurrent(ticket)) {
        setState(() => _error = '$exception');
      }
    } finally {
      // Only the latest search owns the spinner; a stale one clearing it would
      // hide that a newer request is still running.
      if (mounted && _gate.isCurrent(ticket)) setState(() => _loading = false);
    }
  }

  /// Queues every track matching the current filter, paging through all of
  /// them rather than just the visible page.
  ///
  /// Reaches up to the API's 10,000-row window. Beyond that a filter needs the
  /// date-window walk, offered separately. When the client-side exclusive
  /// filter is on, the stream is narrowed here so it applies across all pages,
  /// not only the loaded one.
  Future<void> _queueAllMatching(Session session, DownloadQueue queue) async {
    Stream<Track> source = session.catalog.iterTracks(
      _query(),
      limit: resultWindow,
    );
    if (_exclusiveOnly) source = source.where((t) => t.isExclusive);

    final label = [
      if (_activeFilters.isNotEmpty) _activeFilters.join(', '),
      if (_exclusiveOnly) 'Exclusive',
    ].join(' · ');

    final added = await queue.enqueueStream(
      source,
      label: label.isEmpty ? 'All results' : label,
    );
    if (mounted) _queued(added);
  }

  void _queued(int added) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Queued $added tracks.')));
  }

  /// Queues every track matching the filter across a date range.
  ///
  /// Uses the catalog walk rather than paging: the API refuses an offset past
  /// 10,000 rows, so paging alone cannot reach a whole genre.
  Future<void> _queueEverything(Session session, DownloadQueue queue) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Queue everything matching'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _activeFilters.isEmpty
                    ? 'No filters are set, so this walks the whole catalog for '
                          'the dates below. That is a lot of tracks.'
                    : 'Filters: ${_activeFilters.join(', ')}',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('From'),
                  const SizedBox(width: 8),
                  ActionChip(
                    label: Text(_isoDay(_from)),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _from,
                        firstDate: DateTime(2005),
                        lastDate: DateTime.now(),
                      );
                      if (picked == null) return;
                      _from = picked;
                      if (_to.isBefore(_from)) _to = _from;
                      setDialogState(() {});
                    },
                  ),
                  const SizedBox(width: 12),
                  const Text('to'),
                  const SizedBox(width: 8),
                  ActionChip(
                    label: Text(_isoDay(_to)),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _to,
                        firstDate: DateTime(2005),
                        lastDate: DateTime.now(),
                      );
                      if (picked == null) return;
                      _to = picked;
                      if (_from.isAfter(_to)) _from = _to;
                      setDialogState(() {});
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Tracks download as they are found. You can stop at any time '
                'from the Downloads tab.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Queue'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;
    final added = await queue.enqueueStream(
      session.catalog.exportTracks(_query(), _from, _to),
      label: _activeFilters.isEmpty
          ? 'Whole catalog'
          : _activeFilters.join(', '),
    );
    if (mounted) _queued(added);
  }

  /// How many filters are active behind the Filters button, for its badge.
  int get _filterCount {
    var count = 0;
    if (_trimmed(_artist) != null) count++;
    if (_trimmed(_label) != null) count++;
    if (_genre != null) count++;
    if (_subGenre != null) count++;
    if (_bpmRange() != null) count++;
    count += _flags.length;
    if (_exclusiveOnly) count++;
    return count;
  }

  /// The active filters as removable chips, built from the query state so each
  /// knows how to clear itself. Shown under the search field on a phone.
  List<Widget> _activeChips(Session session) {
    final chips = <Widget>[];
    void add(String label, VoidCallback onClear) => chips.add(
      InputChip(
        label: Text(label),
        onDeleted: onClear,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );

    final artist = _trimmed(_artist);
    if (artist != null) {
      add('Artist: $artist', () {
        _artist.clear();
        setState(() {});
        _searchNow(session);
      });
    }
    final label = _trimmed(_label);
    if (label != null) {
      add('Label: $label', () {
        _label.clear();
        setState(() {});
        _searchNow(session);
      });
    }
    if (_genre != null) {
      add('Genre: ${_genre!.name ?? ''}', () {
        setState(() {
          _genre = null;
          _subGenre = null;
          _subGenres = const [];
        });
        _searchNow(session);
      });
    }
    if (_subGenre != null) {
      add('Sub-genre: ${_subGenre!.name ?? ''}', () {
        setState(() => _subGenre = null);
        _searchNow(session);
      });
    }
    if (_bpmRange() != null) {
      add('BPM ${_bpmLow.text.trim()}-${_bpmHigh.text.trim()}', () {
        _bpmLow.clear();
        _bpmHigh.clear();
        setState(() {});
        _searchNow(session);
      });
    }
    for (final flag in _flags.toList()) {
      add(flag, () {
        setState(() => _flags.remove(flag));
        _searchNow(session);
      });
    }
    if (_exclusiveOnly) {
      add('Exclusive', () => setState(() => _exclusiveOnly = false));
    }
    return chips;
  }

  /// Phone layout: a pinned search field, a single Filters button opening a
  /// bottom sheet, and the active filters as removable chips below.
  List<Widget> _phoneControls(Session session) {
    final chips = _activeChips(session);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _name,
                textInputAction: TextInputAction.search,
                onChanged: (_) => _searchSoon(session),
                onSubmitted: (_) => _loading ? null : _searchNow(session),
                decoration: const InputDecoration(
                  hintText: 'Search title',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Badge(
              isLabelVisible: _filterCount > 0,
              label: Text('$_filterCount'),
              child: OutlinedButton.icon(
                onPressed: () => _openFilters(session),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Filters'),
              ),
            ),
            if (_shown.isNotEmpty) _downloadsMenu(session),
          ],
        ),
      ),
      if (chips.isNotEmpty)
        // One scrolling row, never a stack: however many filters are set, the
        // list keeps its height.
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            itemCount: chips.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (_, i) => Center(child: chips[i]),
          ),
        ),
    ];
  }

  /// The download-everything options as an overflow menu, sat in the phone's
  /// top bar next to Filters so the results need no separate action row.
  Widget _downloadsMenu(Session session) {
    final capped = _totalCount >= resultWindow;
    final allLabel = _exclusiveOnly
        ? 'Download all exclusive'
        : 'Download all ${capped ? '$resultWindow+' : '$_totalCount'}';
    return PopupMenuButton<String>(
      tooltip: 'Download options',
      icon: const Icon(Icons.more_vert),
      onSelected: (value) {
        final queue = context.read<DownloadQueue>();
        switch (value) {
          case 'all':
            _queueAllMatching(session, queue);
          case 'page':
            _queued(queue.enqueueAll(_shown));
          case 'beyond':
            _queueEverything(session, queue);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'all',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download),
            title: Text(allLabel),
          ),
        ),
        PopupMenuItem(
          value: 'page',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.article_outlined),
            title: Text('Download this page (${_shown.length})'),
          ),
        ),
        if (capped)
          const PopupMenuItem(
            value: 'beyond',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.travel_explore),
              title: Text('Reach beyond 10,000...'),
              subtitle: Text('Walks the catalog by date window'),
            ),
          ),
      ],
    );
  }

  /// Wide layout: the full inline search form, unchanged from the desktop
  /// design, with the flag chips shown beneath it.
  List<Widget> _wideControls(Session session) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: _Header(
          session: session,
          name: _name,
          artist: _artist,
          label: _label,
          loading: _loading,
          showAdvanced: _showAdvanced,
          advancedCount: _advancedCount,
          onToggleAdvanced: () =>
              setState(() => _showAdvanced = !_showAdvanced),
          genre: _genre,
          subGenre: _subGenre,
          subGenres: _subGenres,
          bpmLow: _bpmLow,
          bpmHigh: _bpmHigh,
          orderBy: _orderBy,
          perPage: _perPage,
          onGenre: (genre) => _pickGenre(session, genre),
          onSubGenre: (sub) {
            setState(() => _subGenre = sub);
            _searchNow(session);
          },
          onOrderBy: (value) {
            setState(() => _orderBy = value);
            _searchNow(session);
          },
          onPerPage: (value) {
            setState(() => _perPage = value);
            _searchNow(session);
          },
          onChanged: () => _searchSoon(session),
          onRun: () => _searchNow(session),
        ),
      ),
      if (_activeFilters.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Showing:', style: Theme.of(context).textTheme.bodySmall),
              for (final filter in _activeFilters)
                Chip(
                  label: Text(filter),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ),
      // Real server-side flag filters, so they narrow every page, not just the
      // loaded one. Only the three the API honours are offered.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Only show:', style: Theme.of(context).textTheme.bodySmall),
            for (final flag in _flagLabels)
              FilterChip(
                label: Text(flag),
                selected: _flags.contains(flag),
                visualDensity: VisualDensity.compact,
                onSelected: (on) {
                  setState(() {
                    if (on) {
                      _flags.add(flag);
                    } else {
                      _flags.remove(flag);
                    }
                  });
                  _searchNow(session);
                },
              ),
            Tooltip(
              message:
                  'Beatport has no exclusive filter, so this narrows the '
                  'results already loaded.',
              child: FilterChip(
                avatar: _exclusiveOnly
                    ? null
                    : const Icon(Icons.filter_alt_outlined, size: 16),
                label: Text(
                  _exclusiveOnly
                      ? 'Exclusive (${_shown.length}/${_results.length})'
                      : 'Exclusive',
                ),
                selected: _exclusiveOnly,
                visualDensity: VisualDensity.compact,
                onSelected: (on) => setState(() => _exclusiveOnly = on),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// The advanced filters in a bottom sheet, the phone's single entry point for
  /// everything but the title search. Changes apply live behind the sheet.
  Future<void> _openFilters(Session session) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final media = MediaQuery.of(sheetContext);
        return StatefulBuilder(
          builder: (sheetContext, setSheet) {
            final theme = Theme.of(sheetContext);

            Widget field(TextEditingController controller, String label) =>
                TextField(
                  controller: controller,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => _searchSoon(session),
                  decoration: InputDecoration(
                    labelText: label,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                );

            return Padding(
              padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: media.size.height * 0.85,
                ),
                child: SingleChildScrollView(
                  // Add the system navigation-bar inset so the Done button clears
                  // the phone's on-screen buttons instead of hiding behind them.
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
                          Text('Filters', style: theme.textTheme.titleMedium),
                          const Spacer(),
                          TextButton(
                            onPressed: () {
                              _artist.clear();
                              _label.clear();
                              _bpmLow.clear();
                              _bpmHigh.clear();
                              setState(() {
                                _genre = null;
                                _subGenre = null;
                                _subGenres = const [];
                                _flags.clear();
                                _exclusiveOnly = false;
                                _orderBy = '-publish_date';
                                _perPage = 100;
                              });
                              setSheet(() {});
                              _searchNow(session);
                            },
                            child: const Text('Reset'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      field(_artist, 'Artist'),
                      const SizedBox(height: 12),
                      field(_label, 'Label'),
                      const SizedBox(height: 12),
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
                        onChanged: (g) async {
                          await _pickGenre(session, g);
                          setSheet(() {});
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<Named?>(
                        key: ValueKey('${_genre?.id}:${_subGenre?.id}'),
                        initialValue: _subGenre,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Sub-genre',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem<Named?>(
                            child: Text('Any sub-genre'),
                          ),
                          ..._subGenres.map(
                            (s) => DropdownMenuItem<Named?>(
                              value: s,
                              child: Text(
                                s.name ?? '',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: _subGenres.isEmpty
                            ? null
                            : (s) {
                                setState(() => _subGenre = s);
                                setSheet(() {});
                                _searchNow(session);
                              },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(child: field(_bpmLow, 'BPM min')),
                          const SizedBox(width: 12),
                          Expanded(child: field(_bpmHigh, 'BPM max')),
                        ],
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        key: ValueKey(_orderBy),
                        initialValue: _orderBy,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Sort by',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: '-publish_date',
                            child: Text('Newest first'),
                          ),
                          DropdownMenuItem(
                            value: 'publish_date',
                            child: Text('Oldest first'),
                          ),
                          DropdownMenuItem(
                            value: '-plays',
                            child: Text('Most played'),
                          ),
                          DropdownMenuItem(
                            value: '-downloads',
                            child: Text('Most downloaded'),
                          ),
                          DropdownMenuItem(value: 'name', child: Text('Title')),
                          DropdownMenuItem(value: 'bpm', child: Text('BPM')),
                        ],
                        onChanged: (value) {
                          setState(() => _orderBy = value ?? '-publish_date');
                          setSheet(() {});
                          _searchNow(session);
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        key: ValueKey(_perPage),
                        initialValue: _perPage,
                        decoration: const InputDecoration(
                          labelText: 'Per page',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [25, 50, 100, 200]
                            .map(
                              (n) =>
                                  DropdownMenuItem(value: n, child: Text('$n')),
                            )
                            .toList(),
                        onChanged: (value) {
                          setState(() => _perPage = value ?? 100);
                          setSheet(() {});
                          _searchNow(session);
                        },
                      ),
                      const SizedBox(height: 16),
                      Text('Only show', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final flag in _flagLabels)
                            FilterChip(
                              label: Text(flag),
                              selected: _flags.contains(flag),
                              onSelected: (on) {
                                setState(() {
                                  if (on) {
                                    _flags.add(flag);
                                  } else {
                                    _flags.remove(flag);
                                  }
                                });
                                setSheet(() {});
                                _searchNow(session);
                              },
                            ),
                          FilterChip(
                            avatar: _exclusiveOnly
                                ? null
                                : const Icon(
                                    Icons.filter_alt_outlined,
                                    size: 16,
                                  ),
                            label: Text(
                              _exclusiveOnly
                                  ? 'Exclusive (${_shown.length}/${_results.length})'
                                  : 'Exclusive',
                            ),
                            selected: _exclusiveOnly,
                            onSelected: (on) {
                              setState(() => _exclusiveOnly = on);
                              setSheet(() {});
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: const Text('Done'),
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

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final narrow = MediaQuery.sizeOf(context).width < 600;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (narrow) ..._phoneControls(session) else ..._wideControls(session),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _ErrorBanner(message: _error!),
          ),
        // Contextual: only meaningful once there is something to act on.
        if (_shown.isNotEmpty)
          Consumer<DownloadQueue>(
            builder: (context, queue, _) => _ActionBar(
              pageCount: _shown.length,
              totalCount: _totalCount,
              capped: _totalCount >= resultWindow,
              exclusiveActive: _exclusiveOnly,
              selectedCount: _selected.length,
              queue: queue,
              // Resolves against every page seen, so a cross-page selection
              // still downloads tracks that scrolled off with a page change.
              onDownloadSelected: () => _queued(
                queue.enqueueAll(
                  _selected.map((id) => _seenById[id]).whereType<Track>(),
                ),
              ),
              onDownloadAllMatching: () => _queueAllMatching(session, queue),
              onDownloadThisPage: () => _queued(queue.enqueueAll(_shown)),
              onQueueBeyond: () => _queueEverything(session, queue),
              onClearSelection: () => setState(() => _selected = {}),
              compact: narrow,
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _shown.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      !_searched
                          ? 'Search by title, artist or label, or open Filters '
                                'for genre, BPM and key.'
                          : _exclusiveOnly && _results.isNotEmpty
                          ? 'No exclusive tracks on this page. Try turning off '
                                'Exclusive or loading more pages.'
                          : 'No tracks matched those filters.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                )
              : Consumer2<DownloadQueue, PreviewPlayer>(
                  builder: (context, queue, player, _) {
                    return TrackTable(
                      tracks: _shown,
                      rankFor: _rankLabel == null
                          ? null
                          : (track) => _rank[track.id],
                      rankLabel: _rankLabel,
                      onDownload: queue.enqueue,
                      statusFor: (track) => queue.jobFor(track)?.status,
                      selected: _selected,
                      onSelectionChanged: (next) =>
                          setState(() => _selected = next),
                      onPlay: (track) {
                        // Autoplay steps through the tracks on screen once this
                        // one finishes.
                        player.setUpNext(_shown);
                        player.toggle(track);
                      },
                      playingState: (track) => playbackStateFor(player, track),
                      colourByStatus: queue.colourByStatus,
                      historyMarkFor: queue.historyMark,
                    );
                  },
                ),
        ),
        if (_searched && _totalCount > 0) _pager(session),
      ],
    );
  }

  /// Page navigation and the running total.
  Widget _pager(Session session) {
    final theme = Theme.of(context);
    final first = (_page - 1) * _perPage + 1;
    final last = first + _results.length - 1;
    final capped = _totalCount >= resultWindow;

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Text(
              _results.isEmpty
                  ? 'No results'
                  : 'Showing $first-$last of '
                        '${capped ? '$resultWindow+' : _totalCount}',
              style: theme.textTheme.bodySmall,
            ),
            if (capped)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Tooltip(
                  message:
                      'Beatport only serves the first $resultWindow rows of a '
                      'query. Narrow the filters to reach the rest.',
                  child: Icon(
                    Icons.info_outline,
                    size: 15,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const Spacer(),
            IconButton(
              tooltip: 'First page',
              onPressed: _loading || _page <= 1
                  ? null
                  : () => _load(session, page: 1),
              icon: const Icon(Icons.first_page),
            ),
            IconButton(
              tooltip: 'Previous page',
              onPressed: _loading || _page <= 1
                  ? null
                  : () => _load(session, page: _page - 1),
              icon: const Icon(Icons.chevron_left),
            ),
            Text(
              'Page $_page of $_totalPages',
              style: theme.textTheme.bodySmall,
            ),
            IconButton(
              tooltip: 'Next page',
              onPressed: _loading || !_hasNext
                  ? null
                  : () => _load(session, page: _page + 1),
              icon: const Icon(Icons.chevron_right),
            ),
            IconButton(
              tooltip: 'Last page',
              onPressed: _loading || !_hasNext || _totalPages <= 1
                  ? null
                  : () => _load(session, page: _totalPages),
              icon: const Icon(Icons.last_page),
            ),
          ],
        ),
      ),
    );
  }
}

/// Search fields, with the less-used filters collapsed.
class _Header extends StatelessWidget {
  const _Header({
    required this.session,
    required this.name,
    required this.artist,
    required this.label,
    required this.loading,
    required this.showAdvanced,
    required this.advancedCount,
    required this.onToggleAdvanced,
    required this.genre,
    required this.subGenre,
    required this.subGenres,
    required this.bpmLow,
    required this.bpmHigh,
    required this.orderBy,
    required this.perPage,
    required this.onGenre,
    required this.onSubGenre,
    required this.onOrderBy,
    required this.onPerPage,
    required this.onChanged,
    required this.onRun,
  });

  final Session session;
  final TextEditingController name;
  final TextEditingController artist;
  final TextEditingController label;
  final bool loading;
  final bool showAdvanced;
  final int advancedCount;
  final VoidCallback onToggleAdvanced;
  final Genre? genre;
  final Named? subGenre;
  final List<Named> subGenres;
  final TextEditingController bpmLow;
  final TextEditingController bpmHigh;
  final String orderBy;
  final int perPage;
  final ValueChanged<Genre?> onGenre;
  final ValueChanged<Named?> onSubGenre;
  final ValueChanged<String> onOrderBy;
  final ValueChanged<int> onPerPage;

  /// Called on every keystroke, for a debounced search.
  final VoidCallback onChanged;

  /// Called on Enter or the Search button, for an immediate search.
  final VoidCallback onRun;

  /// A text field that searches as you type, and at once on Enter.
  Widget _field(TextEditingController controller, String label, double width) =>
      SizedBox(
        width: width,
        child: TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          onChanged: (_) => onChanged(),
          onSubmitted: (_) => loading ? null : onRun(),
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _field(name, 'Title', 200),
            _field(artist, 'Artist', 190),
            _field(label, 'Label', 190),
            FilledButton.icon(
              onPressed: loading ? null : onRun,
              icon: const Icon(Icons.search, size: 18),
              label: const Text('Search'),
            ),
            TextButton.icon(
              onPressed: onToggleAdvanced,
              icon: Icon(
                showAdvanced ? Icons.expand_less : Icons.tune,
                size: 18,
              ),
              label: Text(
                advancedCount == 0 ? 'Filters' : 'Filters ($advancedCount)',
              ),
            ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 150),
          alignment: Alignment.topLeft,
          child: showAdvanced
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 210,
                        child: DropdownButtonFormField<Genre?>(
                          // Keyed to the value: the field takes initialValue
                          // and is otherwise uncontrolled, so without this it
                          // can show a genre the query no longer uses.
                          key: ValueKey(genre?.id),
                          initialValue: genre,
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
                          onChanged: onGenre,
                        ),
                      ),
                      SizedBox(
                        width: 190,
                        child: DropdownButtonFormField<Named?>(
                          key: ValueKey('${genre?.id}:${subGenre?.id}'),
                          initialValue: subGenre,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Sub-genre',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem<Named?>(
                              child: Text('Any sub-genre'),
                            ),
                            ...subGenres.map(
                              (s) => DropdownMenuItem<Named?>(
                                value: s,
                                child: Text(
                                  s.name ?? '',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                          onChanged: subGenres.isEmpty ? null : onSubGenre,
                        ),
                      ),
                      _field(bpmLow, 'BPM min', 96),
                      _field(bpmHigh, 'BPM max', 96),
                      SizedBox(
                        width: 180,
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(orderBy),
                          initialValue: orderBy,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Sort by',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          // Only descending popularity keys: ascending plays
                          // and downloads are unstable between requests,
                          // because thousands of tracks tie at zero.
                          items: const [
                            DropdownMenuItem(
                              value: '-publish_date',
                              child: Text('Newest first'),
                            ),
                            DropdownMenuItem(
                              value: 'publish_date',
                              child: Text('Oldest first'),
                            ),
                            DropdownMenuItem(
                              value: '-plays',
                              child: Text('Most played'),
                            ),
                            DropdownMenuItem(
                              value: '-downloads',
                              child: Text('Most downloaded'),
                            ),
                            DropdownMenuItem(
                              value: 'name',
                              child: Text('Title'),
                            ),
                            DropdownMenuItem(value: 'bpm', child: Text('BPM')),
                          ],
                          onChanged: (value) =>
                              onOrderBy(value ?? '-publish_date'),
                        ),
                      ),
                      SizedBox(
                        width: 120,
                        child: DropdownButtonFormField<int>(
                          key: ValueKey(perPage),
                          initialValue: perPage,
                          decoration: const InputDecoration(
                            labelText: 'Per page',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: const [25, 50, 100, 200]
                              .map(
                                (n) => DropdownMenuItem(
                                  value: n,
                                  child: Text('$n'),
                                ),
                              )
                              .toList(),
                          onChanged: (value) => onPerPage(value ?? 100),
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        if (!showAdvanced && advancedCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '$advancedCount filter${advancedCount == 1 ? '' : 's'} hidden',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// Bulk actions over the results, shown only when there are some.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.pageCount,
    required this.totalCount,
    required this.capped,
    required this.exclusiveActive,
    required this.selectedCount,
    required this.queue,
    required this.onDownloadSelected,
    required this.onDownloadAllMatching,
    required this.onDownloadThisPage,
    required this.onQueueBeyond,
    required this.onClearSelection,
    required this.compact,
  });

  /// Tracks on the current page.
  final int pageCount;

  /// Total matching the filter across all pages, capped at the API window.
  final int totalCount;

  /// Whether [totalCount] hit the 10,000-row window and there may be more.
  final bool capped;

  /// Whether the client-side exclusive filter is narrowing results.
  final bool exclusiveActive;

  final int selectedCount;
  final DownloadQueue queue;
  final VoidCallback onDownloadSelected;
  final VoidCallback onDownloadAllMatching;
  final VoidCallback onDownloadThisPage;
  final VoidCallback onQueueBeyond;
  final VoidCallback onClearSelection;

  /// Compact (phone) layout hides the wide "Download all" button and moves it
  /// into the overflow menu, so the bar is just the count and the menu.
  final bool compact;

  String get _allLabel {
    if (exclusiveActive) return 'Download all exclusive';
    final n = capped ? '$resultWindow+' : '$totalCount';
    return 'Download all $n';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (queue.isDiscovering) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Finding tracks - ${queue.discovered} queued so far.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            TextButton(
              onPressed: queue.cancelDiscovery,
              child: const Text('Stop'),
            ),
          ],
        ),
      );
    }

    final hasSelection = selectedCount > 0;

    // On a phone the download-all / page / beyond actions live in the top bar's
    // menu, and the track count is already shown by the pager, so this bar only
    // appears when tracks are selected.
    if (compact && !hasSelection) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
      child: Row(
        children: [
          Text(
            hasSelection
                ? '$selectedCount of $pageCount selected'
                : capped
                ? '$resultWindow+ tracks'
                : '$totalCount tracks',
            style: theme.textTheme.bodySmall,
          ),
          if (hasSelection) ...[
            const SizedBox(width: 4),
            TextButton(onPressed: onClearSelection, child: const Text('Clear')),
          ],
          const Spacer(),
          if (hasSelection)
            FilledButton.icon(
              onPressed: onDownloadSelected,
              icon: const Icon(Icons.download, size: 18),
              label: Text('Download $selectedCount'),
            )
          else
            // Primary action is the whole result set, not just the page - that
            // is what "download this genre" means.
            FilledButton.icon(
              onPressed: onDownloadAllMatching,
              icon: const Icon(Icons.download, size: 18),
              label: Text(_allLabel),
            ),
          // The overflow stays on desktop; on a phone the same options live in
          // the top bar, so a selection bar needs no menu of its own.
          if (!compact)
            PopupMenuButton<String>(
              tooltip: 'More download options',
              onSelected: (value) {
                switch (value) {
                  case 'page':
                    onDownloadThisPage();
                  case 'beyond':
                    onQueueBeyond();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'page',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.article_outlined),
                    title: Text('Download this page ($pageCount)'),
                  ),
                ),
                if (capped)
                  const PopupMenuItem(
                    value: 'beyond',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.travel_explore),
                      title: Text('Reach beyond 10,000...'),
                      subtitle: Text('Walks the catalog by date window'),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

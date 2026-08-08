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

const List<int> perPageOptions = [10, 20, 50, 100, 200, 500];

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

  final Set<String> _flags = {};

  static const _flagLabels = ['Hype', 'Classic', 'Explicit'];

  bool _exclusiveOnly = false;

  List<Track> get _shown =>
      _exclusiveOnly ? _results.where((t) => t.isExclusive).toList() : _results;

  Genre? _genre;
  Named? _subGenre;
  List<Named> _subGenres = const [];
  String _orderBy = '-publish_date';
  int _perPage = 20;

  List<Track> _results = const [];
  bool _loading = false;
  String? _error;
  bool _searched = false;
  Set<int> _selected = {};
  List<String> _activeFilters = const [];

  int _page = 1;
  int _totalCount = 0;
  bool _hasNext = false;

  final Map<int, Track> _seenById = {};

  int get _totalPages {
    final reachable = _totalCount < resultWindow ? _totalCount : resultWindow;
    if (reachable == 0) return 0;
    return (reachable + _perPage - 1) ~/ _perPage;
  }

  Map<int, int> _rank = const {};
  String? _rankLabel;

  DateTime _from = DateTime(DateTime.now().year, 1, 1);
  DateTime _to = DateTime.now();

  final _debounce = Debouncer();

  final _gate = RequestGate();

  // Memoized so rows are not re-subscribed on every keystroke rebuild. Both
  // sources live for the whole app, so the merge never goes stale.
  Listenable? _updates;
  Listenable _liveStates(DownloadQueue queue, PreviewPlayer player) =>
      _updates ??= Listenable.merge([queue, player]);

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

  void _searchNow(Session session) {
    _debounce.cancel();
    _run(session);
  }

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
      // Best-effort sub-genre fetch; leave the list empty on failure.
    }
  }

  Future<void> _run(Session session) => _load(session, page: 1, fresh: true);

  Future<void> _load(
    Session session, {
    required int page,
    bool fresh = false,
  }) async {
    // Searching during a dig used to be blocked outright. It does not need to
    // be: a walk in flight builds its own queries up front and is unaffected
    // by what the search box does afterwards.
    final ticket = _gate.begin();
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final query = _query();
      final result = await session.catalog.tracks(query, page: page);

      if (!mounted || !_gate.isCurrent(ticket)) return;
      setState(() {
        _results = result.results;
        _page = page;
        _totalCount = result.count;

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
      if (mounted && _gate.isCurrent(ticket)) setState(() => _loading = false);
    }
  }

  Future<void> _queueAllMatching(Session session, DownloadQueue queue) async {
    // Walk in large pages regardless of how the results are being displayed.
    Stream<Track> source = session.catalog.iterTracks(
      _query()..perPage = discoveryPerPage,
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
    if (mounted) _queued(added, error: queue.discoverError);
  }

  void _queued(int added, {String? error}) {
    final message = error == null
        ? 'Queued $added tracks.'
        : 'Queued $added tracks, then stopped early: $error';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: Duration(seconds: error == null ? 4 : 8),
      ),
    );
  }

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
      session.catalog.exportTracks(
        _query()..perPage = discoveryPerPage,
        _from,
        _to,
      ),
      label: _activeFilters.isEmpty
          ? 'Whole catalog'
          : _activeFilters.join(', '),
    );
    if (mounted) _queued(added, error: queue.discoverError);
  }

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
            PopupMenuButton<int>(
              tooltip: 'Per page',
              onSelected: (value) {
                setState(() => _perPage = value);
                _searchNow(session);
              },
              itemBuilder: (context) => [
                for (final n in perPageOptions)
                  PopupMenuItem(value: n, child: Text('$n / page')),
              ],
              child: Chip(
                avatar: const Icon(Icons.view_list, size: 16),
                label: Text('$_perPage/page'),
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

  Widget _downloadsMenu(Session session) {
    final capped = _totalCount >= resultWindow;
    final allLabel = _exclusiveOnly
        ? 'Queue all exclusive'
        : capped
        ? 'Queue first $resultWindow (API cap)'
        : 'Queue all $_totalCount';
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
          case 'page-first':
            _queued(queue.enqueueAllFirst(_shown));
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
            subtitle: capped
                ? const Text('Queues the first 10,000 matching rows')
                : null,
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
        PopupMenuItem(
          value: 'page-first',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.vertical_align_top),
            title: Text('Queue this page first (${_shown.length})'),
            subtitle: const Text('Prioritizes these tracks next'),
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
                                _perPage = 20;
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
                        items: perPageOptions
                            .map(
                              (n) =>
                                  DropdownMenuItem(value: n, child: Text('$n')),
                            )
                            .toList(),
                        onChanged: (value) {
                          setState(() => _perPage = value ?? 20);
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

        if (_shown.isNotEmpty)
          // The action bar only reflects the discovery banner, so it listens
          // for that rather than for the whole queue. Selecting a record means
          // job churn, which changes none of these, no longer redraws it.
          Builder(
            builder: (context) {
              context.select<DownloadQueue, ({bool on, int found})>(
                (q) => (on: q.isDiscovering, found: q.discovered),
              );
              final queue = context.read<DownloadQueue>();
              return _ActionBar(
                pageCount: _shown.length,
                totalCount: _totalCount,
                capped: _totalCount >= resultWindow,
                exclusiveActive: _exclusiveOnly,
                selectedCount: _selected.length,
                queue: queue,

                onDownloadSelected: () => _queued(
                  queue.enqueueAll(
                    _selected.map((id) => _seenById[id]).whereType<Track>(),
                  ),
                ),
                onDownloadAllMatching: () => _queueAllMatching(session, queue),
                onDownloadThisPage: () => _queued(queue.enqueueAll(_shown)),
                onDownloadThisPageFirst: () =>
                    _queued(queue.enqueueAllFirst(_shown)),
                onQueueBeyond: () => _queueEverything(session, queue),
                onClearSelection: () => setState(() => _selected = {}),
                compact: narrow,
              );
            },
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
              // Deliberately not a Consumer: the queue notifies on every job
              // transition and the player on every position tick, and either
              // used to rebuild and re-sort this whole table. The rows follow
              // both through [TrackTable.updates] instead, each repainting
              // only when its own state changed.
              : Builder(
                  builder: (context) {
                    final queue = context.read<DownloadQueue>();
                    final player = context.read<PreviewPlayer>();
                    final colourByStatus = context.select<DownloadQueue, bool>(
                      (q) => q.colourByStatus,
                    );
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
                        player.setUpNext(_shown);
                        player.toggle(track);
                      },
                      playingState: (track) => playbackStateFor(player, track),
                      colourByStatus: colourByStatus,
                      historyMarkFor: queue.historyMark,
                      updates: _liveStates(queue, player),
                    );
                  },
                ),
        ),
        if (_searched && _totalCount > 0) _pager(session),
      ],
    );
  }

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

  final VoidCallback onChanged;

  final VoidCallback onRun;

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
                items: perPageOptions
                    .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                    .toList(),
                onChanged: (value) => onPerPage(value ?? 20),
              ),
            ),
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
    required this.onDownloadThisPageFirst,
    required this.onQueueBeyond,
    required this.onClearSelection,
    required this.compact,
  });

  final int pageCount;

  final int totalCount;

  final bool capped;

  final bool exclusiveActive;

  final int selectedCount;
  final DownloadQueue queue;
  final VoidCallback onDownloadSelected;
  final VoidCallback onDownloadAllMatching;
  final VoidCallback onDownloadThisPage;
  final VoidCallback onDownloadThisPageFirst;
  final VoidCallback onQueueBeyond;
  final VoidCallback onClearSelection;

  final bool compact;

  String get _allLabel {
    if (exclusiveActive) return 'Queue all exclusive';
    if (capped) return 'Queue first $resultWindow';
    return 'Queue all $totalCount';
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
            FilledButton.icon(
              onPressed: onDownloadAllMatching,
              icon: const Icon(Icons.download, size: 18),
              label: Text(_allLabel),
            ),

          if (!compact)
            PopupMenuButton<String>(
              tooltip: 'More download options',
              onSelected: (value) {
                switch (value) {
                  case 'page':
                    onDownloadThisPage();
                  case 'page-first':
                    onDownloadThisPageFirst();
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
                PopupMenuItem(
                  value: 'page-first',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.vertical_align_top),
                    title: Text('Queue this page first ($pageCount)'),
                    subtitle: const Text('Prioritizes these tracks next'),
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

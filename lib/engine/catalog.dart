/// Catalog queries: search, filtered listings, genres, and full exports.
library;

import 'client.dart';
import 'links.dart';
import 'models.dart';

/// The search backend refuses an offset at or beyond this, with "Result window
/// is too large". It bounds one query's reachable rows, not the catalog: a
/// filter matching more than this can only be read in narrower slices.
const int resultWindow = 10000;

/// Largest page the API serves reliably. It validates per_page against the
/// result window, so anything up to [resultWindow] is accepted, but pages
/// beyond roughly this size spend too long being assembled and return 504.
const int safeMaxPerPage = 2000;

/// Bounds for dividing a query by tempo. The ceiling is far above any real
/// track so the top bucket cannot strand outliers outside every range.
const int bpmFloor = 0;
const int bpmCeiling = 1000;

/// Sort keys the API honours, each also accepted with a "-" prefix. An
/// unrecognised key is not rejected: it returns an empty page with a zero
/// count, which is indistinguishable from a filter that matched nothing.
/// Sort keys the API honours, each also accepted with a "-" prefix.
///
/// "plays" and "downloads" are the only popularity measures that exist;
/// popularity, trending, rank, sales and hype are all rejected. Only their
/// descending forms are worth offering: ascending is unstable between requests
/// because thousands of tracks tie at zero.
const Set<String> orderByFields = {
  'publish_date',
  'name',
  'bpm',
  'release_date',
  'plays',
  'downloads',
};

/// Rejects sort keys the API would answer with a silent empty result.
String validateOrderBy(String orderBy) {
  final field = orderBy.startsWith('-') ? orderBy.substring(1) : orderBy;
  if (field.isNotEmpty && !orderByFields.contains(field)) {
    final allowed = (orderByFields.toList()..sort()).join(', ');
    throw ArgumentError('unknown order_by "$orderBy"; expected one of: $allowed');
  }
  return orderBy;
}

String _isoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// Reads a bpm filter as a range, or null if it cannot be divided further.
/// An exact value such as "128" cannot be narrowed.
({int low, int high})? bpmBounds(String? bpm) {
  if (bpm == null || bpm.isEmpty) {
    return (low: bpmFloor, high: bpmCeiling);
  }
  if (!bpm.contains(':')) return null;
  final parts = bpm.split(':');
  final low = parts[0].isEmpty ? bpmFloor : int.tryParse(parts[0]);
  final high = parts[1].isEmpty ? bpmCeiling : int.tryParse(parts[1]);
  if (low == null || high == null) return null;
  return (low: low, high: high);
}

/// Filters for /catalog/tracks/.
///
/// Ranges use the API's slice syntax: "120:130", ":130", "120:",
/// "2026-01-01:2026-06-30".
///
/// Date filtering is on new_release_date. A publish_date range is accepted by
/// the API and then ignored, which silently returns the unfiltered catalog.
class TrackQuery {
  TrackQuery({
    this.genreId,
    this.subGenreId,
    this.labelId,
    this.artistId,
    this.keyName,
    this.keyId,
    this.bpm,
    this.newReleaseDate,
    this.name,
    this.artistName,
    this.labelName,
    this.isHype,
    this.isClassic,
    this.isExplicit,
    String orderBy = '-publish_date',
    this.perPage = 100,
  }) : orderBy = validateOrderBy(orderBy);

  List<int>? genreId;
  List<int>? subGenreId;
  List<int>? labelId;
  List<int>? artistId;
  List<String>? keyName;

  /// Key ids to match. Prefer this over [keyName], which cannot express more
  /// than one key: the API answers a comma-joined key_name with zero results
  /// and honours only the last of a repeated key_name.
  List<int>? keyId;
  String? bpm;
  String? newReleaseDate;

  /// Title contains. Matched as a substring.
  String? name;

  /// Artist name contains. Substring and case-insensitive, so "Beyer" matches
  /// every artist with that in their name, not one specific artist.
  String? artistName;

  /// Label name contains. Substring and case-insensitive.
  String? labelName;

  /// Restrict to Beatport Hype releases. A real server filter, unlike the
  /// exclusive/dj-edit/pre-order flags which the API ignores.
  bool? isHype;

  /// Restrict to catalogue classics.
  bool? isClassic;

  /// Restrict to explicit tracks.
  bool? isExplicit;

  String orderBy;
  int perPage;

  TrackQuery copy() => TrackQuery(
    genreId: genreId == null ? null : List.of(genreId!),
    subGenreId: subGenreId == null ? null : List.of(subGenreId!),
    labelId: labelId == null ? null : List.of(labelId!),
    artistId: artistId == null ? null : List.of(artistId!),
    keyName: keyName == null ? null : List.of(keyName!),
    keyId: keyId == null ? null : List.of(keyId!),
    bpm: bpm,
    newReleaseDate: newReleaseDate,
    name: name,
    artistName: artistName,
    labelName: labelName,
    isHype: isHype,
    isClassic: isClassic,
    isExplicit: isExplicit,
    orderBy: orderBy,
    perPage: perPage,
  );

  /// A copy restricted to a release-date window.
  TrackQuery dated(DateTime start, DateTime end) =>
      copy()..newReleaseDate = '${_isoDate(start)}:${_isoDate(end)}';

  static String? _join(List<Object>? values) =>
      (values == null || values.isEmpty) ? null : values.join(',');

  Map<String, Object?> params() => {
    'genre_id': _join(genreId),
    'sub_genre_id': _join(subGenreId),
    'label_id': _join(labelId),
    'artist_id': _join(artistId),
    'key_name': _join(keyName),
    'key_id': _join(keyId),
    'bpm': bpm,
    'new_release_date': newReleaseDate,
    'name': name,
    'artist_name': artistName,
    'label_name': labelName,
    'is_hype': isHype == true ? 'true' : null,
    'is_classic': isClassic == true ? 'true' : null,
    'is_explicit': isExplicit == true ? 'true' : null,
    'order_by': orderBy,
    'per_page': perPage,
  };
}

/// Progress reported while an export walks the catalog.
class ExportWindow {
  const ExportWindow(this.low, this.high, this.total, {this.truncated = false});

  final DateTime low;
  final DateTime high;
  final int total;

  /// Set when the window could not be divided small enough to read in one
  /// request, so paging may have dropped rows.
  final bool truncated;

  String get label =>
      low == high ? _isoDate(low) : '${_isoDate(low)} .. ${_isoDate(high)}';
}

class Catalog {
  Catalog(this.client);

  final BeatportClient client;
  List<Genre>? _genreCache;
  List<Key>? _keyCache;

  Future<List<Genre>> genres({int perPage = 100}) async {
    final payload = await client.get('/catalog/genres/', {'per_page': perPage});
    return Paginated.fromJson(payload, Genre.fromJson).results;
  }

  /// Genres, fetched once: dividing a broad export re-reads them often.
  Future<List<Genre>> allGenres() async => _genreCache ??= await genres();

  Future<List<Named>> subGenres(int genreId, {int perPage = 100}) async {
    final payload = await client.get('/catalog/genres/$genreId/sub-genres/', {
      'per_page': perPage,
    });
    return Paginated.fromJson(payload, Named.fromJson).results;
  }

  /// The HLS stream for a track, used by the downloader.
  Future<TrackStream> trackStream(int trackId) async =>
      TrackStream.fromJson(await client.get('/catalog/tracks/$trackId/stream/'));

  /// A direct download URL for a track at the requested quality.
  Future<TrackDownload> trackDownload(int trackId, String quality) async =>
      TrackDownload.fromJson(
        await client.get('/catalog/tracks/$trackId/download/', {
          'quality': quality,
        }),
      );

  /// Every track behind a link, following pagination.
  ///
  /// Labels and artists are read through the tracks endpoint rather than their
  /// own listings, which return releases and would need a second request each
  /// to reach the tracks.
  Stream<Track> linkTracks(BeatportLink link, {int limit = 100000}) async* {
    switch (link.type) {
      case LinkType.track:
        final payload = await client.get('/catalog/tracks/${link.id}/');
        yield Track.fromJson(payload);
      case LinkType.release:
        yield* _paged('/catalog/releases/${link.id}/tracks/', limit);
      case LinkType.chart:
        yield* _paged('/catalog/charts/${link.id}/tracks/', limit);
      case LinkType.playlist:
        yield* _pagedPlaylist('/catalog/playlists/${link.id}/tracks/', limit);
      case LinkType.label:
        yield* iterTracks(TrackQuery(labelId: [link.id]), limit: limit);
      case LinkType.artist:
        yield* iterTracks(TrackQuery(artistId: [link.id]), limit: limit);
    }
  }

  /// A human label for a link, for the queue to show while it resolves.
  Future<String> linkTitle(BeatportLink link) async {
    final path = switch (link.type) {
      LinkType.track => '/catalog/tracks/${link.id}/',
      LinkType.release => '/catalog/releases/${link.id}/',
      LinkType.chart => '/catalog/charts/${link.id}/',
      LinkType.playlist => '/catalog/playlists/${link.id}/',
      LinkType.label => '/catalog/labels/${link.id}/',
      LinkType.artist => '/catalog/artists/${link.id}/',
    };
    try {
      final payload = await client.get(path);
      final name = payload['name'];
      return name is String && name.isNotEmpty ? name : link.toString();
    } on Exception {
      return link.toString();
    }
  }

  Stream<Track> _paged(String path, int limit) async* {
    var page = 1;
    var seen = 0;
    while (seen < limit) {
      final payload = await client.get(path, {'page': page, 'per_page': 100});
      final result = Paginated.fromJson(payload, Track.fromJson);
      if (result.results.isEmpty) return;
      for (final track in result.results) {
        yield track;
        if (++seen >= limit) return;
      }
      if (result.next == null) return;
      page += 1;
    }
  }

  /// Playlist entries wrap the track in a positioned item.
  Stream<Track> _pagedPlaylist(String path, int limit) async* {
    var page = 1;
    var seen = 0;
    while (seen < limit) {
      final payload = await client.get(path, {'page': page, 'per_page': 100});
      final raw = payload['results'];
      if (raw is! List || raw.isEmpty) return;
      for (final entry in raw.whereType<Map<String, dynamic>>()) {
        final track = entry['track'];
        if (track is! Map<String, dynamic>) continue;
        yield Track.fromJson(track);
        if (++seen >= limit) return;
      }
      if (payload['next'] == null) return;
      page += 1;
    }
  }

  /// Every musical key the catalog knows, fetched once.
  Future<List<Key>> allKeys() async {
    final cached = _keyCache;
    if (cached != null) return cached;
    final payload = await client.get('/catalog/keys/', {'per_page': 100});
    return _keyCache = Paginated.fromJson(payload, Key.fromJson).results;
  }

  /// Key ids grouped by Camelot code.
  ///
  /// A code can carry more than one id, because the catalog stores enharmonic
  /// spellings separately: 1A is both "G# Minor" and "Ab Minor". Filtering by a
  /// single name would silently miss every track filed under the other.
  Future<Map<String, List<int>>> keyIdsByCamelot() async {
    final grouped = <String, List<int>>{};
    for (final key in await allKeys()) {
      final id = key.id;
      final code = key.camelot;
      if (id == null || code.isEmpty) continue;
      grouped.putIfAbsent(code, () => []).add(id);
    }
    return grouped;
  }

  Future<Map<String, dynamic>> search(String query) =>
      client.get('/catalog/search/', {'q': query});

  Future<List<Track>> searchTracks(String query) async {
    final payload = await search(query);
    final raw = payload['tracks'];
    if (raw is! List) return const [];
    return raw.whereType<Map<String, dynamic>>().map(Track.fromJson).toList();
  }

  Future<Paginated<Track>> tracks(TrackQuery query, {int page = 1}) async {
    final params = query.params()..['page'] = page;
    return Paginated.fromJson(
      await client.get('/catalog/tracks/', params),
      Track.fromJson,
    );
  }

  /// Number of tracks matching a filter, clamped to [resultWindow].
  Future<int> count(TrackQuery query) async {
    final params = query.params()..['per_page'] = 1;
    final payload = await client.get('/catalog/tracks/', params);
    return (payload['count'] as num?)?.toInt() ?? 0;
  }

  /// Yields up to [limit] tracks, following pagination.
  Stream<Track> iterTracks(TrackQuery query, {int limit = 500}) async* {
    var seen = 0;
    var page = 1;
    while (seen < limit) {
      final result = await tracks(query, page: page);
      if (result.results.isEmpty) return;
      for (final track in result.results) {
        yield track;
        seen += 1;
        if (seen >= limit) return;
      }
      if (result.next == null) return;
      page += 1;
    }
  }

  /// Narrows a query still too large for one request, or null if it cannot be
  /// narrowed further.
  ///
  /// Genre is tried first, since an export with no genre filter is what makes a
  /// single day overflow. Tempo is the fallback: every track carries a bpm,
  /// whereas sub-genre is set on under a tenth of them and would silently drop
  /// the rest.
  Future<List<TrackQuery>?> _divide(TrackQuery query) async {
    final hasGenre = query.genreId != null && query.genreId!.isNotEmpty;
    final hasSubGenre = query.subGenreId != null && query.subGenreId!.isNotEmpty;

    if (!hasGenre && !hasSubGenre) {
      final parts = <TrackQuery>[];
      for (final genre in await allGenres()) {
        final id = genre.id;
        if (id == null) continue;
        parts.add(query.copy()..genreId = [id]);
      }
      return parts.isEmpty ? null : parts;
    }

    final bounds = bpmBounds(query.bpm);
    if (bounds == null || bounds.high - bounds.low < 1) return null;

    final midpoint = (bounds.low + bounds.high) ~/ 2;
    return [
      query.copy()..bpm = '${bounds.low}:$midpoint',
      query.copy()..bpm = '${midpoint + 1}:${bounds.high}',
    ];
  }

  /// Reads a window whole, in one request sized to its contents.
  Future<List<Track>> _readSized(TrackQuery query, int total) async {
    final sized = query.copy()..perPage = total < 1 ? 1 : total;
    return (await tracks(sized, page: 1)).results;
  }

  /// Yields every track in one window, stopping at the reachable offset.
  Stream<Track> _pageWindow(TrackQuery query) async* {
    var page = 1;
    var offset = 0;
    while (offset < resultWindow) {
      final result = await tracks(query, page: page);
      if (result.results.isEmpty) return;
      yield* Stream.fromIterable(result.results);
      offset += result.results.length;
      if (result.next == null) return;
      page += 1;
    }
  }

  /// Reads one day, dividing it further when it exceeds a single request.
  Stream<Track> _readDay(
    TrackQuery query,
    DateTime day,
    Set<int> seen,
    void Function(ExportWindow)? onWindow,
  ) async* {
    final pending = <TrackQuery>[query.dated(day, day)];

    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      final total = await count(current);
      if (total == 0) continue;

      if (total <= safeMaxPerPage) {
        onWindow?.call(ExportWindow(day, day, total));
        for (final track in await _readSized(current, total)) {
          final id = track.id;
          if (id == null || !seen.add(id)) continue;
          yield track;
        }
        continue;
      }

      final children = await _divide(current);
      if (children != null) {
        pending.addAll(children);
        continue;
      }

      // Nothing left to divide by. Paging is the only way through and may drop
      // rows that shift between pages.
      onWindow?.call(ExportWindow(day, day, total, truncated: true));
      await for (final track in _pageWindow(current)) {
        final id = track.id;
        if (id == null || !seen.add(id)) continue;
        yield track;
      }
    }
  }

  /// Yields every track between two release dates.
  ///
  /// A date window whose matches do not fit in one page is halved until it
  /// does, so the reachable total is bounded by the catalog rather than by the
  /// result window. Reading each window in a single request also avoids paging:
  /// the sort is not stable across pages, so tied rows shift between requests
  /// and a row can be missed entirely.
  Stream<Track> exportTracks(
    TrackQuery query,
    DateTime start,
    DateTime end, {
    void Function(ExportWindow)? onWindow,
  }) async* {
    final seen = <int>{};
    final pending = <(DateTime, DateTime)>[(start, end)];

    while (pending.isNotEmpty) {
      final (low, high) = pending.removeLast();
      final window = query.dated(low, high);
      // Size the window with a one-row request. Most windows in a broad export
      // are only visited to be split, and probing cheaply keeps those visits
      // from transferring a full page that is discarded.
      final total = await count(window);
      if (total == 0) continue;

      if (total > query.perPage && low.isBefore(high)) {
        // Halve and revisit. The later half is pushed first so the earlier half
        // is popped, keeping the output chronological.
        final midpoint = low.add(Duration(days: high.difference(low).inDays ~/ 2));
        pending.add((midpoint.add(const Duration(days: 1)), high));
        pending.add((low, midpoint));
        continue;
      }

      if (total > safeMaxPerPage) {
        // A single day past one request. It cannot be split by date any
        // further, so divide it by genre or tempo instead.
        yield* _readDay(query, low, seen, onWindow);
        continue;
      }

      onWindow?.call(ExportWindow(low, high, total));
      for (final track in await _readSized(window, total)) {
        final id = track.id;
        if (id == null || !seen.add(id)) continue;
        yield track;
      }
    }
  }
}

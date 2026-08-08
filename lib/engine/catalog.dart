library;

import 'client.dart';
import 'links.dart';
import 'models.dart';

const int resultWindow = 10000;

const int safeMaxPerPage = 2000;

/// Page size for walks that fill the download queue.
///
/// The visible result page is sized for reading, and defaults to 20. Walking
/// the 10,000 row window at that size is 500 sequential requests, so every
/// extra request is another chance to trip a rate limit and end the walk
/// early. At 100 the same walk is 100 requests.
const int discoveryPerPage = 100;

const int bpmFloor = 0;
const int bpmCeiling = 1000;

const Set<String> orderByFields = {
  'publish_date',
  'name',
  'bpm',
  'release_date',
  'plays',
  'downloads',
};

String validateOrderBy(String orderBy) {
  final field = orderBy.startsWith('-') ? orderBy.substring(1) : orderBy;
  if (field.isNotEmpty && !orderByFields.contains(field)) {
    final allowed = (orderByFields.toList()..sort()).join(', ');
    throw ArgumentError(
      'unknown order_by "$orderBy"; expected one of: $allowed',
    );
  }
  return orderBy;
}

/// Renders a date the way Beatport's date-range filters expect it.
String isoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

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

  List<int>? keyId;
  String? bpm;
  String? newReleaseDate;

  String? name;

  String? artistName;

  String? labelName;

  bool? isHype;

  bool? isClassic;

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

  TrackQuery dated(DateTime start, DateTime end) =>
      copy()..newReleaseDate = '${isoDate(start)}:${isoDate(end)}';

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

class ExportWindow {
  const ExportWindow(this.low, this.high, this.total, {this.truncated = false});

  final DateTime low;
  final DateTime high;
  final int total;

  final bool truncated;

  String get label =>
      low == high ? isoDate(low) : '${isoDate(low)} .. ${isoDate(high)}';
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

  Future<List<Genre>> allGenres() async => _genreCache ??= await genres();

  Future<List<Named>> subGenres(int genreId, {int perPage = 100}) async {
    final payload = await client.get('/catalog/genres/$genreId/sub-genres/', {
      'per_page': perPage,
    });
    return Paginated.fromJson(payload, Named.fromJson).results;
  }

  Future<TrackStream> trackStream(int trackId) async => TrackStream.fromJson(
    await client.get('/catalog/tracks/$trackId/stream/'),
  );

  Future<TrackDownload> trackDownload(int trackId, String quality) async =>
      TrackDownload.fromJson(
        await client.get('/catalog/tracks/$trackId/download/', {
          'quality': quality,
        }),
      );

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

  Future<List<Key>> allKeys() async {
    final cached = _keyCache;
    if (cached != null) return cached;
    final payload = await client.get('/catalog/keys/', {'per_page': 100});
    return _keyCache = Paginated.fromJson(payload, Key.fromJson).results;
  }

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

  Future<int> count(TrackQuery query) async {
    final params = query.params()..['per_page'] = 1;
    final payload = await client.get('/catalog/tracks/', params);
    return (payload['count'] as num?)?.toInt() ?? 0;
  }

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

  Future<List<TrackQuery>?> _divide(TrackQuery query) async {
    final hasGenre = query.genreId != null && query.genreId!.isNotEmpty;
    final hasSubGenre =
        query.subGenreId != null && query.subGenreId!.isNotEmpty;

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

  Future<List<Track>> _readSized(TrackQuery query, int total) async {
    final sized = query.copy()..perPage = total < 1 ? 1 : total;
    return (await tracks(sized, page: 1)).results;
  }

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

      onWindow?.call(ExportWindow(day, day, total, truncated: true));
      await for (final track in _pageWindow(current)) {
        final id = track.id;
        if (id == null || !seen.add(id)) continue;
        yield track;
      }
    }
  }

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

      final total = await count(window);
      if (total == 0) continue;

      if (total > query.perPage && low.isBefore(high)) {
        final midpoint = low.add(
          Duration(days: high.difference(low).inDays ~/ 2),
        );
        pending.add((midpoint.add(const Duration(days: 1)), high));
        pending.add((low, midpoint));
        continue;
      }

      if (total > safeMaxPerPage) {
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

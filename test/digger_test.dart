import 'dart:convert';

import 'package:beatport_digger/engine/auth.dart';
import 'package:beatport_digger/engine/catalog.dart';
import 'package:beatport_digger/engine/client.dart';
import 'package:beatport_digger/engine/digger.dart';
import 'package:beatport_digger/engine/token.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryTokenStore implements TokenStore {
  TokenPair? stored;

  @override
  Future<TokenPair?> read() async => stored;

  @override
  Future<void> write(TokenPair token) async => stored = token;

  @override
  Future<void> clear() async => stored = null;
}

/// A catalog whose track endpoint is answered by [handler].
Catalog _catalog(
  Future<http.Response> Function(Map<String, String> params) handler,
) {
  final client = MockClient((request) => handler(request.url.queryParameters));
  final auth = Authenticator(httpClient: client, store: _MemoryTokenStore());
  auth.token = TokenPair(
    accessToken: 'test',
    expiresIn: 36000,
    issuedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
  return Catalog(
    BeatportClient(auth: auth, httpClient: client, sleep: (_) async {}),
  );
}

http.Response _page(List<int> ids, {bool exclusive = false, int? count}) =>
    http.Response(
      jsonEncode({
        'count': count ?? ids.length,
        'next': null,
        'results': [
          for (final id in ids)
            {'id': id, 'name': 'Track $id', 'exclusive': exclusive},
        ],
      }),
      200,
    );

DiggerCrate _crate(
  String id, {
  int? genreId,
  String? genreName,
  int? subGenreId,
  String? subGenreName,
  int limit = defaultCrateLimit,
  int windowDays = defaultWindowDays,
  bool isExclusive = false,
  // ignore: unused_element_parameter
}) => DiggerCrate(
  id: id,
  genreId: genreId,
  genreName: genreName,
  subGenreId: subGenreId,
  subGenreName: subGenreName,
  limit: limit,
  windowDays: windowDays,
  isExclusive: isExclusive,
);

final _today = DateTime(2026, 8, 7);

void main() {
  group('DiggerCrate', () {
    test('round-trips through JSON', () {
      const crate = DiggerCrate(
        id: 'c1',
        genreId: 6,
        genreName: 'Techno',
        subGenreId: 61,
        subGenreName: 'Peak Time',
        orderBy: '-plays',
        limit: 250,
        windowDays: 90,
        bpmLow: 124,
        bpmHigh: 132,
        isHype: true,
        isClassic: true,
        isExclusive: true,
      );

      final restored = DiggerCrate.fromJson(
        jsonDecode(jsonEncode(crate.toJson())) as Map<String, dynamic>,
      )!;

      expect(restored.id, 'c1');
      expect(restored.genreId, 6);
      expect(restored.genreName, 'Techno');
      expect(restored.subGenreId, 61);
      expect(restored.subGenreName, 'Peak Time');
      expect(restored.orderBy, '-plays');
      expect(restored.limit, 250);
      expect(restored.windowDays, 90);
      expect(restored.bpmLow, 124);
      expect(restored.bpmHigh, 132);
      expect(restored.isHype, isTrue);
      expect(restored.isClassic, isTrue);
      expect(restored.isExclusive, isTrue);
    });

    test('a record with no id is dropped', () {
      expect(DiggerCrate.fromJson({'genre_id': 1}), isNull);
      expect(DiggerCrate.fromJson({'id': ''}), isNull);
    });

    test('an unknown ordering falls back rather than throwing', () {
      final crate = DiggerCrate.fromJson({'id': 'x', 'order_by': 'nonsense'})!;
      expect(crate.orderBy, '-downloads');
      expect(crate.limit, defaultCrateLimit);
      expect(crate.windowDays, defaultWindowDays);
    });

    test('stored values out of range are clamped, not trusted', () {
      const huge = DiggerCrate(id: 'x', limit: 999999, windowDays: 999999);
      expect(huge.boundedLimit, maxCrateLimit);
      expect(huge.boundedWindowDays, maxWindowDays);

      const tiny = DiggerCrate(id: 'x', limit: 0, windowDays: -5);
      expect(tiny.boundedLimit, minCrateLimit);
      expect(tiny.boundedWindowDays, 0);
    });

    test('the query carries every filter the crate sets', () {
      const crate = DiggerCrate(
        id: 'x',
        genreId: 1,
        subGenreId: 11,
        orderBy: '-downloads',
        windowDays: 30,
        bpmLow: 120,
        bpmHigh: 130,
        isHype: true,
        isClassic: true,
      );

      final params = crate.query(today: _today).params();
      expect(params['genre_id'], '1');
      expect(params['sub_genre_id'], '11');
      expect(params['bpm'], '120:130');
      expect(params['new_release_date'], '2026-07-08:2026-08-07');
      expect(params['order_by'], '-downloads');
      expect(params['is_hype'], 'true');
      expect(params['is_classic'], 'true');
    });

    test('an all-time crate sets no date filter', () {
      const crate = DiggerCrate(id: 'x', genreId: 1, windowDays: 0);
      expect(crate.query(today: _today).params()['new_release_date'], isNull);
    });

    test('a half-open BPM range is allowed', () {
      const low = DiggerCrate(id: 'x', bpmLow: 140);
      const high = DiggerCrate(id: 'x', bpmHigh: 100);
      expect(low.query(today: _today).params()['bpm'], '140:');
      expect(high.query(today: _today).params()['bpm'], ':100');
      expect(
        const DiggerCrate(id: 'x').query(today: _today).params()['bpm'],
        isNull,
      );
    });

    test('the page size never exceeds the discovery page', () {
      expect(
        const DiggerCrate(id: 'x', limit: 1000).query(today: _today).perPage,
        discoveryPerPage,
      );
      expect(
        const DiggerCrate(id: 'x', limit: 25).query(today: _today).perPage,
        25,
      );
    });

    test('reads as a title and a filter line', () {
      const crate = DiggerCrate(
        id: 'x',
        genreName: 'Techno',
        subGenreName: 'Peak Time',
        limit: 50,
        windowDays: 7,
        bpmLow: 130,
        isExclusive: true,
      );

      expect(crate.title, 'Techno / Peak Time');
      expect(crate.subtitle, contains('most downloaded'));
      expect(crate.subtitle, contains('last 7 days'));
      expect(crate.subtitle, contains('top 50'));
      expect(crate.subtitle, contains('130- BPM'));
      expect(crate.subtitle, contains('exclusive only'));

      expect(const DiggerCrate(id: 'y').title, 'Whole catalog');
      expect(const DiggerCrate(id: 'y', genreName: 'House').title, 'House');
    });
  });

  group('Digger.dig', () {
    test('walks the bundle in order', () async {
      final asked = <String>[];
      final digger = Digger(
        _catalog((params) async {
          asked.add(params['genre_id'] ?? 'any');
          return _page([int.parse(params['genre_id'] ?? '0')]);
        }),
      );

      final tracks = await digger
          .dig([
            _crate('a', genreId: 1),
            _crate('b', genreId: 2),
            _crate('c', genreId: 3),
          ], today: _today)
          .toList();

      expect(asked, ['1', '2', '3']);
      expect(tracks.map((t) => t.id), [1, 2, 3]);
    });

    test('stops a crate at its own depth', () async {
      final digger = Digger(
        _catalog((_) async => _page(List.generate(100, (i) => i + 1))),
      );

      final tracks = await digger
          .dig([_crate('a', genreId: 1, limit: 10)], today: _today)
          .toList();

      expect(tracks, hasLength(10));
    });

    test('a failing crate is reported and the dig carries on', () async {
      final failed = <String>[];
      final digger = Digger(
        _catalog(
          (params) async => params['genre_id'] == '2'
              ? http.Response(jsonEncode({'detail': 'gone'}), 404)
              : _page([int.parse(params['genre_id']!)]),
        ),
      );

      final tracks = await digger
          .dig([
            _crate('a', genreId: 1),
            _crate('b', genreId: 2, genreName: 'Techno'),
            _crate('c', genreId: 3),
          ], today: _today, onFailure: (crate, _) => failed.add(crate.title))
          .toList();

      expect(
        tracks.map((t) => t.id),
        [1, 3],
        reason: 'one bad crate must not cost the rest of the bundle',
      );
      expect(failed, ['Techno']);
    });

    test('exclusive-only drops the rest', () async {
      final digger = Digger(
        _catalog((params) async {
          final exclusive = params['genre_id'] == '1';
          return _page([int.parse(params['genre_id']!)], exclusive: exclusive);
        }),
      );

      final tracks = await digger
          .dig([
            _crate('a', genreId: 1, isExclusive: true),
            _crate('b', genreId: 2, isExclusive: true),
          ], today: _today)
          .toList();

      expect(tracks.map((t) => t.id), [1]);
    });

    test('a crate added while digging joins the same walk', () async {
      final crates = [_crate('a', genreId: 1)];
      final seen = <int>[];

      final digger = Digger(
        _catalog((params) async => _page([int.parse(params['genre_id']!)])),
      );

      await for (final track in digger.dig(crates, today: _today)) {
        seen.add(track.id!);
        if (seen.length == 1) crates.add(_crate('b', genreId: 2));
      }

      expect(
        seen,
        [1, 2],
        reason: 'the bundle is read live so the user can keep building',
      );
    });

    test('a crate removed before its turn is skipped', () async {
      final crates = [
        _crate('a', genreId: 1),
        _crate('b', genreId: 2),
        _crate('c', genreId: 3),
      ];
      final seen = <int>[];

      final digger = Digger(
        _catalog((params) async => _page([int.parse(params['genre_id']!)])),
      );

      await for (final track in digger.dig(crates, today: _today)) {
        seen.add(track.id!);
        if (seen.length == 1) crates.removeWhere((crate) => crate.id == 'b');
      }

      expect(seen, [1, 3]);
    });

    test('reports which crate it is on', () async {
      final steps = <String>[];
      final digger = Digger(_catalog((_) async => _page(const [])));

      await digger
          .dig(
            [
              _crate('a', genreId: 1, genreName: 'House'),
              _crate('b', genreId: 2, genreName: 'Techno'),
            ],
            today: _today,
            onStep: (step) => steps.add(step.label),
          )
          .toList();

      expect(steps, ['House (1 of 2)', 'Techno (2 of 2)']);
    });

    test('an unlimited crate reaches past the 10,000 row window', () async {
      // The paged endpoint cannot see past resultWindow however many pages are
      // requested, so an unlimited crate has to go through the date-splitting
      // sweep instead. That sweep asks for counts and then reads slices.
      final windows = <String>[];
      var served = 0;

      final digger = Digger(
        _catalog((params) async {
          final range = params['new_release_date'] ?? '';
          if (params['per_page'] == '1') {
            // A count probe. Report a slice-sized batch for a single day and
            // something too big for anything wider, forcing a split.
            final parts = range.split(':');
            final single = parts.length == 2 && parts[0] == parts[1];
            return _page(const [], count: single ? 2 : 50000);
          }
          windows.add(range);
          served += 1;
          return _page([served]);
        }),
      );

      final tracks = await digger
          .dig([
            _crate('a', genreId: 1, limit: unlimitedCrateLimit, windowDays: 3),
          ], today: _today)
          .toList();

      expect(tracks, isNotEmpty);
      expect(
        windows.every((w) => w.split(':')[0] == w.split(':')[1]),
        isTrue,
        reason: 'wide windows must be split down before they are read',
      );
    });

    test('a top-N crate still uses the plain paged read', () async {
      final probes = <String?>[];
      final digger = Digger(
        _catalog((params) async {
          probes.add(params['per_page']);
          return _page([1]);
        }),
      );

      await digger
          .dig([_crate('a', genreId: 1, limit: 50)], today: _today)
          .toList();

      expect(
        probes,
        ['50'],
        reason: 'no count probe, just one page of the requested size',
      );
    });

    test('a crate can be stopped without ending the bundle', () async {
      final control = DiggerControl();
      final seen = <int>[];

      final digger = Digger(
        _catalog((params) async {
          final id = int.parse(params['genre_id']!);
          return _page(List.generate(50, (i) => id * 1000 + i));
        }),
      );

      await for (final track in digger.dig([
        _crate('a', genreId: 1, limit: 500),
        _crate('b', genreId: 2, limit: 500),
      ], today: _today, control: control)) {
        seen.add(track.id!);
        if (seen.length == 3) control.skip('a');
      }

      expect(
        seen.take(3),
        [1000, 1001, 1002],
        reason: 'the crate stops where it was told to, not at its limit',
      );
      expect(
        seen.skip(3),
        hasLength(50),
        reason: 'the next crate is unaffected',
      );
    });

    test('a crate skipped before its turn is never walked', () async {
      final asked = <String>[];
      final control = DiggerControl()..skip('b');

      final digger = Digger(
        _catalog((params) async {
          asked.add(params['genre_id']!);
          return _page([int.parse(params['genre_id']!)]);
        }),
      );

      final tracks = await digger
          .dig([
            _crate('a', genreId: 1),
            _crate('b', genreId: 2),
            _crate('c', genreId: 3),
          ], today: _today, control: control)
          .toList();

      expect(asked, ['1', '3']);
      expect(tracks.map((t) => t.id), [1, 3]);
    });

    test('an empty bundle finishes without asking for anything', () async {
      var calls = 0;
      final digger = Digger(
        _catalog((_) async {
          calls += 1;
          return _page(const []);
        }),
      );

      expect(await digger.dig([], today: _today).toList(), isEmpty);
      expect(calls, 0);
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:beatport_digger/engine/digger.dart';
import 'package:beatport_digger/engine/token.dart';
import 'package:beatport_digger/state/digger.dart';
import 'package:beatport_digger/state/downloads.dart';
import 'package:beatport_digger/state/session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryTokenStore implements TokenStore {
  _MemoryTokenStore(this.stored);

  TokenPair? stored;

  @override
  Future<TokenPair?> read() async => stored;

  @override
  Future<void> write(TokenPair token) async => stored = token;

  @override
  Future<void> clear() async => stored = null;
}

http.Response _json(Object payload) => http.Response(jsonEncode(payload), 200);

/// Serves just enough of the catalog for a session to sign in, load its genre
/// list and be dug through. [tracksFor] answers the track endpoint.
MockClient _api(http.Response Function(String? genreId) tracksFor) {
  return MockClient((request) async {
    final path = request.url.path;

    if (path.endsWith('/catalog/genres/')) {
      return _json({
        'count': 2,
        'next': null,
        'results': [
          {'id': 1, 'name': 'House'},
          {'id': 2, 'name': 'Techno'},
        ],
      });
    }
    if (path.contains('/sub-genres/') || path.endsWith('/catalog/keys/')) {
      return _json({'count': 0, 'next': null, 'results': []});
    }
    if (path.endsWith('/catalog/tracks/')) {
      return tracksFor(request.url.queryParameters['genre_id']);
    }
    return http.Response('not found', 404);
  });
}

Session _session(MockClient client) => Session(
  httpClient: client,
  store: _MemoryTokenStore(
    TokenPair(
      accessToken: 'live',
      refreshToken: 'refresh',
      expiresIn: 36000,
      issuedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    ),
  ),
);

/// The reference refresh is kicked off without being awaited, so tests wait
/// for the genre list to actually land.
Future<void> _awaitGenres(Session session) async {
  if (session.genres.isNotEmpty) return;
  final loaded = Completer<void>();
  void listener() {
    if (session.genres.isNotEmpty && !loaded.isCompleted) loaded.complete();
  }

  session.addListener(listener);
  try {
    await loaded.future.timeout(const Duration(seconds: 5));
  } finally {
    session.removeListener(listener);
  }
}

DiggerCrate _crate(String id, {int? genreId, String? genreName}) =>
    DiggerCrate(id: id, genreId: genreId, genreName: genreName);

http.Response _oneTrack(int id) => _json({
  'count': 1,
  'next': null,
  'results': [
    {'id': id, 'name': 'Track $id'},
  ],
});

void main() {
  late Directory support;

  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    support = Directory.systemTemp.createTempSync('bpdl-digger');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
  });

  tearDown(() => support.deleteSync(recursive: true));

  group('the bundle on disk', () {
    test('survives a restart', () async {
      final runner = DiggerRunner();
      await runner.load();

      runner.addCrate(
        const DiggerCrate(
          id: 'c1',
          genreId: 6,
          genreName: 'Techno',
          orderBy: '-plays',
          limit: 250,
          windowDays: 90,
          bpmLow: 124,
        ),
      );
      runner.addCrate(_crate('c2', genreId: 1, genreName: 'House'));
      runner.setRunOnStart(true);
      await runner.save();

      final restored = DiggerRunner();
      await restored.load();

      expect(restored.crates.map((c) => c.id), ['c1', 'c2']);
      expect(restored.crates.first.genreName, 'Techno');
      expect(restored.crates.first.orderBy, '-plays');
      expect(restored.crates.first.limit, 250);
      expect(restored.crates.first.bpmLow, 124);
      expect(restored.runOnStart, isTrue);
    });

    test('a first run starts empty', () async {
      final runner = DiggerRunner();
      await runner.load();

      expect(runner.crates, isEmpty);
      expect(runner.runOnStart, isFalse);
      expect(runner.isConfigured, isTrue);
      expect(runner.canRun, isFalse);
      expect(runner.estimatedTracks, 0);
    });

    test('crates can be added, removed and cleared', () async {
      final runner = DiggerRunner();
      await runner.load();

      runner.addCrate(_crate('a', genreId: 1));
      runner.addCrate(_crate('b', genreId: 2));
      expect(runner.crates, hasLength(2));
      expect(runner.estimatedTracks, defaultCrateLimit * 2);
      expect(runner.canRun, isTrue);

      runner.removeCrate('a');
      expect(runner.crates.single.id, 'b');

      runner.clearCrates();
      expect(runner.crates, isEmpty);
    });

    test('a batch of crates is saved once, and all of it survives', () async {
      final runner = DiggerRunner();
      await runner.load();

      // One crate per sub-genre, added together. Adding them one at a time
      // fired a save per crate, each racing the others to write the file.
      runner.addCrates([
        for (var i = 0; i < 20; i++)
          DiggerCrate(
            id: runner.nextCrateId(),
            genreId: 1,
            genreName: 'Dubstep',
            subGenreId: 100 + i,
            subGenreName: 'Sub $i',
          ),
      ]);
      await runner.save();

      final restored = DiggerRunner();
      await restored.load();

      expect(restored.crates, hasLength(20));
      expect(restored.crates.map((c) => c.subGenreId), [
        for (var i = 0; i < 20; i++) 100 + i,
      ]);
      expect(restored.crates.first.title, 'Dubstep / Sub 0');
    });

    test('every crate gets its own id', () async {
      final runner = DiggerRunner();
      await runner.load();

      final ids = {for (var i = 0; i < 50; i++) runner.nextCrateId()};
      expect(
        ids,
        hasLength(50),
        reason: 'two crates with identical filters are still separate entries',
      );
    });
  });

  group('queueing a bundle', () {
    test('walks every crate and queues what it finds', () async {
      final session = _session(
        _api((genreId) => _oneTrack(int.parse(genreId ?? '0'))),
      );
      await session.restore();
      await _awaitGenres(session);

      final runner = DiggerRunner();
      await runner.load();
      runner.addCrate(_crate('a', genreId: 1, genreName: 'House'));
      runner.addCrate(_crate('b', genreId: 2, genreName: 'Techno'));

      final queue = DownloadQueue();
      expect(await runner.run(session, queue), 2);

      expect(queue.jobs.map((job) => job.track.id), [1, 2]);
      expect(runner.running, isFalse);
      expect(runner.failures, isEmpty);
      expect(runner.summary, 'Queued 2');
    });

    test('an empty bundle says so instead of running', () async {
      final session = _session(_api((_) => _oneTrack(1)));
      await session.restore();
      await _awaitGenres(session);

      final runner = DiggerRunner();
      await runner.load();

      expect(await runner.run(session, DownloadQueue()), 0);
      expect(runner.error, 'Add at least one crate to the bundle first.');
    });

    test('a failing crate is recorded, the rest still land', () async {
      final session = _session(
        _api(
          (genreId) => genreId == '2'
              ? http.Response(jsonEncode({'detail': 'nope'}), 404)
              : _oneTrack(55),
        ),
      );
      await session.restore();
      await _awaitGenres(session);

      final runner = DiggerRunner();
      await runner.load();
      runner.addCrate(_crate('a', genreId: 1, genreName: 'House'));
      runner.addCrate(_crate('b', genreId: 2, genreName: 'Techno'));

      expect(await runner.run(session, DownloadQueue()), 1);
      expect(runner.failures.single, startsWith('Techno:'));
      expect(runner.summary, contains('1 crate failed'));
    });

    test('two runs cannot overlap', () async {
      final session = _session(_api((_) => _oneTrack(1)));
      await session.restore();
      await _awaitGenres(session);

      final runner = DiggerRunner();
      await runner.load();
      runner.addCrate(_crate('a', genreId: 1));

      final queue = DownloadQueue();
      final results = await Future.wait([
        runner.run(session, queue),
        runner.run(session, queue),
      ]);

      expect(results.where((n) => n > 0), hasLength(1));
      expect(results, contains(0));
    });

    test('a repeat run skips what the first one already fetched', () async {
      final session = _session(_api((_) => _oneTrack(1)));
      await session.restore();
      await _awaitGenres(session);

      final saved = File('${support.path}${Platform.pathSeparator}a.flac')
        ..writeAsStringSync('audio');
      File(
        '${support.path}${Platform.pathSeparator}download_history.json',
      ).writeAsStringSync(
        jsonEncode([
          {
            'track_id': 1,
            'title': 'A',
            'artists': '',
            'path': saved.path,
            'quality': 'FLAC',
            'completed_at': '2026-08-01T12:00:00.000',
          },
        ]),
      );

      final queue = DownloadQueue();
      await queue.loadHistory();
      await queue.verifyHistory();

      final runner = DiggerRunner();
      await runner.load();
      runner.addCrate(_crate('a', genreId: 1));

      expect(await runner.run(session, queue), 0);
      expect(queue.jobs, isEmpty);
      expect(runner.skipped, 1);
      expect(runner.summary, contains('skipped'));
    });

    test('the second crate starts from the first crate total', () async {
      final session = _session(
        _api((genreId) => _oneTrack(int.parse(genreId ?? '0'))),
      );
      await session.restore();
      await _awaitGenres(session);

      final runner = DiggerRunner();
      await runner.load();
      runner.addCrate(_crate('a', genreId: 1, genreName: 'House'));
      runner.addCrate(_crate('b', genreId: 2, genreName: 'Techno'));

      final marks = <String, int>{};
      void listener() {
        final step = runner.step;
        if (step != null) marks[step.crate.id] = runner.stepQueuedBefore;
      }

      runner.addListener(listener);
      await runner.run(session, DownloadQueue());
      runner.removeListener(listener);

      expect(marks['a'], 0);
      expect(
        marks['b'],
        1,
        reason: 'so the page can show what each crate contributed on its own',
      );
    });

    test('a run that queues nothing still reports progress', () async {
      // Everything already downloaded: nothing is added, so an update cadence
      // counting only additions would never fire and the dig would look hung.
      final session = _session(_api((_) => _oneTrack(1)));
      await session.restore();
      await _awaitGenres(session);

      final saved = File('${support.path}${Platform.pathSeparator}a.flac')
        ..writeAsStringSync('audio');
      File(
        '${support.path}${Platform.pathSeparator}download_history.json',
      ).writeAsStringSync(
        jsonEncode([
          {
            'track_id': 1,
            'title': 'A',
            'artists': '',
            'path': saved.path,
            'quality': 'FLAC',
            'completed_at': '2026-08-01T12:00:00.000',
          },
        ]),
      );

      final queue = DownloadQueue();
      await queue.loadHistory();
      await queue.verifyHistory();

      final runner = DiggerRunner();
      await runner.load();
      runner.addCrate(_crate('a', genreId: 1));

      await runner.run(session, queue);
      expect(queue.discoverSkipped, 1);
      expect(runner.skipped, 1);
    });

    /// Forty tracks per genre, numbered so the crate they came from is
    /// obvious. [onGenre] runs while that genre is being walked, which is a
    /// deterministic way to act mid-run: notifications are batched, so a
    /// listener cannot see inside a run this short.
    Session sessionActingMidWalk(void Function(String genreId) onGenre) =>
        _session(
          _api((genreId) {
            onGenre(genreId ?? '0');
            final id = int.parse(genreId ?? '0');
            return _json({
              'count': 40,
              'next': null,
              'results': [
                for (var i = 0; i < 40; i++)
                  {'id': id * 1000 + i, 'name': 'Track $i'},
              ],
            });
          }),
        );

    test('one crate can be cut short without stopping the bundle', () async {
      // The case this exists for: watching a genre pile up, deciding that is
      // enough of it, and moving on without losing the rest of the run.
      late final DiggerRunner runner;
      final session = sessionActingMidWalk((genreId) {
        if (genreId == '1') runner.skipCurrentCrate();
      });
      await session.restore();
      await _awaitGenres(session);

      runner = DiggerRunner();
      await runner.load();
      runner.addCrate(_crate('a', genreId: 1, genreName: 'House'));
      runner.addCrate(_crate('b', genreId: 2, genreName: 'Techno'));

      final queue = DownloadQueue();
      final queued = await runner.run(session, queue);

      expect(queued, 40, reason: 'the skipped crate contributed nothing more');
      expect(
        queue.jobs.every((job) => job.track.id! >= 2000),
        isTrue,
        reason: 'the second crate ran in full',
      );
      expect(
        runner.crates,
        hasLength(2),
        reason: 'skipping stops collecting, it does not delete the crate',
      );
    });

    test('removing the crate being walked also stops it', () async {
      late final DiggerRunner runner;
      final session = sessionActingMidWalk((genreId) {
        if (genreId == '1') runner.removeCrate('a');
      });
      await session.restore();
      await _awaitGenres(session);

      runner = DiggerRunner();
      await runner.load();
      runner.addCrate(_crate('a', genreId: 1, genreName: 'House'));
      runner.addCrate(_crate('b', genreId: 2, genreName: 'Techno'));

      final queue = DownloadQueue();
      await runner.run(session, queue);

      expect(runner.crates.single.id, 'b');
      expect(queue.jobs.every((job) => job.track.id! >= 2000), isTrue);
    });

    test('a crate added mid-run joins that run', () async {
      final session = _session(
        _api((genreId) => _oneTrack(int.parse(genreId ?? '0'))),
      );
      await session.restore();
      await _awaitGenres(session);

      final runner = DiggerRunner();
      await runner.load();
      runner.addCrate(_crate('a', genreId: 1));

      final queue = DownloadQueue();

      // Drop the second crate in as soon as the walk reports it has started.
      void listener() {
        if (runner.running && runner.crates.length == 1) {
          runner.addCrate(_crate('b', genreId: 2));
        }
      }

      runner.addListener(listener);
      final queued = await runner.run(session, queue);
      runner.removeListener(listener);

      expect(
        queued,
        2,
        reason: 'the user must be able to keep building while it queues',
      );
      expect(queue.jobs.map((job) => job.track.id), [1, 2]);
    });
  });
}

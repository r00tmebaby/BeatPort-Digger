import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:beatport_digger/engine/models.dart';
import 'package:beatport_digger/state/downloads.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Track _track(int id, {String name = 'Track'}) => Track(id: id, name: '$name $id');

Track _richTrack() => const Track(
  id: 4242,
  name: 'Strobe',
  mixName: 'Original Mix',
  slug: 'strobe',
  isrc: 'USUM71203001',
  bpm: 128,
  length: '10:37',
  publishDate: '2010-06-14',
  key: Key(id: 9, name: 'B min', camelotNumber: 10, camelotLetter: 'A'),
  genre: Named(id: 3, name: 'Progressive House'),
  subGenre: Named(id: 91, name: 'Melodic'),
  artists: [Named(id: 1, name: 'deadmau5', slug: 'deadmau5')],
  labelName: 'mau5trap',
  sampleUrl: 'https://geo-samples.beatport.com/4242.mp3',
  isExclusive: true,
  isClassic: true,
);

void main() {
  late Directory support;

  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    support = Directory.systemTemp.createTempSync('bpdl-queue');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
  });

  tearDown(() => support.deleteSync(recursive: true));

  File queueFile() =>
      File('${support.path}${Platform.pathSeparator}download_queue.jsonl');

  void writeQueueFile(List<Map<String, dynamic>> records) {
    queueFile().writeAsStringSync(
      records.map(jsonEncode).join('\n'),
    );
  }

  void writeHistoryFile(List<Map<String, dynamic>> records) {
    File(
      '${support.path}${Platform.pathSeparator}download_history.json',
    ).writeAsStringSync(jsonEncode(records));
  }

  group('saving', () {
    test('outstanding work is written and comes back', () async {
      final queue = DownloadQueue();
      queue.enqueueAll([_track(1), _track(2), _track(3)]);
      await queue.saveQueue();

      expect(queueFile().existsSync(), isTrue);

      final restored = DownloadQueue();
      await restored.loadQueue();

      expect(restored.jobs.map((job) => job.track.id), [1, 2, 3]);
      expect(
        restored.jobs.every((job) => job.status == JobStatus.queued),
        isTrue,
      );
      expect(restored.activeCount, 3);
    });

    test('a full track survives the round trip', () async {
      final queue = DownloadQueue();
      queue.enqueue(_richTrack());
      await queue.saveQueue();

      final restored = DownloadQueue();
      await restored.loadQueue();

      final track = restored.jobs.single.track;
      expect(track.id, 4242);
      expect(track.title, 'Strobe (Original Mix)');
      expect(track.artistNames, 'deadmau5');
      expect(track.labelName, 'mau5trap');
      expect(track.bpm, 128);
      expect(track.length, '10:37');
      expect(track.isrc, 'USUM71203001');
      expect(track.key?.camelot, '10A');
      expect(track.genreName, 'Progressive House');
      expect(track.subGenreName, 'Melodic');
      expect(track.sampleUrl, isNotNull);
      expect(track.isExclusive, isTrue);
      expect(track.isClassic, isTrue);
      expect(track.isHype, isFalse);
      expect(track.storeUrl, 'https://www.beatport.com/track/strobe/4242');
    });

    test('cancelled work is not carried over', () async {
      final queue = DownloadQueue();
      queue.enqueueAll([_track(1), _track(2)]);
      queue.cancel(queue.jobs.first);
      await queue.saveQueue();

      final restored = DownloadQueue();
      await restored.loadQueue();

      expect(restored.jobs.map((job) => job.track.id), [2]);
    });

    test('an empty queue leaves an empty file rather than a stale one', () async {
      final queue = DownloadQueue();
      queue.enqueue(_track(1));
      await queue.saveQueue();
      queue.clearAll();
      await queue.saveQueue();

      final restored = DownloadQueue();
      await restored.loadQueue();
      expect(restored.jobs, isEmpty);
    });
  });

  group('skipping what is already downloaded', () {
    /// A queue whose history says track 1 is on disk and track 2 is not.
    Future<DownloadQueue> queueWithHistory() async {
      final saved = File('${support.path}${Platform.pathSeparator}have.flac')
        ..writeAsStringSync('audio');

      writeHistoryFile([
        {
          'track_id': 1,
          'title': 'Track 1',
          'artists': 'Artist',
          'path': saved.path,
          'quality': 'FLAC',
          'completed_at': '2026-08-01T12:00:00.000',
        },
        {
          'track_id': 2,
          'title': 'Track 2',
          'artists': 'Artist',
          'path': '${support.path}${Platform.pathSeparator}gone.flac',
          'quality': 'FLAC',
          'completed_at': '2026-08-01T12:00:00.000',
        },
      ]);

      final queue = DownloadQueue();
      await queue.loadHistory();
      await queue.verifyHistory();
      return queue;
    }

    test('a bulk queue passes over tracks already on disk', () async {
      final queue = await queueWithHistory();

      expect(queue.enqueueAll([_track(1), _track(3)]), 1);
      expect(queue.jobs.map((job) => job.track.id), [3]);
      expect(queue.skippedDownloaded, 1);
    });

    test('a track whose file is gone is fetched again', () async {
      final queue = await queueWithHistory();

      expect(
        queue.enqueueAll([_track(2)]),
        1,
        reason: 'history marks it missing once the file is deleted',
      );
      expect(queue.skippedDownloaded, 0);
    });

    test('downloading a single track by hand always works', () async {
      final queue = await queueWithHistory();

      queue.enqueue(_track(1));
      expect(
        queue.jobs.map((job) => job.track.id),
        [1],
        reason: 'an explicit pick is not a sweep and must never be dropped',
      );

      queue.clearAll();
      queue.enqueueFirst(_track(1));
      expect(queue.jobs, hasLength(1));
    });

    test('the setting turns it off', () async {
      final queue = await queueWithHistory();
      queue.skipExisting = false;

      expect(queue.enqueueAll([_track(1), _track(3)]), 2);
      expect(queue.skippedDownloaded, 0);
    });

    test('the counts climb while the walk is still running', () async {
      // The digger reads these live. They used to be readable only once the
      // walk finished, so a long dig showed which crate it was on and nothing
      // about what it had actually collected.
      final queue = await queueWithHistory();
      final source = StreamController<Track>();
      final walk = queue.enqueueStream(source.stream, label: 'test');

      source.add(_track(3));
      await Future<void>.delayed(Duration.zero);
      expect(queue.discovered, 1);
      expect(queue.discoverSkipped, 0);

      source.add(_track(1));
      await Future<void>.delayed(Duration.zero);
      expect(queue.discovered, 1, reason: 'track 1 is already on disk');
      expect(queue.discoverSkipped, 1);

      source.add(_track(4));
      await Future<void>.delayed(Duration.zero);
      expect(queue.discovered, 2);

      await source.close();
      expect(await walk, 2);
    });

    test('a discovery walk reports what it passed over', () async {
      final queue = await queueWithHistory();

      final added = await queue.enqueueStream(
        Stream.fromIterable([_track(1), _track(3), _track(4)]),
        label: 'test',
      );

      expect(added, 2);
      expect(queue.discoverSkipped, 1);
    });

    test('the setting survives a restart', () async {
      final queue = DownloadQueue()..skipExisting = false;
      await queue.saveSettings();

      final restored = DownloadQueue();
      await restored.loadSettings();
      expect(restored.skipDownloaded, isFalse);
    });
  });

  group('restoring', () {
    test('a job that was mid-download comes back queued', () async {
      // Running jobs are persisted with no status marker, exactly as queued
      // ones are, because a half-finished download has to start over.
      writeQueueFile([
        {
          'track': {'id': 7, 'name': 'Interrupted'},
        },
      ]);

      final queue = DownloadQueue();
      await queue.loadQueue();

      expect(queue.jobs.single.status, JobStatus.queued);
      expect(queue.activeCount, 1);
    });

    test('a failed job comes back failed, with its reason', () async {
      writeQueueFile([
        {
          'track': {'id': 8, 'name': 'Broken'},
          'failed': true,
          'error': 'request failed with status 404',
        },
      ]);

      final queue = DownloadQueue();
      await queue.loadQueue();

      final job = queue.jobs.single;
      expect(job.status, JobStatus.failed);
      expect(job.error, 'request failed with status 404');
      expect(
        queue.activeCount,
        0,
        reason: 'a failed job is finished, so it is not outstanding work',
      );
    });

    test('a damaged line does not take the rest of the queue with it', () async {
      queueFile().writeAsStringSync(
        [
          jsonEncode({
            'track': {'id': 1, 'name': 'A'},
          }),
          '{not json at all',
          jsonEncode({'no track key': true}),
          '',
          jsonEncode({
            'track': {'id': 2, 'name': 'B'},
          }),
        ].join('\n'),
      );

      final queue = DownloadQueue();
      await queue.loadQueue();

      expect(queue.jobs.map((job) => job.track.id), [1, 2]);
    });

    test('a track already downloaded is not queued again', () async {
      final saved = File('${support.path}${Platform.pathSeparator}have.flac')
        ..writeAsStringSync('audio');

      writeHistoryFile([
        {
          'track_id': 1,
          'title': 'Track 1',
          'artists': 'Artist',
          'path': saved.path,
          'quality': 'FLAC',
          'completed_at': '2026-08-01T12:00:00.000',
        },
      ]);
      writeQueueFile([
        {
          'track': {'id': 1, 'name': 'Track 1'},
        },
        {
          'track': {'id': 2, 'name': 'Track 2'},
        },
      ]);

      final queue = DownloadQueue();
      await queue.restore();

      expect(
        queue.jobs.map((job) => job.track.id),
        [2],
        reason: 'the queue file can lag behind a completion by a few seconds',
      );
    });

    test('no queue file is not an error', () async {
      final queue = DownloadQueue();
      await queue.loadQueue();
      expect(queue.jobs, isEmpty);
    });

    test('restoring twice does not duplicate jobs', () async {
      writeQueueFile([
        {
          'track': {'id': 1, 'name': 'A'},
        },
      ]);

      final queue = DownloadQueue();
      await queue.loadQueue();
      await queue.loadQueue();

      expect(queue.jobs, hasLength(1));
      expect(queue.activeCount, 1);
    });
  });
}

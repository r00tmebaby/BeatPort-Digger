import 'dart:convert';
import 'dart:io';

import 'package:beatport_digger/engine/download_history.dart';
import 'package:beatport_digger/engine/models.dart';
import 'package:beatport_digger/state/downloads.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Track track(int id) => Track(id: id, name: 'Track $id');

void main() {
  group('DownloadQueue history', () {
    late Directory support;

    setUp(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      support = Directory.systemTemp.createTempSync('bpdl-history');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
    });

    tearDown(() => support.deleteSync(recursive: true));

    void writeHistory(List<Map<String, dynamic>> entries) {
      File(
        '${support.path}${Platform.pathSeparator}download_history.json',
      ).writeAsStringSync(jsonEncode(entries));
    }

    Map<String, dynamic> record(int id, String fileName) => {
      'track_id': id,
      'title': 'Track $id',
      'artists': 'Artist',
      'path': '${support.path}${Platform.pathSeparator}$fileName',
      'quality': 'FLAC',
      'completed_at': '2026-07-20T12:00:00.000',
    };

    test('persists a completion and reloads it', () async {
      writeHistory([record(42, 'strobe.flac')]);
      File(
        '${support.path}${Platform.pathSeparator}strobe.flac',
      ).writeAsStringSync('audio');

      final queue = DownloadQueue();
      await queue.loadHistory();
      await queue.verifyHistory();

      expect(queue.historyCount, 1);
      expect(queue.historyMark(track(42)), HistoryMark.saved);
      expect(queue.historyMark(track(99)), HistoryMark.none);
    });

    test('marks an entry missing when its file is gone', () async {
      writeHistory([record(7, 'does-not-exist.flac')]);

      final queue = DownloadQueue();
      await queue.loadHistory();
      await queue.verifyHistory();

      expect(queue.historyMark(track(7)), HistoryMark.missing);
      expect(queue.missingCount, 1);

      await queue.removeMissingHistory();
      expect(queue.historyCount, 0);
    });

    test('clearHistory forgets records but is a separate action', () async {
      writeHistory([record(1, 'a.flac')]);
      final queue = DownloadQueue();
      await queue.loadHistory();
      expect(queue.historyCount, 1);
      await queue.clearHistory();
      expect(queue.historyCount, 0);
    });
  });

  group('DownloadQueue', () {
    test('queues a track once', () {
      final queue = DownloadQueue();
      queue.enqueue(track(1));
      queue.enqueue(track(1));
      expect(queue.jobs, hasLength(1));
    });

    test('ignores a track with no id', () {
      final queue = DownloadQueue();
      queue.enqueue(const Track());
      expect(queue.jobs, isEmpty);
    });

    test('cancelling a queued job marks it cancelled', () {
      final queue = DownloadQueue();
      queue.enqueue(track(1));
      queue.cancel(queue.jobs.single);
      expect(queue.jobs.single.status, JobStatus.cancelled);
      expect(queue.jobs.single.isFinished, isTrue);
    });

    test('cancelAll stops everything outstanding', () {
      final queue = DownloadQueue();
      for (var i = 1; i <= 3; i++) {
        queue.enqueue(track(i));
      }
      queue.cancelAll();
      expect(queue.jobs.every((j) => j.status == JobStatus.cancelled), isTrue);
      expect(queue.activeCount, 0);
      expect(queue.isBusy, isFalse);
    });

    test('cancelAll signals cancellation, not just the status', () {
      final queue = DownloadQueue();
      queue.enqueue(track(1));
      final job = queue.jobs.single;
      queue.cancelAll();
      expect(job.cancellation.isCancelled, isTrue);
    });

    test('a cancelled job can be queued again', () {
      final queue = DownloadQueue();
      queue.enqueue(track(1));
      queue.cancel(queue.jobs.single);
      queue.enqueue(track(1));
      expect(queue.jobs, hasLength(1));
      expect(queue.jobs.single.status, JobStatus.queued);
    });

    test('clearFinished keeps outstanding work', () {
      final queue = DownloadQueue();
      queue.enqueue(track(1));
      queue.enqueue(track(2));
      queue.cancel(queue.jobs.first);
      queue.clearFinished();
      expect(queue.jobs, hasLength(1));
      expect(queue.jobs.single.track.id, 2);
    });

    test('clearAll empties the list', () {
      final queue = DownloadQueue();
      queue.enqueue(track(1));
      queue.enqueue(track(2));
      queue.clearAll();
      expect(queue.jobs, isEmpty);
    });

    test('enqueueAll reports how many were added', () {
      final queue = DownloadQueue();
      expect(queue.enqueueAll([track(1), track(2), track(1)]), 2);
    });

    test('enqueueFirst prioritizes a track ahead of queued work', () {
      final queue = DownloadQueue();
      queue.enqueue(track(1));
      queue.enqueue(track(2));
      queue.enqueueFirst(track(3));
      expect(queue.jobs.map((job) => job.track.id), [3, 1, 2]);
    });

    test('enqueueAllFirst keeps page order while moving it to the front', () {
      final queue = DownloadQueue();
      queue.enqueue(track(10));
      queue.enqueue(track(20));

      expect(queue.enqueueAllFirst([track(1), track(2), track(3)]), 3);
      expect(queue.jobs.map((job) => job.track.id), [1, 2, 3, 10, 20]);
    });

    test('enqueueAll notifies once, not once per track', () {
      final queue = DownloadQueue();
      var notifications = 0;
      queue.addListener(() => notifications += 1);

      queue.enqueueAll([for (var i = 0; i < 500; i++) track(i)]);
      expect(queue.jobs, hasLength(500));
      expect(notifications, 1);
    });

    test('enqueueAll does not notify when nothing was added', () {
      final queue = DownloadQueue();
      queue.enqueue(track(1));
      var notifications = 0;
      queue.addListener(() => notifications += 1);

      expect(queue.enqueueAll([track(1)]), 0);
      expect(notifications, 0);
    });

    test('a large bulk enqueue stays linear', () {
      final queue = DownloadQueue();
      final tracks = [for (var i = 0; i < 5000; i++) track(i)];

      final stopwatch = Stopwatch()..start();
      expect(queue.enqueueAll(tracks), 5000);
      stopwatch.stop();

      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(1000),
        reason: 'quadratic behaviour would take far longer',
      );
    });

    test('lookup stays correct after removals', () {
      final queue = DownloadQueue();
      queue.enqueueAll([track(1), track(2)]);
      queue.cancel(queue.jobs.first);
      queue.clearFinished();

      expect(queue.jobFor(track(1)), isNull);
      expect(queue.jobFor(track(2)), isNotNull);

      queue.enqueue(track(1));
      expect(queue.jobFor(track(1)), isNotNull);
      expect(queue.jobs, hasLength(2));
    });

    test('clearAll empties the index too', () {
      final queue = DownloadQueue();
      queue.enqueueAll([track(1), track(2)]);
      queue.clearAll();
      expect(queue.jobFor(track(1)), isNull);
      queue.enqueue(track(1));
      expect(queue.jobs, hasLength(1));
    });

    test('concurrency is clamped to a usable range', () {
      final queue = DownloadQueue();
      queue.maxConcurrent = 999;
      expect(queue.maxConcurrent, maxParallelDownloads);
      queue.maxConcurrent = 0;
      expect(queue.maxConcurrent, 1);
      queue.maxConcurrent = 32;
      expect(queue.maxConcurrent, 32);
    });

    test('the active list can hold the full concurrency', () {
      final queue = DownloadQueue()..maxConcurrent = maxParallelDownloads;
      expect(queue.maxConcurrent, 64);
      expect(queue.active, isEmpty);
    });

    test('jobFor finds a queued track by id', () {
      final queue = DownloadQueue();
      queue.enqueue(track(7));
      expect(queue.jobFor(track(7)), isNotNull);
      expect(queue.jobFor(track(8)), isNull);
    });
  });

  group('DownloadQueue bookkeeping', () {
    test('the active count follows every transition', () {
      final queue = DownloadQueue();
      queue.enqueueAll([track(1), track(2), track(3)]);
      expect(queue.activeCount, 3);
      expect(queue.isBusy, isTrue);

      queue.cancel(queue.jobs.first);
      expect(queue.activeCount, 2);

      queue.enqueue(track(1));
      expect(queue.activeCount, 3, reason: 'a retry is outstanding again');

      queue.cancelAll();
      expect(queue.activeCount, 0);
      expect(queue.isBusy, isFalse);

      queue.clearFinished();
      expect(queue.activeCount, 0);
    });

    test('the revision moves on status changes, the structure does not', () {
      final queue = DownloadQueue();
      queue.enqueueAll([track(1), track(2)]);

      final revision = queue.revision;
      final structure = queue.structureRevision;

      queue.cancel(queue.jobs.first);
      expect(queue.revision, greaterThan(revision));
      expect(
        queue.structureRevision,
        structure,
        reason:
            'title and artist ordering must survive a status change '
            'without re-sorting the whole queue',
      );

      queue.clearFinished();
      expect(queue.structureRevision, greaterThan(structure));
    });

    test('the active list holds only what is downloading now', () {
      final queue = DownloadQueue();
      queue.enqueueAll([track(1), track(2)]);

      expect(
        queue.active,
        isEmpty,
        reason: 'nothing runs until a catalog is bound',
      );

      queue.cancelAll();
      expect(queue.active, isEmpty);
    });

    test('jobs carry lower-cased sort keys computed once', () {
      final queue = DownloadQueue();
      queue.enqueue(
        const Track(
          id: 1,
          name: 'Strobe',
          mixName: 'Club Mix',
          artists: [Named(name: 'Deadmau5')],
        ),
      );

      final job = queue.jobs.single;
      expect(job.titleKey, 'strobe (club mix)');
      expect(job.artistKey, 'deadmau5');
      expect(
        identical(job.titleKey, job.titleKey),
        isTrue,
        reason:
            'lower-casing inside a sort comparator allocates per '
            'comparison, which dominates a large sort',
      );
    });

    test('a retried job keeps its place in the list', () {
      final queue = DownloadQueue();
      queue.enqueueAll([track(1), track(2), track(3)]);
      queue.cancel(queue.jobs[1]);
      queue.enqueue(track(2));

      expect(queue.jobs.map((job) => job.track.id), [1, 2, 3]);
      expect(queue.jobs[1].status, JobStatus.queued);
    });

    test('queueing a page first lifts retried tracks to the front too', () {
      final queue = DownloadQueue();
      queue.enqueueAll([track(1), track(2), track(3)]);
      queue.cancel(queue.jobs[2]);

      expect(queue.enqueueAllFirst([track(3), track(4)]), 2);
      expect(
        queue.jobs.map((job) => job.track.id),
        [3, 4, 1, 2],
        reason:
            'a track already in the queue must still be prioritized, '
            'not left where it was',
      );
      expect(queue.jobs.first.status, JobStatus.queued);
    });
  });

  group('DownloadQueue at scale', () {
    test('requeuing a large queue stays linear', () {
      final queue = DownloadQueue();
      final tracks = [for (var i = 0; i < 20000; i++) track(i)];
      queue.enqueueAll(tracks);
      queue.cancelAll();

      final stopwatch = Stopwatch()..start();
      expect(queue.enqueueAll(tracks), 20000);
      stopwatch.stop();

      expect(queue.jobs, hasLength(20000));
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(1000),
        reason: 'removing and re-appending each job would be quadratic',
      );
    });

    test('reading the job list does not copy it', () {
      final queue = DownloadQueue();
      queue.enqueueAll([for (var i = 0; i < 100000; i++) track(i)]);

      final stopwatch = Stopwatch()..start();
      var seen = 0;
      for (var i = 0; i < 1000; i++) {
        seen += queue.jobs.length;
      }
      stopwatch.stop();

      expect(seen, 100000 * 1000);
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(500),
        reason:
            'the Downloads list reads this on every rebuild, and '
            'rebuilds arrive several times a second while downloads run',
      );
    });

    test('the active count does not scan the queue', () {
      final queue = DownloadQueue();
      queue.enqueueAll([for (var i = 0; i < 100000; i++) track(i)]);

      final stopwatch = Stopwatch()..start();
      var seen = 0;
      for (var i = 0; i < 1000; i++) {
        seen += queue.activeCount;
      }
      stopwatch.stop();

      expect(seen, 100000 * 1000);
      expect(stopwatch.elapsedMilliseconds, lessThan(200));
    });
  });
}

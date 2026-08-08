@Tags(['bench'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:beatport_digger/engine/models.dart';
import 'package:beatport_digger/state/downloads.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Stall = ({Duration total, Duration worst, Duration blocked});

/// How badly [work] holds up the event loop.
///
/// A periodic timer fires as fast as the loop allows, so the gap between two
/// ticks is how long something held the isolate without yielding. [worst] is
/// the single longest hitch; [blocked] adds up every gap over a frame, which
/// is what catches thousands of small stalls that never show up as one big
/// one but still make the app feel dead.
Future<Stall> stallDuring(Future<void> Function() work) async {
  var worst = Duration.zero;
  var blocked = Duration.zero;
  var last = DateTime.now();

  final ticker = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final now = DateTime.now();
    final gap = now.difference(last);
    if (gap > worst) worst = gap;
    if (gap.inMilliseconds > 16) blocked += gap;
    last = now;
  });

  // Let the ticker settle before measuring.
  await Future<void>.delayed(const Duration(milliseconds: 20));
  last = DateTime.now();

  final watch = Stopwatch()..start();
  await work();
  watch.stop();
  ticker.cancel();
  return (total: watch.elapsed, worst: worst, blocked: blocked);
}

Track track(int id) => Track(
  id: id,
  name: 'Track $id',
  mixName: 'Extended Mix',
  bpm: 120 + (id % 40),
  newReleaseDate: '2026-03-14',
  key: const Key(name: 'A Minor', camelotNumber: 8, camelotLetter: 'A'),
  genre: const Named(id: 1, name: 'Melodic House & Techno'),
  subGenre: const Named(id: 2, name: 'Melodic Techno'),
  artists: [Named(id: id, name: 'Artist $id')],
  labelName: 'Label',
  sampleUrl: 'https://geo-samples.beatport.com/$id.mp3',
);

void main() {
  late Directory support;
  const size = 100000;

  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    support = Directory.systemTemp.createTempSync('bpdl-bench');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
  });

  tearDown(() => support.deleteSync(recursive: true));

  test('where the isolate blocks', () async {
    final report = <String, Stall>{};

    final tracks = [for (var i = 0; i < size; i++) track(i)];

    final queue = DownloadQueue();
    report['enqueueAll $size'] = await stallDuring(() async {
      queue.enqueueAll(tracks);
    });

    report['saveQueue $size'] = await stallDuring(queue.saveQueue);

    final restored = DownloadQueue();
    report['loadQueue $size'] = await stallDuring(restored.loadQueue);

    // History: one record per track, half of them pointing at files that are
    // not there.
    final present = File('${support.path}${Platform.pathSeparator}have.flac')
      ..writeAsStringSync('audio');
    File(
      '${support.path}${Platform.pathSeparator}download_history.json',
    ).writeAsStringSync(
      jsonEncode([
        for (var i = 0; i < 20000; i++)
          {
            'track_id': i,
            'title': 'Track $i',
            'artists': 'Artist',
            'path': i.isEven
                ? present.path
                : '${support.path}${Platform.pathSeparator}gone-$i.flac',
            'quality': 'FLAC',
            'completed_at': '2026-08-01T12:00:00.000',
          },
      ]),
    );

    final history = DownloadQueue();
    report['loadHistory 20k'] = await stallDuring(history.loadHistory);
    report['verifyHistory 20k'] = await stallDuring(history.verifyHistory);

    final notifier = DownloadQueue()..enqueueAll(tracks.take(size).toList());
    var rebuilds = 0;
    notifier.addListener(() => rebuilds += 1);
    report['1000 cancels'] = await stallDuring(() async {
      for (final job in notifier.jobs.take(1000)) {
        notifier.cancel(job);
      }
    });

    // ignore: avoid_print
    print('\n=== event loop, $size queued ===');
    // ignore: avoid_print
    print('${'step'.padRight(22)} ${'wall'.padLeft(8)}'
        '${'worst'.padLeft(8)}${'blocked'.padLeft(9)}');
    for (final entry in report.entries) {
      final s = entry.value;
      // ignore: avoid_print
      print(
        '${entry.key.padRight(22)}'
        '${'${s.total.inMilliseconds}ms'.padLeft(8)}'
        '${'${s.worst.inMilliseconds}ms'.padLeft(8)}'
        '${'${s.blocked.inMilliseconds}ms'.padLeft(9)}'
        '${s.blocked.inMilliseconds > 500 ? '   <-- FREEZE' : ''}',
      );
    }
    // ignore: avoid_print
    print('listener rebuilds during 1000 cancels: $rebuilds\n');
  }, timeout: const Timeout(Duration(minutes: 5)));
}

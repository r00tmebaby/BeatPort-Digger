@Tags(['bench'])
library;

import 'dart:io';

import 'package:beatport_digger/engine/models.dart';
import 'package:beatport_digger/state/downloads.dart';
import 'package:beatport_digger/ui/downloads_page.dart';
import 'package:beatport_digger/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Track track(int id) => Track(
  id: id,
  name: 'Track $id',
  mixName: 'Extended Mix',
  bpm: 120 + (id % 40),
  genre: const Named(id: 1, name: 'Melodic House & Techno'),
  artists: [Named(id: id, name: 'Artist $id')],
  labelName: 'Label',
);

/// Microseconds spent in the state change, and in the frame it causes.
({int change, int frame}) frameCost(
  WidgetTester tester,
  void Function() apply,
) {
  final changeWatch = Stopwatch()..start();
  apply();
  changeWatch.stop();

  final frameWatch = Stopwatch()..start();
  tester.binding.scheduleFrame();
  tester.binding.handleBeginFrame(Duration.zero);
  tester.binding.handleDrawFrame();
  frameWatch.stop();

  return (
    change: changeWatch.elapsedMicroseconds,
    frame: frameWatch.elapsedMicroseconds,
  );
}

void main() {
  late Directory support;

  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    support = Directory.systemTemp.createTempSync('bpdl-ui-bench');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
  });

  tearDown(() => support.deleteSync(recursive: true));

  testWidgets('what a queue change costs the UI', (tester) async {
    final report = <String, ({int change, int frame})>{};
    const size = 100000;

    final queue = DownloadQueue();
    queue.enqueueAll([for (var i = 0; i < size; i++) track(i)]);

    Widget host(Widget child) => MaterialApp(
      home: ChangeNotifierProvider<DownloadQueue>.value(
        value: queue,
        child: Scaffold(body: child),
      ),
    );

    // The pages the app keeps alive in its IndexedStack, measured one at a
    // time so it is obvious which of them is expensive.
    await tester.pumpWidget(host(const DownloadsPage()));
    await tester.pump();

    report['Downloads first build'] = frameCost(tester, () {});
    report['Downloads on notify'] = frameCost(
      tester,
      () => queue.cancel(queue.jobs.first),
    );

    var worstChange = 0;
    var worstFrame = 0;
    for (var i = 1; i <= 20; i++) {
      final cost = frameCost(tester, () => queue.cancel(queue.jobs[i]));
      if (cost.change > worstChange) worstChange = cost.change;
      if (cost.frame > worstFrame) worstFrame = cost.frame;
    }
    report['Downloads worst of 20'] = (change: worstChange, frame: worstFrame);

    await tester.pumpWidget(host(const SettingsPage()));
    await tester.pump();
    report['Settings first build'] = frameCost(tester, () {});
    report['Settings on notify'] = frameCost(
      tester,
      () => queue.cancel(queue.jobs[50]),
    );

    // Does the frame cost scale with how much is queued? If it does, the
    // list is doing work proportional to the whole queue rather than to what
    // is on screen, and that is the thing to fix.
    for (final n in [1000, 10000, 100000]) {
      final sized = DownloadQueue();
      sized.enqueueAll([for (var i = 0; i < n; i++) track(i)]);
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<DownloadQueue>.value(
            value: sized,
            child: const Scaffold(body: DownloadsPage()),
          ),
        ),
      );
      await tester.pump();

      var worst = 0;
      for (var i = 0; i < 5; i++) {
        final cost = frameCost(tester, () => sized.cancel(sized.jobs[i]));
        if (cost.frame > worst) worst = cost.frame;
      }
      report['Downloads notify @$n'] = (change: 0, frame: worst);
    }

    // ignore: avoid_print
    print('\n=== cost, 100k queued (microseconds) ===');
    // ignore: avoid_print
    print('${'step'.padRight(24)}${'change'.padLeft(10)}${'frame'.padLeft(10)}');
    for (final entry in report.entries) {
      final total = entry.value.change + entry.value.frame;
      // ignore: avoid_print
      print(
        '${entry.key.padRight(24)}'
        '${entry.value.change.toString().padLeft(10)}'
        '${entry.value.frame.toString().padLeft(10)}'
        '${total > 16000 ? '   <-- dropped frame' : ''}',
      );
    }
    // ignore: avoid_print
    print('');
  }, timeout: const Timeout(Duration(minutes: 5)));
}

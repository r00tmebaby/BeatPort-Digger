import 'package:beatport_digger/engine/models.dart';
import 'package:beatport_digger/state/downloads.dart';
import 'package:beatport_digger/ui/widgets/track_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Track track(int id, String title) => Track(id: id, name: title);

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: SizedBox(width: 1000, height: 400, child: child)),
);

/// Stands in for the download queue and the preview player as an update
/// source for [TrackTable.updates].
class _Ticker extends ChangeNotifier {
  void fire() => notifyListeners();

  bool get isListenedTo => hasListeners;
}

void main() {
  testWidgets('header stays visible after the list is scrolled', (
    tester,
  ) async {
    final tracks = [for (var i = 0; i < 100; i++) track(i, 'Track $i')];
    await tester.pumpWidget(host(TrackTable(tracks: tracks)));
    await tester.pumpAndSettle();

    expect(find.text('Artists'), findsOneWidget);
    expect(find.text('Title'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();

    expect(find.text('Artists'), findsOneWidget);
    expect(find.text('Title'), findsOneWidget);
  });

  testWidgets('rows are numbered from one', (tester) async {
    final tracks = [for (var i = 0; i < 5; i++) track(i, 'Track $i')];
    await tester.pumpWidget(host(TrackTable(tracks: tracks)));
    await tester.pumpAndSettle();

    expect(find.text('1'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('a rank column shows when rankFor is given', (tester) async {
    final tracks = [track(1, 'A'), track(2, 'B')];
    await tester.pumpWidget(
      host(
        TrackTable(
          tracks: tracks,
          rankLabel: 'Plays',
          rankFor: (t) => t.id == 1 ? 1 : 2,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Plays'), findsOneWidget);
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);
  });

  testWidgets('copy button shows copied feedback', (tester) async {
    final tracks = [track(1, 'Song A')];
    await tester.pumpWidget(host(TrackTable(tracks: tracks)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.content_copy).first);
    await tester.pump();

    expect(find.text('Copied song to clipboard.'), findsOneWidget);
  });

  group('live rows', () {
    testWidgets('a row updates its state without a parent rebuild', (
      tester,
    ) async {
      // The queue and the player notify constantly while downloading and
      // previewing; the whole point of TrackTable.updates is that the table
      // above the rows never rebuilds for that.
      final ticker = _Ticker();
      addTearDown(ticker.dispose);
      final statuses = <int, JobStatus>{};
      var parentBuilds = 0;

      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) {
              parentBuilds += 1;
              return TrackTable(
                tracks: [track(1, 'Song A'), track(2, 'Song B')],
                onDownload: (_) {},
                statusFor: (t) => statuses[t.id],
                updates: ticker,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.download_outlined), findsNWidgets(2));

      statuses[1] = JobStatus.completed;
      ticker.fire();
      await tester.pump();

      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      expect(
        parentBuilds,
        1,
        reason: 'only the changed row may rebuild, never the table',
      );
    });

    testWidgets('a notification that changes nothing repaints nothing', (
      tester,
    ) async {
      final ticker = _Ticker();
      addTearDown(ticker.dispose);
      var parentBuilds = 0;

      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) {
              parentBuilds += 1;
              return TrackTable(
                tracks: [track(1, 'Song A')],
                onDownload: (_) {},
                statusFor: (_) => null,
                updates: ticker,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Progress bytes and player position ticks land here as notifications
      // whose fingerprints are unchanged.
      for (var i = 0; i < 50; i++) {
        ticker.fire();
      }
      await tester.pump();

      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      expect(parentBuilds, 1);
    });

    testWidgets('play state changes reach the row', (tester) async {
      final ticker = _Ticker();
      addTearDown(ticker.dispose);
      var playingId = -1;

      await tester.pumpWidget(
        host(
          TrackTable(
            tracks: [track(1, 'Song A'), track(2, 'Song B')],
            onPlay: (_) {},
            playingState: (t) => t.id == playingId
                ? PlaybackState.playing
                : PlaybackState.idle,
            updates: ticker,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.pause_circle_filled), findsNothing);

      playingId = 1;
      ticker.fire();
      await tester.pump();
      expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);

      playingId = 2;
      ticker.fire();
      await tester.pump();
      expect(
        find.byIcon(Icons.pause_circle_filled),
        findsOneWidget,
        reason: 'the old row must clear as the new one lights up',
      );
      expect(find.byIcon(Icons.play_circle_outline), findsNWidgets(1));
    });

    testWidgets('the narrow layout follows updates the same way', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final ticker = _Ticker();
      addTearDown(ticker.dispose);
      final statuses = <int, JobStatus>{};

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrackTable(
              tracks: [track(1, 'Song A')],
              onDownload: (_) {},
              statusFor: (t) => statuses[t.id],
              updates: ticker,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.download_outlined), findsOneWidget);

      statuses[1] = JobStatus.failed;
      ticker.fire();
      await tester.pump();
      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });

    testWidgets('rows detach their listeners when disposed', (tester) async {
      final ticker = _Ticker();
      addTearDown(ticker.dispose);

      await tester.pumpWidget(
        host(
          TrackTable(
            tracks: [for (var i = 0; i < 3; i++) track(i, 'Track $i')],
            onDownload: (_) {},
            statusFor: (_) => null,
            updates: ticker,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(ticker.isListenedTo, isTrue);

      await tester.pumpWidget(host(const SizedBox()));
      await tester.pumpAndSettle();

      expect(
        ticker.isListenedTo,
        isFalse,
        reason: 'a leaked listener would keep dead rows doing lookups on '
            'every queue change for the rest of the session',
      );

      // Firing with no rows alive must not throw.
      ticker.fire();
    });
  });
}

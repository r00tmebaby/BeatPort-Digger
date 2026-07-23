import 'package:cratedigger/engine/models.dart';
import 'package:cratedigger/ui/widgets/track_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Track track(int id, String title) => Track(id: id, name: title);

Widget host(Widget child) => MaterialApp(
  home: Scaffold(
    // Wide enough that the table renders as the columned layout, not cards.
    body: SizedBox(width: 1000, height: 400, child: child),
  ),
);

void main() {
  testWidgets('header stays visible after the list is scrolled', (tester) async {
    final tracks = [for (var i = 0; i < 100; i++) track(i, 'Track $i')];
    await tester.pumpWidget(host(TrackTable(tracks: tracks)));
    await tester.pumpAndSettle();

    // The header labels are present before scrolling.
    expect(find.text('Artists'), findsOneWidget);
    expect(find.text('Title'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();

    // Still present: the header is pinned outside the scroll view. As row 0 of
    // the ListView it would have scrolled off.
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
}

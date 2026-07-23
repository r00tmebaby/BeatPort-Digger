import 'package:beatport_digger/engine/catalog.dart';
import 'package:beatport_digger/engine/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Total pages the UI should show for a result count, mirroring the search
/// tab's arithmetic so the rule is pinned in one place.
int totalPages(int count, int perPage) {
  final reachable = count < resultWindow ? count : resultWindow;
  if (reachable == 0) return 0;
  return (reachable + perPage - 1) ~/ perPage;
}

void main() {
  group('Paginated.fromJson', () {
    test('reads count and the next/previous links', () {
      final page = Paginated.fromJson({
        'count': 2386,
        'next': 'https://api/tracks/?page=2',
        'previous': null,
        'results': [
          {'id': 1, 'name': 'A'},
        ],
      }, Track.fromJson);

      expect(page.count, 2386);
      expect(page.next, isNotNull);
      expect(page.previous, isNull);
      expect(page.results, hasLength(1));
    });

    test('a last page has no next link', () {
      final page = Paginated.fromJson({
        'count': 10,
        'next': null,
        'results': const [],
      }, Track.fromJson);
      expect(page.next, isNull);
    });
  });

  group('totalPages', () {
    test('rounds up a partial final page', () {
      expect(totalPages(250, 100), 3);
      expect(totalPages(200, 100), 2);
      expect(totalPages(1, 100), 1);
    });

    test('is zero when nothing matched', () {
      expect(totalPages(0, 100), 0);
    });

    test('caps at the reachable result window', () {
      // The API refuses an offset past resultWindow, so a count above it does
      // not add reachable pages.
      expect(totalPages(50000, 100), resultWindow ~/ 100);
      expect(totalPages(resultWindow, 100), resultWindow ~/ 100);
    });

    test('respects the per-page size', () {
      expect(totalPages(100, 25), 4);
      expect(totalPages(100, 200), 1);
    });
  });
}

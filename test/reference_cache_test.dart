import 'package:beatport_digger/engine/models.dart';
import 'package:beatport_digger/engine/reference_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReferenceData', () {
    final data = ReferenceData(
      genres: const [
        Genre(id: 1, name: 'Techno', slug: 'techno'),
        Genre(id: 6, name: 'House', slug: 'house'),
      ],
      subGenres: const {
        1: [Named(id: 10, name: 'Peak Time')],
        6: [Named(id: 20, name: 'Deep')],
      },
      keys: const [
        Key(id: 8, name: 'A Minor', camelotNumber: 8, camelotLetter: 'A'),
      ],
      fetchedAt: DateTime.utc(2026, 7, 20),
    );

    test('round-trips through JSON', () {
      final restored = ReferenceData.fromJson(data.toJson());

      expect(restored.genres.map((g) => g.name), ['Techno', 'House']);
      expect(restored.subGenres[1]!.single.name, 'Peak Time');
      expect(restored.subGenres[6]!.single.id, 20);
      expect(restored.keys.single.camelotNumber, 8);
      expect(restored.fetchedAt, DateTime.utc(2026, 7, 20));
    });

    test('sub-genre keys survive as ints, not strings', () {
      final restored = ReferenceData.fromJson(data.toJson());
      expect(restored.subGenres.keys, containsAll([1, 6]));
      expect(restored.subGenres[1], isNotNull);
    });

    test('an empty snapshot reports itself empty', () {
      const empty = ReferenceData(
        genres: [],
        subGenres: {},
        keys: [],
        fetchedAt: null,
      );
      expect(empty.isEmpty, isTrue);
      expect(data.isEmpty, isFalse);
    });

    test('tolerates missing sections', () {
      final restored = ReferenceData.fromJson({'genres': []});
      expect(restored.genres, isEmpty);
      expect(restored.subGenres, isEmpty);
      expect(restored.keys, isEmpty);
      expect(restored.fetchedAt, isNull);
    });
  });
}

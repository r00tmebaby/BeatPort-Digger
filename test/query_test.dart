import 'package:beatport_digger/engine/catalog.dart';
import 'package:beatport_digger/engine/models.dart';
import 'package:beatport_digger/ui/search_tab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TrackQuery.params', () {
    test('carries every filter at once', () {
      // Filters combine as AND at the API, so all of them must survive into
      // the request together. Dropping one silently widens the search.
      final params = TrackQuery(
        genreId: [108],
        subGenreId: [309],
        bpm: '124:124',
        name: 'love',
        artistName: 'Beyer',
        labelName: 'Drumcode',
        isHype: true,
        isClassic: true,
        isExplicit: true,
        orderBy: '-plays',
        perPage: 100,
      ).params();

      expect(params['genre_id'], '108');
      expect(params['sub_genre_id'], '309');
      expect(params['bpm'], '124:124');
      expect(params['name'], 'love');
      expect(params['artist_name'], 'Beyer');
      expect(params['label_name'], 'Drumcode');
      expect(params['is_hype'], 'true');
      expect(params['is_classic'], 'true');
      expect(params['is_explicit'], 'true');
      expect(params['order_by'], '-plays');
    });

    test('omits filters that were not set', () {
      final params = TrackQuery(genreId: [108]).params();
      expect(params['genre_id'], '108');
      expect(params['bpm'], isNull);
      expect(params['artist_name'], isNull);
      // false must not be sent as a filter, or it would exclude everything.
      expect(params['is_hype'], isNull);
      expect(params['is_classic'], isNull);
      expect(params['is_explicit'], isNull);
    });

    test('joins multiple ids with commas', () {
      expect(TrackQuery(keyId: [8, 20]).params()['key_id'], '8,20');
    });

    test('copy keeps every field', () {
      final original = TrackQuery(
        genreId: [1],
        artistName: 'x',
        labelName: 'y',
        isHype: true,
        bpm: '120:130',
      );
      final copy = original.copy();
      expect(copy.params(), original.params());
    });

    test('accepts the popularity sort keys', () {
      expect(validateOrderBy('-plays'), '-plays');
      expect(validateOrderBy('-downloads'), '-downloads');
    });

    test('rejects sort keys the API answers with an empty page', () {
      // These return count=0 rather than an error, which is indistinguishable
      // from a filter that matched nothing.
      for (final key in ['popularity', 'trending', 'rank', 'sales', 'hype']) {
        expect(() => validateOrderBy(key), throwsArgumentError, reason: key);
      }
    });
  });

  group('describeQuery', () {
    test('reports every active filter', () {
      final query = TrackQuery(
        genreId: [108],
        bpm: '124:124',
        artistName: 'Beyer',
        isHype: true,
      );
      final described = describeQuery(
        query,
        const Genre(id: 108, name: 'R&B'),
        null,
      );

      expect(described, contains('Genre: R&B'));
      expect(described, contains('BPM: 124:124'));
      expect(described, contains('Artist: Beyer'));
      expect(described, contains('Hype'));
    });

    test('says nothing when nothing is filtered', () {
      expect(describeQuery(TrackQuery(), null, null), isEmpty);
    });

    test('falls back to the id when the name is unknown', () {
      final described = describeQuery(TrackQuery(genreId: [108]), null, null);
      expect(described.single, 'Genre: 108');
    });
  });
}

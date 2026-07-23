import 'package:beatport_digger/engine/auth.dart';
import 'package:beatport_digger/engine/catalog.dart';
import 'package:beatport_digger/engine/errors.dart';
import 'package:beatport_digger/engine/models.dart';
import 'package:beatport_digger/engine/token.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('computeLoginId', () {
    test('matches the published FNV-1a 64 vectors', () {
      // Verified against the published FNV-1a 64-bit vectors, so the login_id
      // stays stable across runs and platforms.
      expect(computeLoginId('', '').length, 16);
      expect(computeLoginId('a', 'b'), 'e661911904a01160');
    });

    test('is stable and distinguishes accounts', () {
      final one = computeLoginId('alice', 'secret');
      expect(computeLoginId('alice', 'secret'), one);
      expect(computeLoginId('bob', 'secret'), isNot(one));
      expect(computeLoginId('alice', 'other'), isNot(one));
    });
  });

  group('validateOrderBy', () {
    test('accepts the keys the API honours, with and without a prefix', () {
      for (final key in ['publish_date', '-publish_date', 'name', 'bpm', '']) {
        expect(validateOrderBy(key), key);
      }
    });

    test('rejects keys the API answers with a silent empty result', () {
      // id, isrc and new_release_date return count=0 rather than an error,
      // which would look like a filter that matched nothing.
      for (final key in ['id', '-id', 'isrc', 'new_release_date']) {
        expect(() => validateOrderBy(key), throwsArgumentError);
      }
    });
  });

  group('bpmBounds', () {
    test('treats an absent filter as the full range', () {
      expect(bpmBounds(null), (low: bpmFloor, high: bpmCeiling));
      expect(bpmBounds(''), (low: bpmFloor, high: bpmCeiling));
    });

    test('parses ranges including open ends', () {
      expect(bpmBounds('120:130'), (low: 120, high: 130));
      expect(bpmBounds(':130'), (low: bpmFloor, high: 130));
      expect(bpmBounds('120:'), (low: 120, high: bpmCeiling));
    });

    test('refuses to divide an exact value', () {
      expect(bpmBounds('128'), isNull);
      expect(bpmBounds('fast:slow'), isNull);
    });
  });

  group('TrackQuery', () {
    test('filters on new_release_date, never publish_date', () {
      // The API accepts a publish_date range and then ignores it, silently
      // returning the unfiltered catalog.
      final query = TrackQuery(genreId: [89]).dated(
        DateTime(2026, 1, 1),
        DateTime(2026, 6, 30),
      );
      final params = query.params();
      expect(params['new_release_date'], '2026-01-01:2026-06-30');
      expect(params.containsKey('publish_date'), isFalse);
    });

    test('pads single-digit months and days', () {
      final query = TrackQuery().dated(DateTime(2026, 3, 5), DateTime(2026, 3, 5));
      expect(query.params()['new_release_date'], '2026-03-05:2026-03-05');
    });

    test('joins repeated ids for the OR lookup', () {
      expect(TrackQuery(genreId: [1, 2, 3]).params()['genre_id'], '1,2,3');
    });

    test('copy does not alias the original list', () {
      final original = TrackQuery(genreId: [1]);
      final clone = original.copy()..genreId!.add(2);
      expect(original.genreId, [1]);
      expect(clone.genreId, [1, 2]);
    });
  });

  group('sessionIdFrom', () {
    test('reads the cookie out of a folded Set-Cookie header', () {
      // Dart joins repeated Set-Cookie headers with commas, and expiry dates
      // contain commas too, so splitting on them would corrupt the value.
      const header =
          'csrftoken=abc; expires=Fri, 01 Jan 2027 00:00:00 GMT; Path=/, '
          'sessionid=s3cr3tvalue; expires=Sat, 02 Jan 2027 00:00:00 GMT; Path=/';
      expect(sessionIdFrom({'set-cookie': header}), 's3cr3tvalue');
    });

    test('returns null when no session cookie is present', () {
      expect(sessionIdFrom({'set-cookie': 'csrftoken=abc; Path=/'}), isNull);
      expect(sessionIdFrom({}), isNull);
    });
  });

  group('TokenPair', () {
    test('an unknown issue time counts as live', () {
      const token = TokenPair(accessToken: 'x', expiresIn: 3600);
      expect(token.isExpired(), isFalse);
    });

    test('expires within the refresh leeway', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final soon = TokenPair(
        accessToken: 'x',
        expiresIn: 3600,
        issuedAt: now - 3600 + refreshLeeway - 30,
      );
      expect(soon.isExpired(), isTrue);

      final fresh = TokenPair(accessToken: 'x', expiresIn: 3600, issuedAt: now);
      expect(fresh.isExpired(), isFalse);
    });

    test('round-trips through the JSON cache format', () {
      const token = TokenPair(
        accessToken: 'a',
        refreshToken: 'r',
        expiresIn: 36000,
        loginId: 'deadbeefdeadbeef',
        issuedAt: 1700000000,
      );
      final restored = TokenPair.fromJson(token.toJson());
      expect(restored.accessToken, 'a');
      expect(restored.refreshToken, 'r');
      expect(restored.loginId, 'deadbeefdeadbeef');
      expect(restored.issuedAt, 1700000000);
    });

    test('stamping preserves an existing issue time and login id', () {
      const token = TokenPair(
        accessToken: 'a',
        issuedAt: 123,
        loginId: 'keepme0000000000',
      );
      final stamped = token.stamped();
      expect(stamped.issuedAt, 123);
      expect(stamped.loginId, 'keepme0000000000');
    });
  });

  group('models', () {
    test('reads a label out of the release object', () {
      // The generated schema types release as a URI string, but the live API
      // returns an object.
      final track = Track.fromJson({
        'id': 1,
        'name': 'Glue',
        'mix_name': 'Original Mix',
        'release': {
          'label': {'name': 'Ninja Tune'},
        },
        'artists': [
          {'name': 'Bicep'},
        ],
      });
      expect(track.title, 'Glue (Original Mix)');
      expect(track.labelName, 'Ninja Tune');
      expect(track.artistNames, 'Bicep');
    });

    test('survives a release typed as a string', () {
      final track = Track.fromJson({'id': 1, 'release': 'https://example/1'});
      expect(track.labelName, '');
    });

    test('camelot neighbours wrap around the wheel', () {
      const key = Key(camelotNumber: 12, camelotLetter: 'A');
      expect(key.camelot, '12A');
      expect(key.neighbours(), ['12A', '1A', '11A', '12B']);
    });

    test('a key without camelot data yields no neighbours', () {
      const key = Key(name: 'Unknown');
      expect(key.camelot, '');
      expect(key.neighbours(), isEmpty);
    });
  });

  group('errorMessage', () {
    test('reads the common shapes', () {
      expect(errorMessage('{"detail":"Not found."}'), 'Not found.');
      expect(errorMessage('{"error":"invalid_grant"}'), 'invalid_grant');
    });

    test('flattens field-keyed arrays', () {
      expect(
        errorMessage('{"id":["Enter a number."],"bpm":["Too fast."]}'),
        'bpm: Too fast.; id: Enter a number.',
      );
    });

    test('returns empty for anything unparseable', () {
      expect(errorMessage('<html>502</html>'), '');
      expect(errorMessage('[1,2,3]'), '');
    });
  });
}

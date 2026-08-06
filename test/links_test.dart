import 'package:beatport_digger/engine/links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseBeatportLink', () {
    test('reads the slugged store form, where the id trails the slug', () {
      final link = parseBeatportLink(
        'https://www.beatport.com/track/blue-monday/12345',
      );
      expect(link.type, LinkType.track);
      expect(link.id, 12345);
    });

    test('reads the bare form used by the API', () {
      expect(
        parseBeatportLink('https://api.beatport.com/v4/catalog/tracks/999').id,
        999,
      );
    });

    test('strips a locale prefix', () {
      final link = parseBeatportLink(
        'https://www.beatport.com/de/release/some-ep/777',
      );
      expect(link.type, LinkType.release);
      expect(link.id, 777);
    });

    test('unwraps a library playlist', () {
      final link = parseBeatportLink(
        'https://www.beatport.com/library/playlists/42',
      );
      expect(link.type, LinkType.playlist);
      expect(link.id, 42);
    });

    test('separates a store chart from a library playlist', () {
      expect(
        parseBeatportLink('https://www.beatport.com/playlist/x/5').type,
        LinkType.chart,
      );
      expect(
        parseBeatportLink('https://www.beatport.com/playlists/5').type,
        LinkType.playlist,
      );
    });

    test('recognises labels, artists and charts', () {
      expect(
        parseBeatportLink('https://www.beatport.com/label/drumcode/1234').type,
        LinkType.label,
      );
      expect(
        parseBeatportLink('https://www.beatport.com/artist/adam-beyer/1').type,
        LinkType.artist,
      );
      expect(
        parseBeatportLink('https://www.beatport.com/chart/top-100/99').type,
        LinkType.chart,
      );
    });

    test('carries query filters through', () {
      final link = parseBeatportLink(
        'https://www.beatport.com/label/x/1?genre_id=6&bpm=120:130',
      );
      expect(link.query['genre_id'], '6');
      expect(link.query['bpm'], '120:130');
    });

    test('rejects a path with no id instead of crashing', () {
      for (final url in [
        'https://www.beatport.com/library',
        'https://www.beatport.com/track',
        'https://www.beatport.com/tracks',
      ]) {
        expect(
          () => parseBeatportLink(url),
          throwsA(isA<LinkException>()),
          reason: url,
        );
      }
    });

    test('rejects other hosts and unknown types', () {
      expect(
        () => parseBeatportLink('https://soundcloud.com/track/x/1'),
        throwsA(isA<LinkException>()),
      );
      expect(
        () => parseBeatportLink('https://www.beatport.com/nonsense/x/1'),
        throwsA(isA<LinkException>()),
      );
    });

    test('rejects a non-numeric id', () {
      expect(
        () => parseBeatportLink('https://www.beatport.com/track/x/abc'),
        throwsA(isA<LinkException>()),
      );
    });

    test('isBeatportLink does not throw', () {
      expect(isBeatportLink('https://www.beatport.com/track/x/1'), isTrue);
      expect(isBeatportLink('rubbish'), isFalse);
    });
  });
}

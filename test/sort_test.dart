import 'package:beatport_digger/engine/models.dart';
import 'package:beatport_digger/ui/widgets/track_table.dart';
import 'package:flutter_test/flutter_test.dart';

Track track({
  String name = '',
  String label = '',
  int? bpm,
  String? length,
  int? camelotNumber,
  String? camelotLetter,
  List<String> artists = const [],
}) => Track(
  id: name.hashCode,
  name: name,
  labelName: label,
  bpm: bpm,
  length: length,
  key: camelotNumber == null
      ? null
      : Key(camelotNumber: camelotNumber, camelotLetter: camelotLetter),
  artists: [for (final a in artists) Named(name: a)],
);

void main() {
  group('sortTracks', () {
    test('leaves order untouched when no column is chosen', () {
      final tracks = [track(name: 'b'), track(name: 'a')];
      expect(
        sortTracks(tracks, TrackSort.none, true).map((t) => t.name),
        ['b', 'a'],
      );
    });

    test('orders by bpm and reverses on descending', () {
      final tracks = [track(name: 'x', bpm: 128), track(name: 'y', bpm: 120)];
      expect(sortTracks(tracks, TrackSort.bpm, true).first.bpm, 120);
      expect(sortTracks(tracks, TrackSort.bpm, false).first.bpm, 128);
    });

    test('orders keys round the wheel, not as text', () {
      // Sorted as strings, "10A" would land before "9A".
      final tracks = [
        track(name: 'ten', camelotNumber: 10, camelotLetter: 'A'),
        track(name: 'nine', camelotNumber: 9, camelotLetter: 'A'),
        track(name: 'nineB', camelotNumber: 9, camelotLetter: 'B'),
      ];
      expect(
        sortTracks(tracks, TrackSort.key, true).map((t) => t.name),
        ['nine', 'nineB', 'ten'],
      );
    });

    test('orders lengths by duration, not lexically', () {
      // "10:00" sorts before "9:00" as text.
      final tracks = [
        track(name: 'long', length: '10:00'),
        track(name: 'short', length: '9:00'),
      ];
      expect(
        sortTracks(tracks, TrackSort.length, true).map((t) => t.name),
        ['short', 'long'],
      );
    });

    test('handles hour-long durations', () {
      final tracks = [
        track(name: 'hour', length: '1:00:00'),
        track(name: 'minutes', length: '59:00'),
      ];
      expect(
        sortTracks(tracks, TrackSort.length, true).map((t) => t.name),
        ['minutes', 'hour'],
      );
    });

    test('keeps tracks with no value out of the way', () {
      final tracks = [
        track(name: 'none'),
        track(name: 'has', bpm: 100),
      ];
      // Missing sorts lowest ascending, so it does not displace real values at
      // the top of a descending sort either.
      expect(sortTracks(tracks, TrackSort.bpm, true).first.name, 'none');
      expect(sortTracks(tracks, TrackSort.bpm, false).first.name, 'has');
    });

    test('orders artists and labels case insensitively', () {
      final tracks = [
        track(name: 'b', artists: ['zebra']),
        track(name: 'a', artists: ['Apple']),
      ];
      expect(
        sortTracks(tracks, TrackSort.artists, true).map((t) => t.name),
        ['a', 'b'],
      );
    });

    test('does not mutate the list it was given', () {
      final tracks = [track(name: 'b', bpm: 2), track(name: 'a', bpm: 1)];
      sortTracks(tracks, TrackSort.bpm, true);
      expect(tracks.map((t) => t.name), ['b', 'a']);
    });
  });
}

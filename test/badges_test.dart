import 'package:beatport_digger/engine/models.dart';
import 'package:flutter_test/flutter_test.dart';

Track fromJson(Map<String, dynamic> extra) =>
    Track.fromJson({'id': 1, 'name': 'Track', ...extra});

void main() {
  group('track flags', () {
    test('reads every flag the catalog sets', () {
      final track = fromJson({
        'is_hype': true,
        'exclusive': true,
        'is_classic': true,
        'is_dj_edit': true,
        'is_explicit': true,
        'pre_order': true,
      });

      expect(track.isHype, isTrue);
      expect(track.isExclusive, isTrue);
      expect(track.isClassic, isTrue);
      expect(track.isDjEdit, isTrue);
      expect(track.isExplicit, isTrue);
      expect(track.isPreOrder, isTrue);
    });

    test('defaults to false when a flag is absent or null', () {
      final track = fromJson({'is_hype': null});
      expect(track.isHype, isFalse);
      expect(track.isExclusive, isFalse);
      expect(track.badges, isEmpty);
    });

    test('ignores a non-boolean value', () {
      expect(fromJson({'is_hype': 'true'}).isHype, isFalse);
      expect(fromJson({'is_hype': 1}).isHype, isFalse);
    });

    test('badges list only what is set, explicit last', () {
      final track = fromJson({'is_hype': true, 'is_explicit': true});
      expect(track.badges, ['Hype', 'E']);
    });

    test('exclusive comes from the exclusive key, not is_exclusive', () {
      expect(fromJson({'exclusive': true}).isExclusive, isTrue);
      expect(fromJson({'is_exclusive': true}).isExclusive, isFalse);
    });
  });
}

import 'package:cratedigger/engine/download_history.dart';
import 'package:flutter_test/flutter_test.dart';

HistoryEntry entry(int id, {bool present = true}) => HistoryEntry(
  trackId: id,
  title: 'Track $id',
  artists: 'Artist',
  path: '/music/track$id.flac',
  quality: 'FLAC',
  completedAt: DateTime.utc(2026, 7, 20, 12),
  present: present,
);

void main() {
  group('HistoryEntry', () {
    test('round-trips through JSON', () {
      final restored = HistoryEntry.fromJson(entry(5).toJson());
      expect(restored, isNotNull);
      expect(restored!.trackId, 5);
      expect(restored.title, 'Track 5');
      expect(restored.artists, 'Artist');
      expect(restored.path, '/music/track5.flac');
      expect(restored.quality, 'FLAC');
      expect(restored.completedAt, DateTime.utc(2026, 7, 20, 12));
    });

    test('present defaults true on load; disk state is checked separately', () {
      // Presence is not persisted: it reflects the disk now, not when saved.
      final json = entry(1, present: false).toJson();
      expect(json.containsKey('present'), isFalse);
      expect(HistoryEntry.fromJson(json)!.present, isTrue);
    });

    test('rejects a record with no id or path', () {
      expect(HistoryEntry.fromJson({'path': '/x'}), isNull);
      expect(HistoryEntry.fromJson({'track_id': 1}), isNull);
    });

    test('tolerates missing optional fields', () {
      final restored = HistoryEntry.fromJson({
        'track_id': 9,
        'path': '/x.flac',
      });
      expect(restored, isNotNull);
      expect(restored!.title, '');
      expect(restored.completedAt.millisecondsSinceEpoch, 0);
    });

    test('copyWith flips presence without touching the rest', () {
      final marked = entry(3).copyWith(present: false);
      expect(marked.present, isFalse);
      expect(marked.trackId, 3);
      expect(marked.path, '/music/track3.flac');
    });
  });
}

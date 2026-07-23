import 'package:beatport_digger/engine/errors.dart';
import 'package:beatport_digger/engine/hls.dart';
import 'package:beatport_digger/state/player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('previewErrorMessage', () {
    test('a 404 reads as unavailable, not as a status code', () {
      // Beatport serves a stream link for some tracks whose HLS asset 404s;
      // that is accurate, not a crash, so it must not look like one.
      final message = previewErrorMessage(
        BeatportException(404, 'could not read the stream playlist'),
      );
      expect(message, 'No preview available for this track.');
      expect(message, isNot(contains('404')));
    });

    test('403 is treated the same as 404', () {
      expect(
        previewErrorMessage(BeatportException(403)),
        'No preview available for this track.',
      );
    });

    test('another status still shows a number, for a real fault', () {
      expect(
        previewErrorMessage(BeatportException(500)),
        'Preview unavailable (500).',
      );
    });

    test('an HLS parse failure reads as unavailable', () {
      expect(
        previewErrorMessage(HlsException('playlist contains no segments')),
        'No preview available for this track.',
      );
    });

    test('anything else gets a generic, non-technical message', () {
      final message = previewErrorMessage(StateError('boom'));
      expect(message, 'Could not play a preview of this track.');
      expect(message, isNot(contains('boom')));
    });
  });
}

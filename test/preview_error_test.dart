import 'package:beatport_digger/engine/errors.dart';
import 'package:beatport_digger/engine/hls.dart';
import 'package:beatport_digger/state/player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('previewErrorMessage', () {
    test('a 404 reads as unavailable, not as a status code', () {
      final message = previewErrorMessage(
        BeatportException(404, 'could not read the stream playlist'),
      );
      expect(message, 'No preview available for this track.');
      expect(message, isNot(contains('404')));
    });

    test('a 403 reads as a refusal, not as a missing asset', () {
      final message = previewErrorMessage(BeatportException(403));
      expect(message, 'Beatport refused this preview (403).');
      expect(message, isNot(contains('No preview available')));
    });

    test('a 403 repeats the reason Beatport gave', () {
      expect(
        previewErrorMessage(
          BeatportException(403, 'Invalid subscription status.'),
        ),
        'Beatport refused this preview: Invalid subscription status.',
      );
    });

    test('a 401 says to sign in rather than showing a status code', () {
      expect(
        previewErrorMessage(BeatportException(401)),
        'Session expired. Sign in again.',
      );
    });

    test('another status still shows a number, for a real fault', () {
      expect(
        previewErrorMessage(BeatportException(500)),
        'Preview unavailable (500).',
      );
    });

    test('an HLS parse failure reads as a stream that could not be read', () {
      expect(
        previewErrorMessage(HlsException('playlist contains no segments')),
        'The preview stream could not be read.',
      );
    });

    test('anything else gets a generic, non-technical message', () {
      final message = previewErrorMessage(StateError('boom'));
      expect(message, 'Could not play a preview of this track.');
      expect(message, isNot(contains('boom')));
    });
  });
}

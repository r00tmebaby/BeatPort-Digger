import 'package:cratedigger/engine/request_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RequestGate', () {
    test('only the latest ticket is current', () {
      final gate = RequestGate();
      final first = gate.begin();
      final second = gate.begin();

      // Issuing the second search makes the first stale, whichever resolves
      // first over the network.
      expect(gate.isCurrent(first), isFalse);
      expect(gate.isCurrent(second), isTrue);
    });

    test('a stale response is rejected even if it returns last', () {
      // Reproduces the filter race: search A issued, then B; B applies, then A
      // returns late and must be dropped so its results do not overwrite B.
      final gate = RequestGate();
      final a = gate.begin();
      final b = gate.begin();

      // B returns first and is applied.
      expect(gate.isCurrent(b), isTrue);
      // A returns later; it is no longer current.
      expect(gate.isCurrent(a), isFalse);
    });

    test('tickets keep rising', () {
      final gate = RequestGate();
      expect(gate.begin(), 1);
      expect(gate.begin(), 2);
      expect(gate.begin(), 3);
    });

    test('the newest wins across many in flight', () {
      final gate = RequestGate();
      final tickets = [for (var i = 0; i < 5; i++) gate.begin()];
      // Only the last of five overlapping searches applies.
      for (var i = 0; i < 4; i++) {
        expect(gate.isCurrent(tickets[i]), isFalse);
      }
      expect(gate.isCurrent(tickets.last), isTrue);
    });
  });
}

import 'package:beatport_digger/engine/request_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RequestGate', () {
    test('only the latest ticket is current', () {
      final gate = RequestGate();
      final first = gate.begin();
      final second = gate.begin();

      expect(gate.isCurrent(first), isFalse);
      expect(gate.isCurrent(second), isTrue);
    });

    test('a stale response is rejected even if it returns last', () {
      final gate = RequestGate();
      final a = gate.begin();
      final b = gate.begin();

      expect(gate.isCurrent(b), isTrue);

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

      for (var i = 0; i < 4; i++) {
        expect(gate.isCurrent(tickets[i]), isFalse);
      }
      expect(gate.isCurrent(tickets.last), isTrue);
    });
  });
}

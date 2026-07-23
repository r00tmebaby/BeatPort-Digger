import 'package:beatport_digger/engine/debouncer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Debouncer', () {
    test('runs once after a burst of calls', () async {
      final debouncer = Debouncer(delay: const Duration(milliseconds: 40));
      var runs = 0;

      // Five rapid calls, as typing five characters would.
      for (var i = 0; i < 5; i++) {
        debouncer.run(() => runs += 1);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(runs, 0, reason: 'nothing fires while calls keep coming');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(runs, 1, reason: 'one run after the quiet period');
    });

    test('cancel stops a pending run', () async {
      final debouncer = Debouncer(delay: const Duration(milliseconds: 30));
      var runs = 0;
      debouncer.run(() => runs += 1);
      debouncer.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(runs, 0);
    });

    test('a later call reschedules rather than stacking', () async {
      final debouncer = Debouncer(delay: const Duration(milliseconds: 40));
      var runs = 0;
      debouncer.run(() => runs += 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      debouncer.run(() => runs += 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // The first would have fired by now if it had not been rescheduled.
      expect(runs, 0);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(runs, 1);
    });
  });
}

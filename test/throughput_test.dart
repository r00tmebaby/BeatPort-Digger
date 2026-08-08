import 'package:beatport_digger/engine/throughput.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 8, 8, 12);

  DateTime at(int seconds, [int millis = 0]) =>
      start.add(Duration(seconds: seconds, milliseconds: millis));

  group('ThroughputMeter', () {
    test('a steady stream reads as its true rate', () {
      final meter = ThroughputMeter();
      // One megabyte a second for five seconds.
      for (var s = 0; s <= 5; s++) {
        meter.record(1024 * 1024, at(s));
      }

      final rate = meter.bytesPerSecond(at(5));
      expect(rate, closeTo(1024 * 1024, 1024 * 1024 * 0.05));
      expect(meter.total, 6 * 1024 * 1024);
    });

    test('the rate reflects the window, not the whole session', () {
      final meter = ThroughputMeter(window: const Duration(seconds: 10));
      // A fast first minute long out of the window, then a slow trickle.
      meter.record(500 * 1024 * 1024, at(0));
      for (var s = 60; s <= 70; s++) {
        meter.record(100 * 1024, at(s));
      }

      final rate = meter.bytesPerSecond(at(70));
      expect(
        rate,
        lessThan(200 * 1024),
        reason: 'an old burst must not inflate the current rate',
      );
    });

    test('a stall decays toward zero instead of freezing', () {
      final meter = ThroughputMeter();
      meter.record(1024 * 1024, at(0));
      meter.record(1024 * 1024, at(1));

      final live = meter.bytesPerSecond(at(1));
      final stalled = meter.bytesPerSecond(at(30));
      expect(live, greaterThan(0));
      expect(
        stalled,
        0,
        reason: 'nothing arrived for thirty seconds, so nothing is moving',
      );
    });

    test('zero and negative deltas are ignored', () {
      final meter = ThroughputMeter();
      meter.record(0, at(0));
      meter.record(-500, at(1));
      expect(meter.total, 0);
      expect(meter.bytesPerSecond(at(1)), 0);
    });

    test('an empty meter reads zero', () {
      expect(ThroughputMeter().bytesPerSecond(at(0)), 0);
    });
  });

  group('formatSpeed', () {
    test('picks a sensible unit', () {
      expect(formatSpeed(0), '0 B/s');
      expect(formatSpeed(512), '512 B/s');
      expect(formatSpeed(300 * 1024), '300 KB/s');
      expect(formatSpeed(2.5 * 1024 * 1024), '2.5 MB/s');
    });
  });
}

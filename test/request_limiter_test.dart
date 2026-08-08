import 'dart:async';

import 'package:beatport_digger/engine/request_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RequestLimiter', () {
    test('lets the first callers straight through', () async {
      final limiter = RequestLimiter(3);
      await limiter.acquire();
      await limiter.acquire();
      await limiter.acquire();
      expect(limiter.active, 3);
      expect(limiter.waiting, 0);
    });

    test('holds the rest until a slot frees', () async {
      final limiter = RequestLimiter(2);
      await limiter.acquire();
      await limiter.acquire();

      var admitted = false;
      unawaited(limiter.acquire().then((_) => admitted = true));
      await Future<void>.delayed(Duration.zero);

      expect(admitted, isFalse);
      expect(limiter.waiting, 1);

      limiter.release();
      await Future<void>.delayed(Duration.zero);
      expect(admitted, isTrue);
    });

    test('never runs more than the limit at once', () async {
      final limiter = RequestLimiter(4);
      var running = 0;
      var peak = 0;

      await Future.wait([
        for (var i = 0; i < 40; i++)
          limiter.run(() async {
            running += 1;
            if (running > peak) peak = running;
            await Future<void>.delayed(const Duration(milliseconds: 1));
            running -= 1;
            return i;
          }),
      ]);

      expect(peak, lessThanOrEqualTo(4));
      expect(limiter.active, 0);
      expect(limiter.waiting, 0);
    });

    test('a failing call still gives its slot back', () async {
      final limiter = RequestLimiter(1);

      await expectLater(
        limiter.run(() async => throw StateError('boom')),
        throwsStateError,
      );

      expect(limiter.active, 0);
      await limiter.acquire().timeout(const Duration(seconds: 1));
    });

    test('waiters are served in order', () async {
      final limiter = RequestLimiter(1);
      await limiter.acquire();

      final served = <int>[];
      final waiters = [
        for (var i = 0; i < 3; i++)
          limiter.acquire().then((_) => served.add(i)),
      ];

      for (var i = 0; i < 3; i++) {
        limiter.release();
        await Future<void>.delayed(Duration.zero);
      }
      await Future.wait(waiters);

      expect(served, [0, 1, 2]);
    });

    test('a nonsense limit is treated as one', () {
      expect(RequestLimiter(0).limit, 1);
      expect(RequestLimiter(-5).limit, 1);
    });

    test('caps a burst far larger than the limit', () async {
      // Stands in for the download path: sixty-four tracks each wanting six
      // segments at once, against an app-wide cap.
      final limiter = RequestLimiter(24);
      var running = 0;
      var peak = 0;

      await Future.wait([
        for (var i = 0; i < 64 * 6; i++)
          limiter.run(() async {
            running += 1;
            if (running > peak) peak = running;
            await Future<void>.delayed(const Duration(microseconds: 200));
            running -= 1;
          }),
      ]);

      expect(peak, lessThanOrEqualTo(24));
      expect(limiter.active, 0);
    });
  });
}

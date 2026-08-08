library;

import 'dart:async';
import 'dart:collection';

/// Caps how many requests may be in flight at once, queueing the rest in
/// arrival order.
///
/// Sixteen concurrent downloads each opening their own metadata request, on
/// top of a queue discovery walk paging through the catalog, is enough of a
/// burst to draw rate limiting. Holding the in-flight count down costs a busy
/// queue nothing measurable and keeps single downloads at full speed.
class RequestLimiter {
  RequestLimiter(int limit) : limit = limit < 1 ? 1 : limit;

  final int limit;

  final Queue<Completer<void>> _waiting = Queue();
  int _active = 0;

  int get active => _active;
  int get waiting => _waiting.length;

  Future<void> acquire() {
    if (_active < limit) {
      _active += 1;
      return Future.value();
    }
    final slot = Completer<void>();
    _waiting.add(slot);
    return slot.future;
  }

  /// Hands the slot to the next waiter, or gives it back to the pool. The
  /// active count is deliberately not decremented when someone is waiting:
  /// the slot changes owner rather than being freed.
  void release() {
    if (_waiting.isEmpty) {
      if (_active > 0) _active -= 1;
      return;
    }
    _waiting.removeFirst().complete();
  }

  /// Runs [action] holding one slot.
  Future<T> run<T>(Future<T> Function() action) async {
    await acquire();
    try {
      return await action();
    } finally {
      release();
    }
  }
}

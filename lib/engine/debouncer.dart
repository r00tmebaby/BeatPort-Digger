library;

import 'dart:async';

class Debouncer {
  Debouncer({this.delay = const Duration(milliseconds: 400)});

  final Duration delay;
  Timer? _timer;

  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void cancel() => _timer?.cancel();

  bool get isPending => _timer?.isActive ?? false;

  void dispose() => _timer?.cancel();
}

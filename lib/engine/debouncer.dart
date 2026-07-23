/// Collapses a burst of calls into one, after a quiet period.
///
/// Typing in a filter field would otherwise fire a network search per
/// keystroke. Debouncing waits until the typing stops before searching once.
library;

import 'dart:async';

class Debouncer {
  Debouncer({this.delay = const Duration(milliseconds: 400)});

  final Duration delay;
  Timer? _timer;

  /// Runs [action] once [delay] has passed with no further call.
  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  /// Cancels a pending call, e.g. when something fires the action immediately.
  void cancel() => _timer?.cancel();

  bool get isPending => _timer?.isActive ?? false;

  void dispose() => _timer?.cancel();
}

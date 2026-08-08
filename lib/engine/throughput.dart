library;

import 'dart:collection';

/// Measures download throughput over a sliding window.
///
/// Byte deltas are recorded as they arrive and the rate is read as bytes per
/// second across roughly the last [window]. A plain total-over-elapsed figure
/// would average in every stall since the session began; a windowed rate
/// answers the question actually being asked, which is how fast things are
/// moving right now.
class ThroughputMeter {
  ThroughputMeter({this.window = const Duration(seconds: 10)});

  final Duration window;

  /// Cumulative totals at points in time. Keeping totals rather than deltas
  /// makes the rate a subtraction instead of a sum over the queue.
  final Queue<(DateTime, int)> _samples = Queue();

  int _total = 0;

  /// Bytes recorded since the meter was created.
  int get total => _total;

  void record(int bytes, DateTime now) {
    if (bytes <= 0) return;
    _total += bytes;
    _samples.addLast((now, _total));
    _trim(now);
  }

  /// Drops samples that fell out of the window. The most recent one is always
  /// kept so a stalled transfer reads as a rate decaying to zero rather than
  /// as no data.
  void _trim(DateTime now) {
    final edge = now.subtract(window);
    while (_samples.length > 1 && _samples.first.$1.isBefore(edge)) {
      _samples.removeFirst();
    }
  }

  double bytesPerSecond(DateTime now) {
    _trim(now);
    if (_samples.isEmpty) return 0;

    final (edgeTime, edgeTotal) = _samples.first;
    final bytes = _total - edgeTotal;
    final micros = now.difference(edgeTime).inMicroseconds;
    if (bytes <= 0 || micros <= 0) return 0;
    return bytes * 1e6 / micros;
  }
}

/// Renders a byte count with the largest unit that keeps the number small,
/// so a long session reads as gigabytes instead of four-digit megabytes.
String formatBytes(int bytes) {
  const kb = 1024.0;
  const mb = 1024.0 * 1024.0;
  const gb = 1024.0 * 1024.0 * 1024.0;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(0)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// Renders a rate the way download UIs conventionally do.
String formatSpeed(double bytesPerSecond) {
  const kb = 1024.0;
  const mb = 1024.0 * 1024.0;
  if (bytesPerSecond >= mb) {
    return '${(bytesPerSecond / mb).toStringAsFixed(1)} MB/s';
  }
  if (bytesPerSecond >= kb) {
    return '${(bytesPerSecond / kb).toStringAsFixed(0)} KB/s';
  }
  return '${bytesPerSecond.toStringAsFixed(0)} B/s';
}

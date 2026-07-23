/// Lets only the most recently issued async request apply its result.
///
/// When searches fire on every filter change, several can be in flight at once
/// and may resolve out of order. Applying a stale response would show results
/// that do not match the filters on screen. Each request takes a ticket; only
/// the latest ticket is still current when its response returns.
library;

class RequestGate {
  int _latest = 0;

  /// Claims the next ticket, marking every earlier one stale.
  int begin() => ++_latest;

  /// Whether [ticket] is still the most recent request.
  bool isCurrent(int ticket) => ticket == _latest;
}

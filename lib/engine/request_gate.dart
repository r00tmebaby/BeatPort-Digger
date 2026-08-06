library;

class RequestGate {
  int _latest = 0;

  int begin() => ++_latest;

  bool isCurrent(int ticket) => ticket == _latest;
}

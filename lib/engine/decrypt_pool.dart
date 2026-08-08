library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'hls.dart';

/// Decrypts HLS segments on a small, fixed set of long-lived isolates.
///
/// The obvious way to move this off the UI isolate is `compute`, but that
/// spawns a fresh isolate per call and tears it down again. A track is
/// hundreds of segments, several are fetched at once, and many tracks download
/// in parallel, so that works out at thousands of spawns a minute with the
/// setup and teardown landing on the UI isolate. It costs more than the
/// decryption it was meant to move.
///
/// The pool spawns once, sized to the machine rather than to how many
/// downloads are running, and segments queue for a free worker. That also caps
/// the CPU the decryption can take: work arriving faster than the cores can
/// clear it waits instead of piling more isolates on.
class DecryptPool {
  DecryptPool({int? workers})
    : size = (workers ?? Platform.numberOfProcessors - 1).clamp(1, 8);

  final int size;

  final List<_Worker> _workers = [];
  final Queue<_Worker> _idle = Queue();
  final Queue<Completer<_Worker>> _waiting = Queue();

  Future<void>? _startup;
  bool _closed = false;

  int get idleCount => _idle.length;
  int get workerCount => _workers.length;

  Future<Uint8List> decrypt(Uint8List payload, StreamKey key) async {
    if (_closed) throw StateError('decrypt pool is closed');
    await (_startup ??= _start());

    final worker = await _acquire();
    try {
      return await worker.decrypt(payload, key);
    } finally {
      _release(worker);
    }
  }

  Future<void> _start() async {
    for (var i = 0; i < size; i++) {
      if (_closed) return;
      final worker = await _Worker.spawn();
      _workers.add(worker);
      _release(worker);
    }
  }

  Future<_Worker> _acquire() {
    if (_idle.isNotEmpty) return Future.value(_idle.removeFirst());
    final waiter = Completer<_Worker>();
    _waiting.add(waiter);
    return waiter.future;
  }

  /// Hands the worker to the next caller in line, or back to the pool. It is
  /// not returned to [_idle] while anyone is waiting: it changes owner.
  void _release(_Worker worker) {
    if (_closed) {
      worker.close();
      return;
    }
    if (_waiting.isEmpty) {
      _idle.add(worker);
      return;
    }
    _waiting.removeFirst().complete(worker);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final worker in _workers) {
      worker.close();
    }
    _workers.clear();
    _idle.clear();
    for (final waiter in _waiting) {
      waiter.completeError(StateError('decrypt pool is closed'));
    }
    _waiting.clear();
  }
}

class _Worker {
  _Worker(this._isolate, this._send);

  final Isolate _isolate;
  final SendPort _send;

  static Future<_Worker> spawn() async {
    final handshake = ReceivePort();
    final isolate = await Isolate.spawn(
      _main,
      handshake.sendPort,
      debugName: 'segment-decrypt',
    );
    final send = await handshake.first as SendPort;
    handshake.close();
    return _Worker(isolate, send);
  }

  /// One request at a time; the pool guarantees that by handing a worker to a
  /// single caller. The reply port is per request, which is cheap, unlike an
  /// isolate.
  Future<Uint8List> decrypt(Uint8List payload, StreamKey key) async {
    final reply = ReceivePort();
    _send.send((payload, key.value, key.iv, reply.sendPort));
    try {
      final result = await reply.first;
      if (result is Uint8List) return result;
      throw HlsException('$result');
    } finally {
      reply.close();
    }
  }

  void close() => _isolate.kill(priority: Isolate.immediate);

  static void _main(SendPort handshake) {
    final requests = ReceivePort();
    handshake.send(requests.sendPort);

    requests.listen((message) {
      final (payload, value, iv, reply) =
          message as (Uint8List, Uint8List, Uint8List, SendPort);
      try {
        reply.send(decryptSegment(payload, StreamKey(value: value, iv: iv)));
      } on Object catch (error) {
        // Errors cannot cross as exceptions, so they come back as text and
        // are rethrown on the calling side.
        reply.send(error.toString());
      }
    });
  }
}

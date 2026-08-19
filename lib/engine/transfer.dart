library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'hls.dart';
import 'request_limiter.dart';

/// Byte transfers on worker isolates, off the isolate that draws the UI.
///
/// The downloader used to run every transfer where the UI lives: each HTTP
/// body, the copy of every segment to the decrypt pool and back, and every
/// file write shared one event loop with rendering. At full rate that is
/// hundreds of byte-shuffling events a second, which is why the window took
/// seconds to restore from the taskbar and why throughput sank as the session
/// piled more bookkeeping onto the same loop.
///
/// A [TransferPool] keeps a few long-lived worker isolates. The UI isolate
/// resolves what to fetch (the catalog calls need its auth) and hands a
/// [TransferSpec] of plain values to a worker, which fetches, decrypts,
/// writes and remuxes entirely on its own thread. Only compact progress
/// messages cross back, throttled to [transferProgressByteStep].

enum TransferKind {
  /// One plain HTTP body written to a file: a direct download or a sample.
  body,

  /// An HLS playlist: segments fetched in a sliding window, decrypted, and
  /// remuxed with ffmpeg when a tool is available.
  stream,
}

/// Everything a worker needs to move one track, resolved on the UI isolate
/// where the catalog and its tokens live. Plain values only, so the spec
/// crosses the isolate boundary as a cheap copy.
class TransferSpec {
  const TransferSpec({
    required this.kind,
    required this.url,
    required this.directoryPath,
    required this.baseName,
    this.extension = '',
    this.metadataArgs = const [],
    this.ffmpegTool,
    this.segmentWindow = 6,
  });

  final TransferKind kind;
  final String url;
  final String directoryPath;

  /// File name without extension. A [TransferKind.body] transfer appends
  /// [extension]; a stream writes `.aac` and remuxes to `.m4a`.
  final String baseName;

  final String extension;

  /// Pre-rendered `-metadata` flags for the remux; the worker has no access
  /// to the track object they were built from.
  final List<String> metadataArgs;

  /// Resolved ffmpeg path, or null to keep the raw transport file.
  final String? ffmpegTool;

  final int segmentWindow;
}

/// Progress for one transfer. [bytes] is cumulative, so a consumer can meter
/// throughput from deltas no matter how many updates were coalesced.
class TransferUpdate {
  const TransferUpdate({
    required this.id,
    required this.completed,
    required this.total,
    required this.bytes,
    required this.segmented,
  });

  final int id;
  final int completed;
  final int total;
  final int bytes;
  final bool segmented;
}

class TransferOutcome {
  const TransferOutcome({required this.path, required this.remuxed});

  final String path;
  final bool remuxed;
}

/// How many bytes a worker accumulates before sending a progress message.
/// Small enough that a progress bar still moves, large enough that the UI
/// isolate sees a few messages a second per track instead of every chunk.
const int transferProgressByteStep = 256 * 1024;

class Cancellation {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  /// Runs [listener] when the cancel lands, or immediately if it already has.
  /// This is how a cancel reaches a transfer running on another isolate.
  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void throwIfCancelled() {
    if (_cancelled) throw const DownloadCancelled();
  }
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();

  @override
  String toString() => 'download cancelled';
}

/// Yields the first [count] payloads of [segments] in playlist order while
/// keeping [window] fetches in flight.
///
/// This used to take segments in batches behind a Future.wait, so the
/// slowest segment of every batch idled the connection for everything
/// behind it. Measured against Beatport's CDN that barrier cost a factor of
/// twelve: the same segments over the same connection moved at 2.5 MB/s
/// batched and 30 MB/s with the window kept full. Now a replacement fetch
/// starts the moment any fetch lands, and playlist order is restored by
/// consuming index by index, so the bytes written are identical to the
/// sequential ones.
Stream<Uint8List> orderedSegmentPayloads({
  required List<Uri> segments,
  required int count,
  required int window,
  required Future<Uint8List> Function(Uri url, int index) fetch,
  Cancellation? cancellation,
}) async* {
  final width = window < 1 ? 1 : window;

  // A slow segment at the front must not buffer the whole rest of the track
  // behind it, so fetching pauses once this many payloads are outstanding.
  final buffered = width * 4;

  final pending = <int, Future<Uint8List>>{};
  var inFlight = 0;
  var started = 0;
  var closed = false;

  void fill() {
    while (!closed &&
        started < count &&
        inFlight < width &&
        pending.length < buffered) {
      final index = started;
      started += 1;
      final request = fetch(segments[index], index);
      pending[index] = request;
      inFlight += 1;
      // The refill listener must not re-raise the fetch's error: that
      // belongs to the consumer awaiting the entry in [pending].
      unawaited(
        request.then((_) {}, onError: (_) {}).whenComplete(() {
          inFlight -= 1;
          fill();
        }),
      );
    }
  }

  try {
    fill();
    for (var index = 0; index < count; index++) {
      cancellation?.throwIfCancelled();
      final payload = await pending.remove(index)!;
      fill();
      yield payload;
    }
  } finally {
    // Bailing out part-way, on an error or a cancel, leaves later fetches
    // in flight. Their results are unwanted but their failures still need a
    // listener, or they surface as unhandled asynchronous errors.
    closed = true;
    for (final orphan in pending.values) {
      unawaited(orphan.then((_) {}, onError: (_) {}));
    }
  }
}

/// Stream-copies [input] to [output] through ffmpeg, applying [metadataArgs].
Future<void> runFfmpegRemux(
  String tool,
  File input,
  File output,
  List<String> metadataArgs,
) async {
  final result = await Process.run(tool, [
    '-y',
    '-i',
    input.path,
    '-map_metadata',
    '-1',
    ...metadataArgs,
    '-c:a',
    'copy',
    output.path,
  ]);
  if (result.exitCode != 0) {
    await output.delete().catchError((_) => output);
    final detail = result.stderr.toString().trim();
    throw Exception(
      'ffmpeg failed with exit code ${result.exitCode}'
      '${detail.isEmpty ? '' : ': ${detail.split('\n').last}'}',
    );
  }
}

/// A fixed set of long-lived worker isolates executing [TransferSpec]s.
///
/// Workers multiplex transfers on their own event loops, so the pool is sized
/// to spread the decrypt CPU rather than to the download concurrency: a
/// handful of workers carries any number of parallel tracks.
class TransferPool {
  TransferPool({int? workers, int totalSegmentSlots = 64})
    : size = (workers ?? Platform.numberOfProcessors ~/ 2).clamp(2, 4),
      _totalSegmentSlots = totalSegmentSlots;

  final int size;
  final int _totalSegmentSlots;

  final List<_PoolWorker> _workers = [];
  final Map<int, _PoolJob> _jobs = {};
  int _nextId = 0;

  Future<void>? _startup;
  bool _closed = false;

  /// Runs [spec] on the least-loaded worker, relaying its progress to
  /// [onProgress] and completing with the outcome or the transfer's error
  /// rebuilt as the exception type the caller's retry logic expects.
  Future<TransferOutcome> run(
    TransferSpec spec, {
    void Function(TransferUpdate)? onProgress,
    Cancellation? cancellation,
  }) async {
    if (_closed) throw StateError('transfer pool is closed');
    cancellation?.throwIfCancelled();
    await (_startup ??= _start());
    if (_closed) throw StateError('transfer pool is closed');

    // Checked again with no awaits before the send below: a cancel landing
    // during startup must fail here rather than fire the relay before the
    // worker has even been handed the job.
    cancellation?.throwIfCancelled();

    var worker = _workers.first;
    for (final candidate in _workers) {
      if (candidate.load < worker.load) worker = candidate;
    }

    final id = _nextId++;
    final job = _PoolJob(onProgress);
    _jobs[id] = job;
    worker.load += 1;

    void relayCancel() => worker.send(id);
    cancellation?.addListener(relayCancel);
    worker.send(_Run(id, spec));
    try {
      return await job.completer.future;
    } finally {
      cancellation?.removeListener(relayCancel);
      worker.load -= 1;
      _jobs.remove(id);
    }
  }

  Future<void> _start() async {
    final slots = _totalSegmentSlots ~/ size;
    for (var i = 0; i < size; i++) {
      if (_closed) return;
      _workers.add(await _PoolWorker.spawn(slots, _onMessage));
    }
  }

  void _onMessage(Object? message) {
    switch (message) {
      case TransferUpdate update:
        _jobs[update.id]?.onProgress?.call(update);
      case _Done done:
        _jobs[done.id]?.completer.complete(
          TransferOutcome(path: done.path, remuxed: done.remuxed),
        );
      case _Fail fail:
        _jobs[fail.id]?.completer.completeError(fail.rebuild());
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final worker in _workers) {
      worker.close();
    }
    _workers.clear();
    for (final job in _jobs.values) {
      if (!job.completer.isCompleted) {
        job.completer.completeError(StateError('transfer pool is closed'));
      }
    }
    _jobs.clear();
  }
}

class _PoolJob {
  _PoolJob(this.onProgress);

  final Completer<TransferOutcome> completer = Completer();
  final void Function(TransferUpdate)? onProgress;
}

class _PoolWorker {
  _PoolWorker(this._isolate, this._send, this._port);

  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _port;

  /// Transfers currently assigned here, used to spread new work.
  int load = 0;

  static Future<_PoolWorker> spawn(
    int segmentSlots,
    void Function(Object?) onMessage,
  ) async {
    final port = ReceivePort();
    final ready = Completer<SendPort>();
    port.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      onMessage(message);
    });
    final isolate = await Isolate.spawn(_workerMain, (
      port.sendPort,
      segmentSlots,
    ), debugName: 'transfer-worker');
    return _PoolWorker(isolate, await ready.future, port);
  }

  void send(Object message) => _send.send(message);

  void close() {
    _isolate.kill(priority: Isolate.immediate);
    _port.close();
  }
}

class _Run {
  const _Run(this.id, this.spec);

  final int id;
  final TransferSpec spec;
}

class _Done {
  const _Done(this.id, this.path, this.remuxed);

  final int id;
  final String path;
  final bool remuxed;
}

/// A transfer error flattened to values that cross the isolate boundary,
/// carrying enough to rebuild the original type: the queue's retry logic
/// tells transient failures from refusals by exception type and status.
class _Fail {
  const _Fail(this.id, this.kind, this.status, this.message);

  final int id;
  final String kind;
  final int? status;
  final String message;

  static _Fail from(int id, Object error) => switch (error) {
    DownloadCancelled() => _Fail(id, 'cancelled', null, ''),
    BeatportException(:final status, :final message) => _Fail(
      id,
      'beatport',
      status,
      message,
    ),
    HlsException(:final message) => _Fail(id, 'hls', null, message),
    SocketException() => _Fail(id, 'socket', null, error.message),
    http.ClientException(:final message) => _Fail(id, 'http', null, message),
    _ => _Fail(id, 'other', null, error.toString()),
  };

  Object rebuild() => switch (kind) {
    'cancelled' => const DownloadCancelled(),
    'beatport' => BeatportException(status ?? 0, message),
    'hls' => HlsException(message),
    'socket' => SocketException(message),
    'http' => http.ClientException(message),
    _ => Exception(message),
  };
}

void _workerMain((SendPort, int) config) {
  final (results, segmentSlots) = config;
  final commands = ReceivePort();
  results.send(commands.sendPort);

  final client = http.Client();
  final segments = RequestLimiter(segmentSlots);

  // One remux at a time per worker: spawning ffmpeg is the expensive part,
  // more so on Windows, and across the pool this still allows one process
  // per worker.
  final remuxes = RequestLimiter(1);
  final active = <int, Cancellation>{};

  commands.listen((message) {
    switch (message) {
      case _Run run:
        final cancellation = Cancellation();
        active[run.id] = cancellation;
        unawaited(
          _execute(
            run,
            client,
            segments,
            remuxes,
            cancellation,
            results,
          ).whenComplete(() => active.remove(run.id)),
        );
      case int id:
        active[id]?.cancel();
    }
  });
}

Future<void> _execute(
  _Run run,
  http.Client client,
  RequestLimiter segments,
  RequestLimiter remuxes,
  Cancellation cancellation,
  SendPort results,
) async {
  try {
    final outcome = switch (run.spec.kind) {
      TransferKind.body => await _executeBody(
        run,
        client,
        cancellation,
        results,
      ),
      TransferKind.stream => await _executeStream(
        run,
        client,
        segments,
        remuxes,
        cancellation,
        results,
      ),
    };
    results.send(_Done(run.id, outcome.path, outcome.remuxed));
  } on Object catch (error) {
    results.send(_Fail.from(run.id, error));
  }
}

Future<TransferOutcome> _executeBody(
  _Run run,
  http.Client client,
  Cancellation cancellation,
  SendPort results,
) async {
  final spec = run.spec;
  cancellation.throwIfCancelled();
  final directory = Directory(spec.directoryPath);
  await directory.create(recursive: true);
  final target = File(
    '${directory.path}${Platform.pathSeparator}${spec.baseName}${spec.extension}',
  );

  final response = await client.send(http.Request('GET', Uri.parse(spec.url)));
  if (response.statusCode != 200) {
    final reason = response.reasonPhrase?.trim() ?? '';
    throw BeatportException(
      response.statusCode,
      reason.isEmpty ? 'download failed' : 'download failed: $reason',
    );
  }

  final total = response.contentLength ?? 0;
  var received = 0;
  var lastSent = 0;
  final sink = target.openWrite();
  try {
    await for (final chunk in response.stream) {
      cancellation.throwIfCancelled();
      sink.add(chunk);
      received += chunk.length;
      if (received - lastSent >= transferProgressByteStep) {
        lastSent = received;
        results.send(
          TransferUpdate(
            id: run.id,
            completed: received,
            total: total,
            bytes: received,
            segmented: false,
          ),
        );
      }
    }
    await sink.flush();
    await sink.close();
  } on Object {
    await sink.close().catchError((_) {});
    await target.delete().catchError((_) => target);
    rethrow;
  }

  results.send(
    TransferUpdate(
      id: run.id,
      completed: received,
      total: total,
      bytes: received,
      segmented: false,
    ),
  );
  return TransferOutcome(path: target.path, remuxed: true);
}

Future<TransferOutcome> _executeStream(
  _Run run,
  http.Client client,
  RequestLimiter segments,
  RequestLimiter remuxes,
  Cancellation cancellation,
  SendPort results,
) async {
  final spec = run.spec;
  final (playlist, key) = await loadStream(
    Uri.parse(spec.url),
    httpClient: client,
  );
  cancellation.throwIfCancelled();

  final directory = Directory(spec.directoryPath);
  await directory.create(recursive: true);
  final transport = File(
    '${directory.path}${Platform.pathSeparator}${spec.baseName}.aac',
  );

  final list = playlist.segments;
  final sink = transport.openWrite();
  var bytes = 0;
  var lastSent = 0;
  var done = 0;
  try {
    await for (final payload in orderedSegmentPayloads(
      segments: list,
      count: list.length,
      window: spec.segmentWindow,
      fetch: (url, index) async {
        final body = await segments.run(() async {
          final response = await client.get(url);
          if (response.statusCode != 200) {
            throw BeatportException(
              response.statusCode,
              'segment ${index + 1} failed',
            );
          }
          return response.bodyBytes;
        });
        // Decrypted right here on the worker: no hop to a decrypt pool, no
        // copy of the payload across an extra isolate boundary, and the CPU
        // it costs lands on this thread instead of the UI's.
        return key == null ? body : decryptSegment(body, key);
      },
      cancellation: cancellation,
    )) {
      sink.add(payload);
      bytes += payload.length;
      done += 1;
      if (bytes - lastSent >= transferProgressByteStep || done == list.length) {
        lastSent = bytes;
        results.send(
          TransferUpdate(
            id: run.id,
            completed: done,
            total: list.length,
            bytes: bytes,
            segmented: true,
          ),
        );
      }
    }
    await sink.flush();
    await sink.close();
  } on Object {
    await sink.close().catchError((_) {});
    await transport.delete().catchError((_) => transport);
    rethrow;
  }

  final tool = spec.ffmpegTool;
  if (tool == null) {
    return TransferOutcome(path: transport.path, remuxed: false);
  }

  final output = File(
    '${directory.path}${Platform.pathSeparator}${spec.baseName}.m4a',
  );
  await remuxes.run(
    () => runFfmpegRemux(tool, transport, output, spec.metadataArgs),
  );
  await transport.delete().catchError((_) => transport);
  return TransferOutcome(path: output.path, remuxed: true);
}

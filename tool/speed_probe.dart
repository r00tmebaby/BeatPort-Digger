/// Measures where download throughput is actually lost.
///
/// The app reads at most eleven megabytes a second on a line that carries a
/// hundred, and the downloader has enough moving parts (per-connection CDN
/// limits, the app-wide segment window, the decrypt pool) that guessing is
/// pointless. This probe talks to Beatport with raw sockets and times each
/// stage in isolation:
///
///   1. one direct-download connection, to get the CDN's per-connection rate
///   2. several distinct tracks in parallel, to see whether connections scale
///      or an IP-level throttle flattens them
///   3. HLS segments fetched the way the downloader does (batches with a
///      barrier) against a rolling window, to price the barrier
///   4. AES-CBC decryption on this machine, to see whether the pool can keep
///      up with the network
///
/// Authenticates from the same cached-token file the live tests use
/// (BPCAT_CREDENTIALS, falling back to ~/.config/bpcat/bpcat-token.json).
/// Run with: dart run tool/speed_probe.dart
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:beatport_digger/engine/auth.dart';
import 'package:beatport_digger/engine/catalog.dart';
import 'package:beatport_digger/engine/client.dart';
import 'package:beatport_digger/engine/errors.dart';
import 'package:beatport_digger/engine/hls.dart';
import 'package:beatport_digger/engine/token.dart';
import 'package:http/http.dart' as http;

const int singleCap = 32 * 1024 * 1024;
const int parallelCap = 12 * 1024 * 1024;

void heading(String text) => stdout.writeln('\n== $text ==');
void line(String text) => stdout.writeln('   $text');

String mbps(int bytes, Duration elapsed) {
  final micros = elapsed.inMicroseconds;
  if (micros == 0) return '?';
  return (bytes / 1024 / 1024 * 1e6 / micros).toStringAsFixed(1);
}

class FetchResult {
  FetchResult(this.bytes, this.firstByte, this.total);

  final int bytes;
  final Duration firstByte;
  final Duration total;

  /// Rate over the body transfer alone, so API and TLS setup latency does not
  /// flatter or damn the connection.
  Duration get body => total - firstByte;
}

/// Reads [url] until [cap] bytes have arrived, then tears the socket down.
/// A range header asks the server to stop at the cap; servers that ignore it
/// and answer 200 are cut off client-side instead.
Future<FetchResult> fetchCapped(Uri url, int cap) async {
  final client = HttpClient();
  final watch = Stopwatch()..start();
  Duration? firstByte;
  var bytes = 0;
  try {
    final request = await client.getUrl(url);
    request.headers.set('range', 'bytes=0-${cap - 1}');
    final response = await request.close();
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    final done = Completer<void>();
    late StreamSubscription<List<int>> tap;
    tap = response.listen(
      (chunk) {
        firstByte ??= watch.elapsed;
        bytes += chunk.length;
        if (bytes >= cap) {
          tap.cancel();
          if (!done.isCompleted) done.complete();
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object error) {
        if (!done.isCompleted) done.completeError(error);
      },
      cancelOnError: true,
    );
    await done.future;
    watch.stop();
    return FetchResult(bytes, firstByte ?? watch.elapsed, watch.elapsed);
  } finally {
    client.close(force: true);
  }
}

/// Fetches every segment with at most [window] requests in flight, replacing
/// each as it lands. This is the shape the downloader should have.
Future<(int, Duration)> fetchRolling(List<Uri> segments, int window) async {
  final client = HttpClient();
  final watch = Stopwatch()..start();
  var bytes = 0;
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= segments.length) return;
      final request = await client.getUrl(segments[index]);
      final response = await request.close();
      await for (final chunk in response) {
        bytes += chunk.length;
      }
    }
  }

  try {
    await Future.wait([
      for (var i = 0; i < math.min(window, segments.length); i++) worker(),
    ]);
    watch.stop();
    return (bytes, watch.elapsed);
  } finally {
    client.close(force: true);
  }
}

/// Fetches segments the way downloadStream does today: a batch of [window]
/// behind Future.wait, then the next, so the slowest segment gates each batch.
Future<(int, Duration)> fetchBatched(List<Uri> segments, int window) async {
  final client = HttpClient();
  final watch = Stopwatch()..start();
  var bytes = 0;
  Future<int> one(Uri url) async {
    final request = await client.getUrl(url);
    final response = await request.close();
    var got = 0;
    await for (final chunk in response) {
      got += chunk.length;
    }
    return got;
  }

  try {
    for (var start = 0; start < segments.length; start += window) {
      final end = math.min(start + window, segments.length);
      final batch = await Future.wait([
        for (var i = start; i < end; i++) one(segments[i]),
      ]);
      bytes += batch.fold<int>(0, (sum, b) => sum + b);
    }
    watch.stop();
    return (bytes, watch.elapsed);
  } finally {
    client.close(force: true);
  }
}

Future<void> main() async {
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
  final tokenPath =
      Platform.environment['BPCAT_CREDENTIALS'] ??
      '$home${Platform.pathSeparator}.config'
          '${Platform.pathSeparator}bpcat'
          '${Platform.pathSeparator}bpcat-token.json';

  final httpClient = http.Client();
  final auth = Authenticator(
    httpClient: httpClient,
    store: FileTokenStore(tokenPath),
  );

  try {
    heading('1. Session');
    final cached = await auth.loadCached();
    var ready = cached != null && !cached.isExpired();
    if (cached != null && cached.isExpired()) {
      line('cached token expired, refreshing');
      ready = await auth.refresh();
    }
    if (!ready) {
      final username = Platform.environment['BEATPORT_USERNAME'];
      final password = Platform.environment['BEATPORT_PASSWORD'];
      if (username == null || password == null) {
        stderr.writeln(
          'No usable session: cached token at $tokenPath is gone or stale '
          'and BEATPORT_USERNAME/BEATPORT_PASSWORD are not set.',
        );
        exitCode = 2;
        return;
      }
      line('logging in as $username');
      await auth.logIn(username, password);
    }
    line('session ready');

    final catalog = Catalog(BeatportClient(auth: auth, httpClient: httpClient));

    heading('2. Collect download URLs');
    final page = await catalog.tracks(TrackQuery(perPage: 30));
    final ids = [for (final track in page.results) track.id!];
    line('tracks fetched: ${ids.length}');

    final urls = <Uri>[];
    for (final id in ids) {
      if (urls.length >= 16) break;
      try {
        final download = await catalog.trackDownload(id, 'lossless');
        if (download.location.isNotEmpty) {
          urls.add(Uri.parse(download.location));
        }
      } on BeatportException catch (exception) {
        line('track $id refused: HTTP ${exception.status}');
        break;
      }
    }
    line('download URLs signed: ${urls.length}');
    if (urls.isNotEmpty) line('CDN host: ${urls.first.host}');

    if (urls.isNotEmpty) {
      heading('3. Single connection (direct download path)');
      final single = await fetchCapped(urls.first, singleCap);
      line(
        '${single.bytes ~/ 1024 ~/ 1024} MB in '
        '${single.total.inMilliseconds} ms, first byte after '
        '${single.firstByte.inMilliseconds} ms',
      );
      line('per-connection rate: ${mbps(single.bytes, single.body)} MB/s');

      for (final width in [4, 8, 16]) {
        if (urls.length < width) break;
        heading('4. $width parallel connections, distinct tracks');
        final watch = Stopwatch()..start();
        final results = await Future.wait([
          for (var i = 0; i < width; i++) fetchCapped(urls[i], parallelCap),
        ]);
        watch.stop();
        final total = results.fold<int>(0, (sum, r) => sum + r.bytes);
        final each = [
          for (final r in results) mbps(r.bytes, r.body),
        ].join(', ');
        line('aggregate: ${mbps(total, watch.elapsed)} MB/s');
        line('per connection: $each');
      }
    }

    heading('5. HLS stream path');
    List<Uri> segments = const [];
    StreamKey? key;
    try {
      final stream = await catalog.trackStream(ids.first);
      final (playlist, streamKey) = await loadStream(
        Uri.parse(stream.url),
        httpClient: httpClient,
      );
      segments = playlist.segments;
      key = streamKey;
      line('segments in playlist: ${segments.length}');
    } on Object catch (exception) {
      line('stream unavailable: $exception');
    }

    if (segments.isNotEmpty) {
      final sample = segments.take(96).toList();

      final (batchBytes, batchTime) = await fetchBatched(sample, 6);
      line(
        'batched window 6 (today): ${mbps(batchBytes, batchTime)} MB/s '
        '(${sample.length} segments, avg '
        '${batchBytes ~/ sample.length ~/ 1024} KB)',
      );

      final (rollBytes, rollTime) = await fetchRolling(sample, 6);
      line('rolling window 6: ${mbps(rollBytes, rollTime)} MB/s');

      final (wideBytes, wideTime) = await fetchRolling(sample, 24);
      line('rolling window 24: ${mbps(wideBytes, wideTime)} MB/s');

      if (key != null) {
        heading('6. AES-CBC decrypt speed (one core, pointycastle)');
        final client = HttpClient();
        final bodies = <Uint8List>[];
        try {
          for (final url in sample.take(12)) {
            final request = await client.getUrl(url);
            final response = await request.close();
            final builder = BytesBuilder(copy: false);
            await for (final chunk in response) {
              builder.add(chunk);
            }
            bodies.add(builder.takeBytes());
          }
        } finally {
          client.close(force: true);
        }
        final watch = Stopwatch()..start();
        var decrypted = 0;
        for (final body in bodies) {
          decrypted += decryptSegment(body, key).length;
        }
        watch.stop();
        line('decrypted $decrypted bytes');
        line('single-core rate: ${mbps(decrypted, watch.elapsed)} MB/s');
        line(
          'pool of ${(Platform.numberOfProcessors - 1).clamp(1, 8)} workers '
          'tops out near '
          '${(decrypted / 1024 / 1024 * 1e6 / watch.elapsedMicroseconds * (Platform.numberOfProcessors - 1).clamp(1, 8)).toStringAsFixed(0)}'
          ' MB/s',
        );
      }
    }
  } finally {
    httpClient.close();
  }
}

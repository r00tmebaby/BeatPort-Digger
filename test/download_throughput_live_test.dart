@Tags(['live'])
library;

import 'dart:io';

import 'package:beatport_digger/engine/auth.dart';
import 'package:beatport_digger/engine/catalog.dart';
import 'package:beatport_digger/engine/client.dart';
import 'package:beatport_digger/engine/download.dart';
import 'package:beatport_digger/engine/ffmpeg.dart';
import 'package:beatport_digger/engine/token.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Skips the remux so the measurement is the segment pipeline alone; ffmpeg
/// would only add a constant per track and a dependency on the machine.
class _NoFfmpeg extends Ffmpeg {
  @override
  Future<String?> resolve() async => null;
}

/// Measures what the real downloader moves over the stream path, printed
/// rather than asserted: the point is a number to compare across changes,
/// and a CDN's mood is not something to fail CI over.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  HttpOverrides.global = null;

  final pluginTemp = Directory.systemTemp.createTempSync('bpbench-support');
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => pluginTemp.path,
  );

  final credentials = Platform.environment['BPCAT_CREDENTIALS'];
  final available = credentials != null && File(credentials).existsSync();

  test(
    'aggregate stream throughput at four and eight parallel tracks',
    () async {
      if (!available) return markTestSkipped('no credentials');

      final client = http.Client();
      final auth = Authenticator(
        httpClient: client,
        store: FileTokenStore(credentials),
      );
      await auth.loadCached();
      final catalog = Catalog(BeatportClient(auth: auth, httpClient: client));
      final temp = await Directory.systemTemp.createTemp('bpbench');

      try {
        final page = await catalog.tracks(TrackQuery(perPage: 40));
        final tracks = page.results;
        var offset = 0;

        for (final width in [4, 8]) {
          final slice = tracks.skip(offset).take(width * 3).toList();
          offset += slice.length;
          if (slice.length < width) break;

          final downloader = Downloader(
            catalog: catalog,
            httpClient: client,
            ffmpeg: _NoFfmpeg(),
          );
          var bytes = 0;
          var failed = 0;
          var next = 0;
          final watch = Stopwatch()..start();

          Future<void> worker() async {
            while (true) {
              final index = next++;
              if (index >= slice.length) return;
              var last = 0;
              try {
                await downloader.downloadTrack(
                  slice[index],
                  temp,
                  quality: AudioQuality.hls,
                  onProgress: (progress) {
                    bytes += progress.bytes - last;
                    last = progress.bytes;
                  },
                );
              } on Object {
                failed += 1;
              }
            }
          }

          await Future.wait([for (var i = 0; i < width; i++) worker()]);
          watch.stop();

          final rate = bytes / 1024 / 1024 * 1e6 / watch.elapsedMicroseconds;
          // ignore: avoid_print
          print(
            '$width tracks in parallel: ${rate.toStringAsFixed(1)} MB/s '
            'aggregate over ${slice.length} tracks '
            '(${bytes ~/ 1024 ~/ 1024} MB, $failed failed, '
            '${watch.elapsedMilliseconds} ms)',
          );
          expect(failed, lessThan(slice.length), reason: 'nothing downloaded');
        }
      } finally {
        client.close();
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

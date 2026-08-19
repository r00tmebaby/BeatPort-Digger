import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:beatport_digger/engine/auth.dart';
import 'package:beatport_digger/engine/catalog.dart';
import 'package:beatport_digger/engine/client.dart';
import 'package:beatport_digger/engine/download.dart';
import 'package:beatport_digger/engine/ffmpeg.dart';
import 'package:beatport_digger/engine/token.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryTokenStore implements TokenStore {
  TokenPair? stored;

  @override
  Future<TokenPair?> read() async => stored;

  @override
  Future<void> write(TokenPair token) async => stored = token;

  @override
  Future<void> clear() async => stored = null;
}

/// Keeps the downloader on the raw transport file, so the tests read the
/// exact bytes the segment pipeline wrote rather than ffmpeg's output.
class _NoFfmpeg extends Ffmpeg {
  @override
  Future<String?> resolve() async => null;
}

/// A stream host whose segments complete only when the test says so, which
/// makes the fetch schedule observable: [served] records the order requests
/// arrived, and [release]/[fail] decide when and how each one answers.
class _SegmentHost {
  _SegmentHost(int segments)
    : _gates = List.generate(segments, (_) => Completer<void>());

  final List<Completer<void>> _gates;
  final List<int> served = [];

  static List<int> payload(int index) => utf8.encode('segment-$index|');

  String get playlist => [
    '#EXTM3U',
    for (var i = 0; i < _gates.length; i++) ...['#EXTINF:4,', 'seg$i.ts'],
    '#EXT-X-ENDLIST',
  ].join('\n');

  void release(int index) => _gates[index].complete();

  void fail(int index, Object error) => _gates[index].completeError(error);

  http.Client client() => MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/stream/')) {
      return http.Response(
        '{"stream_url": "https://cdn.test/api/list.m3u8"}',
        200,
      );
    }
    if (path.endsWith('.m3u8')) return http.Response(playlist, 200);
    final index = int.parse(
      RegExp(r'seg(\d+)\.ts$').firstMatch(path)!.group(1)!,
    );
    served.add(index);
    await _gates[index].future;
    return http.Response.bytes(payload(index), 200);
  });
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('segment-pipeline');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Downloader downloader(_SegmentHost host, {int window = 2}) {
    final client = host.client();
    final auth = Authenticator(httpClient: client, store: _MemoryTokenStore())
      ..token = const TokenPair(accessToken: 'test-access');
    return Downloader(
      catalog: Catalog(BeatportClient(auth: auth, httpClient: client)),
      httpClient: client,
      ffmpeg: _NoFfmpeg(),
      segmentConcurrency: window,
    );
  }

  test('the window advances past a stalled segment', () async {
    final host = _SegmentHost(5);
    final result = downloader(
      host,
    ).downloadStream(Uri.parse('https://cdn.test/a/list.m3u8'), temp, 'track');

    await pumpEventQueue();
    expect(host.served, [0, 1], reason: 'window of two starts two fetches');

    // Segment 0 never lands, yet finishing 1 must pull 2 into flight. The
    // old batched loop sat here waiting for 0 before asking for anything
    // else, which is what held the whole path to a fraction of the line.
    host.release(1);
    await pumpEventQueue();
    expect(host.served, [0, 1, 2]);

    host.release(2);
    await pumpEventQueue();
    host.release(3);
    await pumpEventQueue();
    expect(
      host.served,
      [0, 1, 2, 3, 4],
      reason: 'every later segment is fetched while 0 is still pending',
    );

    host.release(4);
    host.release(0);
    await result;
  });

  test('bytes land in playlist order however fetches complete', () async {
    final host = _SegmentHost(5);
    final result = downloader(
      host,
      window: 3,
    ).downloadStream(Uri.parse('https://cdn.test/b/list.m3u8'), temp, 'track');

    // Answer in the most hostile order the window allows.
    await pumpEventQueue();
    host.release(2);
    await pumpEventQueue();
    host.release(4);
    await pumpEventQueue();
    host.release(1);
    await pumpEventQueue();
    host.release(3);
    await pumpEventQueue();
    host.release(0);

    final download = await result;
    expect(download.remuxed, isFalse);
    final expected = [for (var i = 0; i < 5; i++) ..._SegmentHost.payload(i)];
    expect(await File(download.path).readAsBytes(), expected);
  });

  test('a failed segment fails the download and removes the file', () async {
    final host = _SegmentHost(4);
    final result = downloader(
      host,
    ).downloadStream(Uri.parse('https://cdn.test/c/list.m3u8'), temp, 'track');

    await pumpEventQueue();
    host.release(0);
    host.fail(1, const SocketException('connection reset'));

    await expectLater(result, throwsA(isA<SocketException>()));

    // Fetches the failure orphaned must resolve without taking the test
    // down as unhandled errors.
    host.release(2);
    await pumpEventQueue();
    expect(
      temp.listSync().whereType<File>(),
      isEmpty,
      reason: 'the partial transport file is deleted on failure',
    );
  });

  test('the preview honours the segment budget it was given', () async {
    final host = _SegmentHost(6);
    final result = downloader(host, window: 2).downloadPreview(
      42,
      temp,
      segments: 3,
      onProgress: (progress) => expect(progress.total, 3),
    );

    await pumpEventQueue();
    for (var i = 0; i < 3; i++) {
      host.release(i);
      await pumpEventQueue();
    }

    final preview = await result;
    expect(host.served, hasLength(3), reason: 'only the budget is fetched');
    final expected = [for (var i = 0; i < 3; i++) ..._SegmentHost.payload(i)];
    expect(await preview.file.readAsBytes(), expected);
  });
}

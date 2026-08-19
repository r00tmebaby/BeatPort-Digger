import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:beatport_digger/engine/errors.dart';
import 'package:beatport_digger/engine/hls.dart';
import 'package:beatport_digger/engine/transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

/// The inverse of [decryptSegment], so the local stream host serves segments
/// the way the CDN does: AES-128-CBC with PKCS#7 padding.
Uint8List _encryptSegment(List<int> plain, StreamKey key) {
  final padding = 16 - (plain.length % 16);
  final padded = Uint8List(plain.length + padding)
    ..setAll(0, plain)
    ..fillRange(plain.length, plain.length + padding, padding);

  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key.value), key.iv));
  final output = Uint8List(padded.length);
  for (var offset = 0; offset < padded.length; offset += 16) {
    cipher.processBlock(padded, offset, output, offset);
  }
  return output;
}

/// A real HTTP host on the loopback interface. The pool's workers are whole
/// isolates, so a mocked client cannot reach them; these tests go over an
/// actual socket, which also covers the worker's own client.
class _StreamHost {
  _StreamHost(this.segments)
    : key = StreamKey(
        value: Uint8List.fromList(List.generate(16, (i) => i * 7 & 0xff)),
        iv: Uint8List.fromList(List.generate(16, (i) => i * 3 & 0xff)),
      );

  final int segments;
  final StreamKey key;

  /// Completers that hold gated segments open until the test releases them.
  final Map<int, Completer<void>> gates = {};

  late HttpServer _server;

  static List<int> payload(int index) => utf8.encode('segment-$index-payload|');

  String get _iv =>
      '0x${key.iv.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  String _playlist(String prefix) => [
    '#EXTM3U',
    '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=$_iv',
    for (var i = 0; i < segments; i++) ...['#EXTINF:4,', '${prefix}seg$i.ts'],
    '#EXT-X-ENDLIST',
  ].join('\n');

  Future<Uri> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
    return Uri.parse('http://127.0.0.1:${_server.port}/');
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;
    List<int>? body;

    if (path.endsWith('list.m3u8')) {
      body = utf8.encode(_playlist(''));
    } else if (path.endsWith('gated.m3u8')) {
      body = utf8.encode(_playlist('gated-'));
    } else if (path.endsWith('key.bin')) {
      body = key.value;
    } else if (path.endsWith('body.bin')) {
      body = List<int>.generate(1024 * 1024, (i) => i & 0xff);
    } else if (path.endsWith('refused.bin')) {
      response.statusCode = 403;
      body = const [];
    } else {
      final match = RegExp(r'(gated-)?seg(\d+)\.ts$').firstMatch(path);
      if (match == null) {
        response.statusCode = 404;
        body = const [];
      } else {
        final index = int.parse(match.group(2)!);
        if (match.group(1) != null) {
          await (gates[index] ??= Completer<void>()).future;
        }
        body = _encryptSegment(payload(index), key);
      }
    }

    response.add(body);
    await response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late _StreamHost host;
  late Uri base;
  late TransferPool pool;
  late Directory temp;

  setUp(() async {
    host = _StreamHost(8);
    base = await host.start();
    pool = TransferPool(workers: 2, totalSegmentSlots: 8);
    temp = await Directory.systemTemp.createTemp('transfer-pool');
  });

  tearDown(() async {
    pool.close();
    await host.stop();
    await temp.delete(recursive: true);
  });

  test('a stream lands decrypted, in playlist order, off the caller '
      'isolate', () async {
    final updates = <TransferUpdate>[];
    final outcome = await pool.run(
      TransferSpec(
        kind: TransferKind.stream,
        url: base.resolve('list.m3u8').toString(),
        directoryPath: temp.path,
        baseName: 'track',
      ),
      onProgress: updates.add,
    );

    expect(outcome.remuxed, isFalse, reason: 'no ffmpeg tool was given');
    final expected = [
      for (var i = 0; i < host.segments; i++) ..._StreamHost.payload(i),
    ];
    expect(await File(outcome.path).readAsBytes(), expected);

    expect(updates, isNotEmpty);
    final last = updates.last;
    expect(last.completed, host.segments);
    expect(last.bytes, expected.length, reason: 'bytes are cumulative');
  });

  test('a plain body downloads with cumulative progress', () async {
    final updates = <TransferUpdate>[];
    final outcome = await pool.run(
      TransferSpec(
        kind: TransferKind.body,
        url: base.resolve('body.bin').toString(),
        directoryPath: temp.path,
        baseName: 'sample',
        extension: '.mp3',
      ),
      onProgress: updates.add,
    );

    expect(outcome.path, endsWith('sample.mp3'));
    expect(await File(outcome.path).length(), 1024 * 1024);
    expect(updates.last.bytes, 1024 * 1024);
    for (var i = 1; i < updates.length; i++) {
      expect(updates[i].bytes, greaterThanOrEqualTo(updates[i - 1].bytes));
    }
  });

  test('a refusal crosses back as the exception type retry logic '
      'inspects', () async {
    await expectLater(
      pool.run(
        TransferSpec(
          kind: TransferKind.body,
          url: base.resolve('refused.bin').toString(),
          directoryPath: temp.path,
          baseName: 'refused',
          extension: '.mp3',
        ),
      ),
      throwsA(isA<BeatportException>().having((e) => e.status, 'status', 403)),
    );
    expect(temp.listSync().whereType<File>(), isEmpty);
  });

  test('cancelling reaches the worker and removes the partial file', () async {
    final cancellation = Cancellation();
    final result = pool.run(
      TransferSpec(
        kind: TransferKind.stream,
        url: base.resolve('gated.m3u8').toString(),
        directoryPath: temp.path,
        baseName: 'cancelled',
      ),
      cancellation: cancellation,
    );

    // Let the transfer reach the gated segments, then cancel and release
    // them: the worker must notice the cancel once fetches stop blocking.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    cancellation.cancel();
    for (var i = 0; i < host.segments; i++) {
      (host.gates[i] ??= Completer<void>()).complete();
    }

    await expectLater(result, throwsA(isA<DownloadCancelled>()));
    expect(temp.listSync().whereType<File>(), isEmpty);
  });
}

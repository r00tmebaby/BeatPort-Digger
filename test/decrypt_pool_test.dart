import 'dart:typed_data';

import 'package:beatport_digger/engine/decrypt_pool.dart';
import 'package:beatport_digger/engine/hls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

const int _block = 16;

Uint8List _bytes(int length, int seed) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (i * 7 + seed) % 256]);

/// Encrypts [plain] the way Beatport's HLS segments are, so the pool has
/// something real to undo.
Uint8List _encrypt(Uint8List plain, StreamKey key) {
  final padding = _block - (plain.length % _block);
  final padded = Uint8List(plain.length + padding)
    ..setRange(0, plain.length, plain)
    ..fillRange(plain.length, plain.length + padding, padding);

  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key.value), key.iv));

  final output = Uint8List(padded.length);
  for (var offset = 0; offset < padded.length; offset += _block) {
    cipher.processBlock(padded, offset, output, offset);
  }
  return output;
}

void main() {
  final key = StreamKey(value: _bytes(_block, 3), iv: _bytes(_block, 11));

  test('decrypts a segment off the calling isolate', () async {
    final pool = DecryptPool(workers: 2);
    addTearDown(pool.close);

    final plain = _bytes(4096, 1);
    final restored = await pool.decrypt(_encrypt(plain, key), key);

    expect(restored, plain);
  });

  test('spawns its workers once, not once per segment', () async {
    final pool = DecryptPool(workers: 3);
    addTearDown(pool.close);

    final plain = _bytes(2048, 5);
    final cipher = _encrypt(plain, key);

    await Future.wait([
      for (var i = 0; i < 50; i++) pool.decrypt(cipher, key),
    ]);

    expect(
      pool.workerCount,
      3,
      reason: 'fifty segments must not mean fifty isolates; spawning per '
          'segment is what stalled the app',
    );
  });

  test('every result of a concurrent batch is correct', () async {
    final pool = DecryptPool(workers: 4);
    addTearDown(pool.close);

    final plains = [for (var i = 0; i < 24; i++) _bytes(1024 + i * 16, i)];
    final results = await Future.wait([
      for (final plain in plains) pool.decrypt(_encrypt(plain, key), key),
    ]);

    for (var i = 0; i < plains.length; i++) {
      expect(results[i], plains[i], reason: 'replies must not cross over');
    }
  });

  test('workers go back to the pool after use', () async {
    final pool = DecryptPool(workers: 2);
    addTearDown(pool.close);

    final cipher = _encrypt(_bytes(512, 2), key);
    await pool.decrypt(cipher, key);
    await pool.decrypt(cipher, key);

    expect(pool.idleCount, 2);
  });

  test('a bad segment surfaces as an error, not a hung future', () async {
    final pool = DecryptPool(workers: 1);
    addTearDown(pool.close);

    // Not a whole number of AES blocks.
    await expectLater(
      pool.decrypt(_bytes(30, 0), key),
      throwsA(isA<HlsException>()),
    );

    // The worker is still usable afterwards.
    final plain = _bytes(256, 9);
    expect(await pool.decrypt(_encrypt(plain, key), key), plain);
  });

  test('the worker count is bounded by the machine, not the caller', () {
    expect(DecryptPool(workers: 999).size, 8);
    expect(DecryptPool(workers: 0).size, 1);
    expect(DecryptPool(workers: -4).size, 1);
  });

  test('using a closed pool fails loudly', () async {
    final pool = DecryptPool(workers: 1);
    pool.close();
    await expectLater(
      pool.decrypt(_bytes(16, 0), key),
      throwsA(isA<StateError>()),
    );
  });
}

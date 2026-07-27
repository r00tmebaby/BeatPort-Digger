import 'dart:typed_data';

import 'package:beatport_digger/engine/download.dart';
import 'package:beatport_digger/engine/hls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

/// Encrypts with PKCS#7 padding, mirroring what the segment packager does.
Uint8List encrypt(Uint8List plain, Uint8List key, Uint8List iv) {
  final padding = 16 - (plain.length % 16);
  final padded = Uint8List(plain.length + padding)
    ..setAll(0, plain)
    ..fillRange(plain.length, plain.length + padding, padding);

  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(padded.length);
  for (var offset = 0; offset < padded.length; offset += 16) {
    cipher.processBlock(padded, offset, out, offset);
  }
  return out;
}

void main() {
  final base = Uri.parse(
    'https://stream.beatport.com/audio/1234/playlist.m3u8',
  );

  group('parseMediaPlaylist', () {
    test('reads segments and the key in playback order', () {
      final playlist = parseMediaPlaylist('''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x0102030405060708090a0b0c0d0e0f10
#EXTINF:6.0,
segment0.ts
#EXTINF:6.0,
segment1.ts
#EXT-X-ENDLIST
''', base);

      expect(playlist.segments, [
        Uri.parse('https://stream.beatport.com/audio/1234/segment0.ts'),
        Uri.parse('https://stream.beatport.com/audio/1234/segment1.ts'),
      ]);
      expect(
        playlist.keyUri,
        Uri.parse('https://stream.beatport.com/audio/1234/key.bin'),
      );
      expect(playlist.isEncrypted, isTrue);
      expect(playlist.iv!.first, 0x01);
      expect(playlist.iv!.last, 0x10);
    });

    test('resolves absolute and root-relative URIs against the playlist', () {
      // Concatenating onto the playlist directory would corrupt both of these.
      final playlist = parseMediaPlaylist('''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="https://keys.beatport.com/k/9",IV=0x00
#EXTINF:6.0,
/cdn/segment0.ts
''', base);

      expect(playlist.keyUri, Uri.parse('https://keys.beatport.com/k/9'));
      expect(
        playlist.segments.single,
        Uri.parse('https://stream.beatport.com/cdn/segment0.ts'),
      );
    });

    test('treats METHOD=NONE as unencrypted', () {
      final playlist = parseMediaPlaylist(
        '#EXTM3U\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:6.0,\na.ts\n',
        base,
      );
      expect(playlist.isEncrypted, isFalse);
      expect(playlist.keyUri, isNull);
    });

    test('rejects an encryption method it cannot honour', () {
      // SAMPLE-AES encrypts only parts of each packet. Treating it as AES-128
      // would produce a file that looks complete and is unplayable.
      expect(
        () => parseMediaPlaylist(
          '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="k"\n#EXTINF:6,\na.ts\n',
          base,
        ),
        throwsA(isA<HlsException>()),
      );
    });

    test('rejects a playlist with no segments', () {
      expect(
        () => parseMediaPlaylist('#EXTM3U\n#EXT-X-ENDLIST\n', base),
        throwsA(isA<HlsException>()),
      );
    });
  });

  group('parseAttributes', () {
    test('keeps a quoted URI containing a comma intact', () {
      final attributes = parseAttributes(
        'METHOD=AES-128,URI="https://x/k?a=1,2",IV=0xFF',
      );
      expect(attributes['METHOD'], 'AES-128');
      expect(attributes['URI'], 'https://x/k?a=1,2');
      expect(attributes['IV'], '0xFF');
    });
  });

  group('parseHexIv', () {
    test('accepts the prefixed and bare forms alike', () {
      expect(parseHexIv('0x00112233445566778899aabbccddeeff'), hasLength(16));
      expect(parseHexIv('00112233445566778899AABBCCDDEEFF').last, 0xff);
    });

    test('rejects odd-length and non-hex input', () {
      expect(() => parseHexIv('0xabc'), throwsA(isA<HlsException>()));
      expect(() => parseHexIv('0xzz'), throwsA(isA<HlsException>()));
      expect(() => parseHexIv('0x'), throwsA(isA<HlsException>()));
    });
  });

  group('decryptSegment', () {
    final key = Uint8List.fromList(List.generate(16, (i) => i));
    final iv = Uint8List.fromList(List.generate(16, (i) => 255 - i));

    test('recovers the plaintext of an encrypted segment', () {
      final plain = Uint8List.fromList(
        List.generate(1000, (i) => (i * 7) % 256),
      );
      final decrypted = decryptSegment(
        encrypt(plain, key, iv),
        StreamKey(value: key, iv: iv),
      );
      expect(decrypted, plain);
    });

    test('recovers plaintext that is an exact multiple of the block size', () {
      // A full block of padding is appended, so the ciphertext is one block
      // longer than the plaintext.
      final plain = Uint8List.fromList(List.generate(32, (i) => i));
      final ciphertext = encrypt(plain, key, iv);
      expect(ciphertext, hasLength(48));
      expect(decryptSegment(ciphertext, StreamKey(value: key, iv: iv)), plain);
    });

    test('rejects ciphertext that is not block aligned', () {
      expect(
        () => decryptSegment(Uint8List(17), StreamKey(value: key, iv: iv)),
        throwsA(isA<HlsException>()),
      );
    });

    test('rejects a segment whose padding byte is out of range', () {
      // Slicing on this byte unchecked would either throw or silently truncate
      // audio.
      final wrongKey = Uint8List(16);
      expect(
        () => decryptSegment(
          encrypt(Uint8List.fromList([1, 2, 3]), key, iv),
          StreamKey(value: wrongKey, iv: iv),
        ),
        throwsA(isA<HlsException>()),
      );
    });
  });

  group('stripPkcs7', () {
    test('removes the declared number of padding bytes', () {
      // The final byte is the count, so three 3s strip themselves and leave the
      // 3 that is real data.
      expect(stripPkcs7(Uint8List.fromList([1, 2, 3, 3, 3, 3])), [1, 2, 3]);
      expect(stripPkcs7(Uint8List.fromList([1, 2, 4, 4, 4, 4])), [1, 2]);
    });

    test('rejects a zero or oversized padding length', () {
      expect(
        () => stripPkcs7(Uint8List.fromList([1, 0])),
        throwsA(isA<HlsException>()),
      );
      expect(
        () => stripPkcs7(Uint8List.fromList([1, 17])),
        throwsA(isA<HlsException>()),
      );
      expect(
        () => stripPkcs7(Uint8List.fromList([5])),
        throwsA(isA<HlsException>()),
      );
    });
  });

  group('sanitizeFileName', () {
    test('removes characters the filesystem forbids', () {
      expect(sanitizeFileName('AC/DC: Back <in> Black?'), 'ACDC Back in Black');
    });

    test('collapses whitespace and trims trailing dots', () {
      // Windows creates "name." but cannot then open it.
      expect(sanitizeFileName('a   b'), 'a b');
      expect(sanitizeFileName('track...'), 'track');
      expect(sanitizeFileName('  spaced  '), 'spaced');
    });

    test('falls back when nothing printable survives', () {
      expect(sanitizeFileName('///'), 'track');
      expect(sanitizeFileName(''), 'track');
    });

    test('truncates without splitting a rune', () {
      final long = 'é' * 300;
      final result = sanitizeFileName(long);
      expect(result.length, lessThanOrEqualTo(maxFileNameLength));
      expect(result.runes.every((r) => r == 'é'.runes.first), isTrue);
    });
  });
}

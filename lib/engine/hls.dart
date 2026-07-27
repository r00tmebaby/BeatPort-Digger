/// HLS media playlists and the AES-128 encryption Beatport applies to segments.
///
/// Streams are delivered as an MPEG-TS segment list encrypted with a single key
/// fetched over HTTPS. The playlist carries one EXT-X-KEY covering every
/// segment, so the key and IV are read once and reused rather than re-fetched
/// per segment.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;

import 'errors.dart';

const int _aesBlockSize = 16;

/// Raised when a playlist cannot be interpreted as an encrypted media playlist.
class HlsException implements Exception {
  HlsException(this.message);

  final String message;

  @override
  String toString() => 'hls: $message';
}

/// The key material protecting a stream's segments.
class StreamKey {
  const StreamKey({required this.value, required this.iv});

  /// The raw AES-128 key, as served by the key URI.
  final Uint8List value;

  /// The initialisation vector declared by the playlist.
  final Uint8List iv;
}

/// A parsed media playlist: where the segments are and how to decrypt them.
class MediaPlaylist {
  const MediaPlaylist({
    required this.segments,
    required this.keyUri,
    required this.iv,
  });

  /// Absolute segment URIs, in playback order.
  final List<Uri> segments;

  /// Absolute URI of the AES key, or null when the stream is unencrypted.
  final Uri? keyUri;

  /// The IV declared by EXT-X-KEY, or null when it was omitted.
  final Uint8List? iv;

  bool get isEncrypted => keyUri != null;
}

/// Parses the hex IV of an EXT-X-KEY attribute, with or without a 0x prefix.
Uint8List parseHexIv(String raw) {
  var text = raw.trim();
  if (text.startsWith('0x') || text.startsWith('0X')) {
    text = text.substring(2);
  }
  if (text.length.isOdd || text.isEmpty) {
    throw HlsException('malformed IV "$raw"');
  }
  final bytes = Uint8List(text.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    final byte = int.tryParse(text.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) throw HlsException('malformed IV "$raw"');
    bytes[i] = byte;
  }
  return bytes;
}

/// Splits an EXT-X-KEY attribute list into its key/value pairs.
///
/// Values may be quoted and a quoted URI can itself contain commas, so the list
/// cannot be split on commas alone.
Map<String, String> parseAttributes(String line) {
  final attributes = <String, String>{};
  final pattern = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');
  for (final match in pattern.allMatches(line)) {
    final key = match.group(1)!;
    var value = match.group(2) ?? '';
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    attributes[key] = value;
  }
  return attributes;
}

/// Reads a media playlist, resolving every URI against [base].
///
/// Relative URIs are resolved properly rather than concatenated onto the
/// playlist's directory, so a segment or key served from another host or from
/// the domain root is still reached.
MediaPlaylist parseMediaPlaylist(String body, Uri base) {
  final segments = <Uri>[];
  Uri? keyUri;
  Uint8List? iv;

  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#EXT-X-KEY:')) {
      final attributes = parseAttributes(line.substring('#EXT-X-KEY:'.length));
      final method = attributes['METHOD'] ?? 'NONE';
      if (method == 'NONE') continue;
      if (method != 'AES-128') {
        throw HlsException('unsupported encryption method "$method"');
      }
      final uri = attributes['URI'];
      if (uri == null || uri.isEmpty) {
        throw HlsException('EXT-X-KEY without a URI');
      }
      keyUri = base.resolve(uri);
      final rawIv = attributes['IV'];
      if (rawIv != null && rawIv.isNotEmpty) iv = parseHexIv(rawIv);
      continue;
    }

    if (line.startsWith('#')) continue;
    segments.add(base.resolve(line));
  }

  if (segments.isEmpty) {
    throw HlsException('playlist contains no segments');
  }
  return MediaPlaylist(segments: segments, keyUri: keyUri, iv: iv);
}

/// Strips PKCS#7 padding from a decrypted block sequence.
///
/// The padding length is attacker-controlled in principle, so it is validated
/// before being trusted as a slice bound: an unchecked value would either throw
/// a range error or silently truncate audio.
Uint8List stripPkcs7(Uint8List data) {
  if (data.isEmpty) return data;
  final padding = data.last;
  if (padding == 0 || padding > _aesBlockSize || padding > data.length) {
    throw HlsException('invalid PKCS#7 padding');
  }
  return Uint8List.sublistView(data, 0, data.length - padding);
}

/// Decrypts one AES-128-CBC segment and removes its padding.
Uint8List decryptSegment(Uint8List segment, StreamKey key) {
  if (segment.isEmpty) return segment;
  if (segment.length % _aesBlockSize != 0) {
    throw HlsException(
      'segment length ${segment.length} is not a multiple of the AES block size',
    );
  }

  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(key.value), key.iv));

  final output = Uint8List(segment.length);
  for (var offset = 0; offset < segment.length; offset += _aesBlockSize) {
    cipher.processBlock(segment, offset, output, offset);
  }
  return stripPkcs7(output);
}

/// Fetches the playlist for [streamUrl] and the key protecting it.
///
/// The stream URL is pre-signed, so it is requested without the API's bearer
/// token; sending one would be ignored at best and rejected at worst.
Future<(MediaPlaylist, StreamKey?)> loadStream(
  Uri streamUrl, {
  http.Client? httpClient,
}) async {
  final client = httpClient ?? http.Client();
  try {
    final response = await client.get(streamUrl);
    if (response.statusCode != 200) {
      throw BeatportException(
        response.statusCode,
        'could not read the stream playlist',
      );
    }

    final playlist = parseMediaPlaylist(response.body, streamUrl);
    final keyUri = playlist.keyUri;
    if (keyUri == null) return (playlist, null);

    final keyResponse = await client.get(keyUri);
    if (keyResponse.statusCode != 200) {
      throw BeatportException(
        keyResponse.statusCode,
        'could not read the stream key',
      );
    }
    final value = Uint8List.fromList(keyResponse.bodyBytes);
    if (value.length != _aesBlockSize) {
      throw HlsException('expected a 16-byte AES-128 key, got ${value.length}');
    }

    // An absent IV is legal: the sequence number stands in for it. Beatport
    // always declares one, but falling back keeps a compliant playlist working.
    final iv = playlist.iv ?? Uint8List(_aesBlockSize);
    if (iv.length != _aesBlockSize) {
      throw HlsException('expected a 16-byte IV, got ${iv.length}');
    }

    return (playlist, StreamKey(value: value, iv: iv));
  } finally {
    if (httpClient == null) client.close();
  }
}
